const std = @import("std");
const json = std.json;
const lsp_types = @import("lsp_types.zig");
const AgentTool = @import("models.zig").AgentTool;

// JSON-RPC initialize request with custom serialization
const InitializeRequestParams = struct {
    processId: i32,
    clientInfo: ClientInfoJson,
    rootUri: ?[]const u8,
    capabilities: CapabilitiesJson,

    const ClientInfoJson = struct {
        name: []const u8,
        version: []const u8,
    };

    const CapabilitiesJson = struct {};

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("processId");
        try jws.write(self.processId);
        try jws.objectField("clientInfo");
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(self.clientInfo.name);
        try jws.objectField("version");
        try jws.write(self.clientInfo.version);
        try jws.endObject();
        try jws.objectField("rootUri");
        try jws.write(self.rootUri);
        try jws.objectField("capabilities");
        try jws.write(self.capabilities);
        try jws.endObject();
    }
};

const InitializeRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: i32,
    method: []const u8 = "initialize",
    params: InitializeRequestParams,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write(self.jsonrpc);
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("method");
        try jws.write(self.method);
        try jws.objectField("params");
        try jws.write(self.params);
        try jws.endObject();
    }
};

// Re-export types for convenience
pub const LspError = lsp_types.LspError;
pub const InitializeParams = lsp_types.InitializeParams;
pub const ClientInfo = lsp_types.ClientInfo;
pub const WorkspaceFolder = lsp_types.WorkspaceFolder;
pub const ServerCapabilities = lsp_types.ServerCapabilities;
pub const Range = lsp_types.Range;
pub const Position = lsp_types.Position;
pub const Diagnostic = lsp_types.Diagnostic;
pub const Location = lsp_types.Location;
pub const InitializeResult = lsp_types.InitializeResult;
pub const common_binary_paths = lsp_types.common_binary_paths;

// Global sessions map - session_id -> *LspClient
var sessions: ?std.StringHashMap(*LspClient) = null;

pub fn getSessions() *std.StringHashMap(*LspClient) {
    if (sessions == null) {
        sessions = std.StringHashMap(*LspClient).init(std.heap.page_allocator);
    }
    return &sessions.?;
}

pub const LspClient = struct {
    allocator: std.mem.Allocator,
    process: std.process.Child,
    stdin: std.fs.File,
    stdout: std.fs.File,
    session_id: []u8,
    workspace_uri: []u8,
    server_capabilities: ?ServerCapabilities,
    initialized: bool,
    next_request_id: i32,
    request_map: std.AutoHashMap(i32, []const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, session_id: []const u8, workspace_uri: []const u8) !Self {
        return .{
            .allocator = allocator,
            .process = undefined,
            .stdin = undefined,
            .stdout = undefined,
            .session_id = try allocator.dupe(u8, session_id),
            .workspace_uri = try allocator.dupe(u8, workspace_uri),
            .server_capabilities = null,
            .initialized = false,
            .next_request_id = 1,
            .request_map = std.AutoHashMap(i32, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.request_map.deinit();
        self.allocator.free(self.session_id);
        self.allocator.free(self.workspace_uri);
    }
};

pub fn findBinary(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    // First try which - build argv manually
    var name_buf: [256]u8 = undefined;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;

    var which_argv: [2][:0]const u8 = undefined;
    which_argv[0] = "which";
    which_argv[1] = name_buf[0..name.len :0];
    var which_child = std.process.Child.init(&which_argv, allocator);
    which_child.stdout_behavior = .Pipe;
    which_child.stderr_behavior = .Ignore;
    which_child.stdin_behavior = .Close;

    const spawn_result = which_child.spawn();
    if (spawn_result) |_| {
        // Read output if spawn succeeded
        var buf: [4096]u8 = undefined;
        const bytes_read = which_child.stdout.?.read(&buf) catch 0;
        if (bytes_read > 0) {
            const path = std.mem.trim(u8, buf[0..bytes_read], " \n\r");
            if (path.len > 0 and path[0] == '/') {
                _ = which_child.wait() catch {};
                return try allocator.dupe(u8, path);
            }
        }
        _ = which_child.wait() catch {};
    } else |_| {
        // Try common paths directly if spawn fails
    }

    // Then try common paths
    for (common_binary_paths) |base_path| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, name });
        defer allocator.free(full_path);

        // Check if file exists by attempting to open it
        if (std.fs.openFileAbsolute(full_path, .{})) |file| {
            file.close();
            return try allocator.dupe(u8, full_path);
        } else |_| {}
    }

    return LspError.BinaryNotFound;
}

pub fn spawnLsp(allocator: std.mem.Allocator, session_id: []const u8, binary_name: []const u8, workspace_uri: []const u8) !*LspClient {
    const binary_path = try findBinary(allocator, binary_name);
    defer allocator.free(binary_path);

    std.debug.print("spawnLsp: found binary at {s}\n", .{binary_path});

    // Parse workspace path from URI (strip "file://")
    var workspace_path: []u8 = undefined;
    if (std.mem.startsWith(u8, workspace_uri, "file://")) {
        workspace_path = try allocator.dupe(u8, workspace_uri[7..]);
    } else {
        workspace_path = try allocator.dupe(u8, workspace_uri);
    }
    defer allocator.free(workspace_path);

    std.debug.print("spawnLsp: workspace path: {s}\n", .{workspace_path});

    // Ensure workspace directory exists
    std.fs.makeDirAbsolute(workspace_path) catch |e| {
        if (e != error.PathAlreadyExists) {
            std.debug.print("spawnLsp: failed to create workspace dir: {}\n", .{e});
            return LspError.ProcessSpawnFailed;
        }
    };

    var child_argv: [1][:0]const u8 = undefined;
    child_argv[0] = try allocator.dupeZ(u8, binary_path);
    defer allocator.free(child_argv[0]);
    var child = std.process.Child.init(&child_argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore; // Ignore stderr to avoid blocking
    child.cwd = workspace_path;

    try child.spawn();

    std.debug.print("spawnLsp: spawned process, pid={d}\n", .{child.id});

    // Give the process a moment to start up
    std.Thread.sleep(200 * std.time.ns_per_ms);

    const client = try allocator.create(LspClient);
    client.* = try LspClient.init(allocator, session_id, workspace_uri);
    client.process = child;
    client.stdin = child.stdin.?;
    client.stdout = child.stdout.?;

    std.debug.print("spawnLsp: client created, stdin={any}, stdout={any}\n", .{ client.stdin, client.stdout });

    // Store in global sessions
    const sessions_ptr = getSessions();
    try sessions_ptr.put(try allocator.dupe(u8, session_id), client);

    return client;
}

pub fn initialize(allocator: std.mem.Allocator, client: *LspClient) !InitializeResult {
    const request_id = client.next_request_id;
    client.next_request_id += 1;

    // Use arena allocator for JSON building
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Build JSON-RPC initialize request using the struct with jsonStringify
    const client_info = InitializeRequestParams.ClientInfoJson{
        .name = "zigaagentic",
        .version = "0.1.0",
    };

    const params = InitializeRequestParams{
        .processId = 12345,
        .clientInfo = client_info,
        .rootUri = client.workspace_uri,
        .capabilities = .{},
    };

    const request = InitializeRequest{
        .id = request_id,
        .params = params,
    };

    // Serialize to JSON string
    var aw: std.io.Writer.Allocating = .init(arena_alloc);
    try aw.writer.print("{f}", .{std.json.fmt(request, .{})});
    const json_str = try aw.toOwnedSlice();
    defer arena_alloc.free(json_str);

    try writeMessage(client.stdin, json_str);

    // Read response
    const response_json = try readMessage(client.stdout, allocator);
    defer allocator.free(response_json);

    var parsed = json.parseFromSlice(json.Value, allocator, response_json, .{}) catch {
        return LspError.InvalidResponse;
    };
    defer parsed.deinit();

    // Check for error response - use .object.get() for Value
    if (parsed.value == .object) {
        if (parsed.value.object.get("error")) |_| {
            return LspError.HandshakeFailed;
        }
    }

    client.initialized = true;
    return InitializeResult{ .capabilities = ServerCapabilities{} };
}

pub fn writeMessage(writer: std.fs.File, json_str: []const u8) !void {
    const content_length = json_str.len;
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{content_length});
    try writer.writeAll(header);
    try writer.writeAll(json_str);
    // Flush to ensure the message is sent immediately
    // Note: std.fs.File doesn't have flush(), writeAll is synchronous
}

pub fn readMessage(reader: std.fs.File, allocator: std.mem.Allocator) ![]u8 {
    // Read header line by line until empty line
    var header_buf: [4096]u8 = undefined;
    var header_len: usize = 0;
    var found_empty_line = false;
    var timeout_counter: usize = 0;
    const max_timeout = 100; // Prevent infinite loops

    // Use read() instead of readByte()
    while (header_len < header_buf.len and timeout_counter < max_timeout) {
        const bytes_read = reader.read(header_buf[header_len..header_buf.len]) catch |e| {
            std.debug.print("readMessage: read error: {}\n", .{e});
            return error.JsonParseError;
        };
        if (bytes_read == 0) {
            timeout_counter += 1;
            std.Thread.sleep(10 * std.time.ns_per_ms); // Small delay before retry
            continue;
        }
        header_len += bytes_read;

        // Check if we have a complete header (double CRLF)
        if (header_len >= 4) {
            // Find the end of headers ( CRLF CRLF)
            var i: usize = 0;
            while (i < header_len - 3) : (i += 1) {
                if (header_buf[i] == '\r' and header_buf[i + 1] == '\n' and
                    header_buf[i + 2] == '\r' and header_buf[i + 3] == '\n')
                {
                    found_empty_line = true;
                    header_len = i + 4;
                    break;
                }
            }
            if (found_empty_line) break;
        }
    }

    if (!found_empty_line) {
        std.debug.print("readMessage: did not find empty line, header_len={d}\n", .{header_len});
        if (header_len > 0) {
            std.debug.print("readMessage: header content: {s}\n", .{header_buf[0..@min(header_len, 200)]});
        }
        return error.JsonParseError;
    }

    // Parse Content-Length from headers
    var content_length: usize = 0;
    var pos: usize = 0;
    while (pos < header_len) {
        const line_start = pos;
        while (pos < header_len and header_buf[pos] != '\n') : (pos += 1) {}
        const line = header_buf[line_start..pos];
        pos += 1;

        if (std.mem.startsWith(u8, line, "Content-Length:")) {
            const val = std.mem.trim(u8, line[15..], " \r");
            content_length = std.fmt.parseInt(usize, val, 10) catch {
                std.debug.print("readMessage: failed to parse Content-Length: {s}\n", .{val});
                return error.JsonParseError;
            };
            break;
        }
    }

    if (content_length == 0) {
        std.debug.print("readMessage: Content-Length is 0\n", .{});
        return error.JsonParseError;
    }

    // Read body
    const body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);

    var remaining = content_length;
    var offset: usize = 0;
    var body_timeout: usize = 0;
    while (remaining > 0 and body_timeout < max_timeout) {
        const bytes_read = reader.read(body[offset..]) catch |e| {
            std.debug.print("readMessage: body read error: {}\n", .{e});
            allocator.free(body);
            return error.JsonParseError;
        };
        if (bytes_read == 0) {
            body_timeout += 1;
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        }
        offset += bytes_read;
        remaining -= bytes_read;
    }

    if (remaining > 0) {
        std.debug.print("readMessage: incomplete body, expected {d} bytes, got {d}\n", .{ content_length, offset });
        allocator.free(body);
        return error.JsonParseError;
    }

    return body[0..offset];
}

test {
    _ = @import("lsp_client_core_test.zig");
}
