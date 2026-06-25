const std = @import("std");
const nalarcore = @import("nalarcore");
const helpers = nalarcore.helpers;
const json = std.json;
const schemas = @import("schemas.zig");
const lsp_types = @import("lsp_types.zig");
const AgentTool = schemas.AgentTool;

// Re-export all LSP input/output types from lsp_types.zig
pub const LspDefinitionInput = lsp_types.LspDefinitionInput;
pub const LspDefinitionOutput = lsp_types.LspDefinitionOutput;
pub const LspLocation = lsp_types.LspLocation;

pub const LspReferencesInput = lsp_types.LspReferencesInput;
pub const LspReferencesOutput = lsp_types.LspReferencesOutput;

pub const LspWorkspaceSymbolInput = lsp_types.LspWorkspaceSymbolInput;
pub const LspWorkspaceSymbolOutput = lsp_types.LspWorkspaceSymbolOutput;
pub const LspWorkspaceSymbol = lsp_types.LspWorkspaceSymbol;

pub const LspDocumentSymbolInput = lsp_types.LspDocumentSymbolInput;
pub const LspDocumentSymbolOutput = lsp_types.LspDocumentSymbolOutput;
pub const LspDocumentSymbol = lsp_types.LspDocumentSymbol;

pub const LspHoverInput = lsp_types.LspHoverInput;
pub const LspHoverOutput = lsp_types.LspHoverOutput;

// Unified LSP error set
pub const LspError = error{
    FileNotFound,
    ReadFileFailed,
    BinaryNotFound,
    ProcessSpawnFailed,
    InvalidResponse,
    DefinitionNotFound,
    ReferencesNotFound,
    SymbolsNotFound,
    HoverNotFound,
};

// Find LSP binary - resolves name to absolute path
pub fn find_lsp(allocator: std.mem.Allocator, lsp_name: []const u8) ![]u8 {
    // If already an absolute path, check if it exists
    if (lsp_name.len > 0 and lsp_name[0] == '/') {
        // `std.fs.accessAbsolute` was removed in Zig 0.16; use the
        // cross-platform `helpers.fileExists` wrapper (libc `access`).
        if (!helpers.fileExists(lsp_name)) return LspError.BinaryNotFound;
        return try allocator.dupe(u8, lsp_name);
    }

    // Try common paths first
    const common_paths = &[_][]const u8{
        "/usr/bin/zls",
        "/usr/local/bin/zls",
        "/home/ginwa/.local/bin/zls",
        "/home/ginwa/.local/share/nvim/mason/bin/zls",
        "/opt/homebrew/bin/zls",
        "/usr/sbin/zls",
    };

    for (common_paths) |path| {
        if (std.fs.accessAbsolute(path, .{})) {
            return try allocator.dupe(u8, path);
        }
    }

    // Try `which` command for the given lsp_name
    var which_child = std.process.Child.init(&.{ "which", lsp_name }, allocator);
    which_child.stdout_behavior = .Pipe;
    which_child.stderr_behavior = .Ignore;

    which_child.spawn() catch return LspError.BinaryNotFound;

    var buf: [256]u8 = undefined;
    const n = which_child.stdout.?.read(&buf) catch {
        _ = which_child.wait() catch {};
        return LspError.BinaryNotFound;
    };
    _ = which_child.wait() catch {};

    if (n > 0) {
        const path = std.mem.trim(u8, buf[0..n], " \n\r");
        if (path.len > 0 and path[0] == '/') {
            return try allocator.dupe(u8, path);
        }
    }

    return LspError.BinaryNotFound;
}

// =============================================================================
// Shared JSON-RPC message helpers
// =============================================================================

pub fn create_message(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ content.len, content });
}

// Read one JSON-RPC message from LSP stdout
fn read_message(allocator: std.mem.Allocator, stdout: std.fs.File) ![]u8 {
    var header_buf: [1024]u8 = undefined;
    var header_len: usize = 0;
    var found_empty = false;

    while (!found_empty) {
        var byte: [1]u8 = undefined;
        const n = stdout.read(&byte) catch return LspError.InvalidResponse;
        if (n == 0) return LspError.InvalidResponse;

        if (header_len < header_buf.len) {
            header_buf[header_len] = byte[0];
            header_len += 1;
        }

        if (header_len >= 4) {
            const end = header_buf[header_len - 4 .. header_len];
            if (std.mem.eql(u8, end, "\r\n\r\n")) {
                found_empty = true;
            }
        }
    }

    const header = header_buf[0..header_len];
    const prefix = "Content-Length: ";
    const start = std.mem.indexOf(u8, header, prefix) orelse return LspError.InvalidResponse;
    const end = std.mem.indexOf(u8, header[start..], "\r\n") orelse return LspError.InvalidResponse;
    const len_str = header[start + prefix.len .. start + end];
    const content_len = std.fmt.parseInt(usize, len_str, 10) catch return LspError.InvalidResponse;

    const body = try allocator.alloc(u8, content_len);
    errdefer allocator.free(body);

    var total_read: usize = 0;
    while (total_read < content_len) {
        const n = try stdout.read(body[total_read..]);
        if (n == 0) return LspError.InvalidResponse;
        total_read += n;
    }

    return body;
}

// =============================================================================
// LSP Session Helper - encapsulates common setup and communication
// =============================================================================

const LspSession = struct {
    arena: std.heap.ArenaAllocator,
    arena_allocator: std.mem.Allocator,
    child: std.process.Child,
    stdin: std.fs.File,
    stdout: std.fs.File,
    uri: []const u8,
    root_uri: []const u8,
    content: []const u8,

    /// Initialize LSP session with file-based operations
    pub fn init_with_file(
        parent_allocator: std.mem.Allocator,
        lsp_name: []const u8,
        file_path: []const u8,
        root_dir: []const u8,
    ) !LspSession {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        const arena_allocator = arena.allocator();

        // Resolve LSP binary name to absolute path
        const lsp_binary = try find_lsp(arena_allocator, lsp_name);
        errdefer arena_allocator.free(lsp_binary);

        // `std.fs.accessAbsolute` / `std.fs.cwd().openFile` were removed
        // in Zig 0.16; use the cross-platform `helpers.fileExists` /
        // `helpers.readFile` wrappers (libc fopen/fread, no `io: std.Io`
        // required).
        if (!helpers.fileExists(file_path)) return LspError.FileNotFound;
        const content = try helpers.readFile(arena_allocator, file_path) catch return LspError.ReadFileFailed;

        var child = std.process.Child.init(&.{lsp_binary}, arena_allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        const stdin = child.stdin.?;
        const stdout = child.stdout.?;
        const uri = try std.fmt.allocPrint(arena_allocator, "file://{s}", .{file_path});
        const root_uri = try std.fmt.allocPrint(arena_allocator, "file://{s}", .{root_dir});

        var session = LspSession{
            .arena = arena,
            .arena_allocator = arena_allocator,
            .child = child,
            .stdin = stdin,
            .stdout = stdout,
            .uri = uri,
            .root_uri = root_uri,
            .content = content,
        };

        try session.send_initialize();
        try session.send_initialized();
        try session.send_did_open();

        return session;
    }

    /// Initialize LSP session without file (for workspace-wide operations)
    pub fn init_without_file(
        parent_allocator: std.mem.Allocator,
        lsp_name: []const u8,
        root_dir: []const u8,
    ) !LspSession {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        const arena_allocator = arena.allocator();

        // Resolve LSP binary name to absolute path
        const lsp_binary = try find_lsp(arena_allocator, lsp_name);
        errdefer arena_allocator.free(lsp_binary);

        var child = std.process.Child.init(&.{lsp_binary}, arena_allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        const stdin = child.stdin.?;
        const stdout = child.stdout.?;
        const root_uri = try std.fmt.allocPrint(arena_allocator, "file://{s}", .{root_dir});

        var session = LspSession{
            .arena = arena,
            .arena_allocator = arena_allocator,
            .child = child,
            .stdin = stdin,
            .stdout = stdout,
            .uri = "",
            .root_uri = root_uri,
            .content = "",
        };

        try session.send_initialize();
        try session.send_initialized();

        return session;
    }

    pub fn deinit(self: *LspSession) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        self.arena.deinit();
    }

    fn send_initialize(self: *LspSession) !void {
        var buf = std.ArrayList(u8).empty;
        const w = buf.writer(self.arena_allocator);
        try w.print("{{", .{});
        try w.print("\"jsonrpc\":\"2.0\",", .{});
        try w.print("\"id\":1,", .{});
        try w.print("\"method\":\"initialize\",", .{});
        try w.print("\"params\":{{", .{});
        try w.print("\"processId\":null,", .{});
        try w.print("\"rootUri\":\"{s}\",", .{self.root_uri});
        try w.print("\"capabilities\":{{}}}}}}", .{});
        const json_str = try buf.toOwnedSlice(self.arena_allocator);
        const msg = try create_message(self.arena_allocator, json_str);
        try self.stdin.writeAll(msg);

        var attempts: usize = 0;
        while (attempts < 10) {
            const data = try read_message(self.arena_allocator, self.stdout);
            var parsed = json.parseFromSlice(json.Value, self.arena_allocator, data, .{}) catch {
                attempts += 1;
                continue;
            };
            if (parsed.value.object.get("id")) |id| {
                if (id == .integer and id.integer == 1) break;
            }
            attempts += 1;
        }
        if (attempts >= 10) return LspError.InvalidResponse;
    }

    fn send_initialized(self: *LspSession) !void {
        const msg = try create_message(self.arena_allocator,
            \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        );
        try self.stdin.writeAll(msg);
    }

    fn send_did_open(self: *LspSession) !void {
        const prefix = try std.fmt.allocPrint(self.arena_allocator,
            \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","languageId":"zig","version":1,"text":"
        , .{self.uri});

        var escaped = std.ArrayList(u8).empty;
        const w = escaped.writer(self.arena_allocator);
        for (self.content) |c| {
            switch (c) {
                '\\' => try w.print("\\\\", .{}),
                '"' => try w.print("\\\"", .{}),
                '\n' => try w.print("\\n", .{}),
                '\r' => try w.print("\\r", .{}),
                '\t' => try w.print("\\t", .{}),
                else => try w.print("{c}", .{c}),
            }
        }

        const full = try std.fmt.allocPrint(self.arena_allocator, "{s}{s}\"}}}}", .{ prefix, escaped.items });
        const msg = try create_message(self.arena_allocator, full);
        try self.stdin.writeAll(msg);
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    pub fn send_request(self: *LspSession, request_json: []const u8, request_id: i64) ![]u8 {
        const msg = try create_message(self.arena_allocator, request_json);
        try self.stdin.writeAll(msg);

        var attempts: usize = 0;
        while (attempts < 10) {
            const data = try read_message(self.arena_allocator, self.stdout);
            var parsed = json.parseFromSlice(json.Value, self.arena_allocator, data, .{}) catch {
                attempts += 1;
                continue;
            };
            if (parsed.value.object.get("id")) |id| {
                if (id == .integer and id.integer == request_id) return data;
            }
            attempts += 1;
        }
        return LspError.InvalidResponse;
    }
};

// =============================================================================
// LSP Definition
// =============================================================================

fn parse_definition_location(allocator: std.mem.Allocator, loc_value: json.Value) !?LspLocation {
    if (loc_value != .object) return null;
    const obj = loc_value.object;

    const uri_val = obj.get("targetUri") orelse obj.get("uri") orelse return null;
    if (uri_val != .string) return null;

    const range_val = obj.get("targetRange") orelse obj.get("range") orelse return null;
    if (range_val != .object) return null;

    const start_val = range_val.object.get("start") orelse return null;
    if (start_val != .object) return null;

    const line_val = start_val.object.get("line") orelse return null;
    const char_val = start_val.object.get("character") orelse return null;
    if (line_val != .integer or char_val != .integer) return null;

    const result_uri = uri_val.string;
    const result_path = if (std.mem.startsWith(u8, result_uri, "file://")) result_uri[7..] else result_uri;

    var location = LspLocation{
        .file_path = try allocator.dupe(u8, result_path),
        .line = @intCast(line_val.integer),
        .character = @intCast(char_val.integer),
    };

    if (range_val.object.get("end")) |end| {
        if (end == .object) {
            if (end.object.get("line")) |el| {
                if (el == .integer) location.end_line = @intCast(el.integer);
            }
            if (end.object.get("character")) |ec| {
                if (ec == .integer) location.end_character = @intCast(ec.integer);
            }
        }
    }

    if (obj.get("targetSelectionRange")) |sr| {
        if (sr == .object) {
            if (sr.object.get("start")) |srs| {
                if (srs == .object) {
                    if (srs.object.get("line")) |sl| {
                        if (sl == .integer) location.line = @intCast(sl.integer);
                    }
                    if (srs.object.get("character")) |sc| {
                        if (sc == .integer) location.character = @intCast(sc.integer);
                    }
                }
            }
        }
    }

    if (obj.get("originSelectionRange")) |orv| {
        if (orv == .object) {
            if (orv.object.get("start")) |ors| {
                if (ors == .object) {
                    if (ors.object.get("line")) |ol| {
                        if (ol == .integer) location.origin_line = @intCast(ol.integer);
                    }
                    if (ors.object.get("character")) |oc| {
                        if (oc == .integer) location.origin_character = @intCast(oc.integer);
                    }
                }
            }
        }
    }

    return location;
}

fn parse_definition_result(allocator: std.mem.Allocator, result: json.Value, max_output: ?u32) !LspDefinitionOutput {
    if (result == .null) {
        return LspDefinitionOutput{ .definitions = &.{}, .found = false };
    }

    var locations = std.ArrayList(LspLocation).empty;
    defer locations.deinit(allocator);
    const limit = max_output orelse 100;

    if (result == .array) {
        for (result.array.items) |item| {
            if (locations.items.len >= limit) break;
            if (try parse_definition_location(allocator, item)) |loc| {
                try locations.append(allocator, loc);
            }
        }
    } else if (result == .object) {
        if (try parse_definition_location(allocator, result)) |loc| {
            try locations.append(allocator, loc);
        }
    }

    const defs = try locations.toOwnedSlice(allocator);
    return LspDefinitionOutput{ .definitions = defs, .found = defs.len > 0 };
}

pub fn execute_lsp_definition(allocator: std.mem.Allocator, input: LspDefinitionInput) !LspDefinitionOutput {
    var session = try LspSession.init_with_file(allocator, input.lsp, input.file_path, input.root_dir);
    defer session.deinit();

    var buf = std.ArrayList(u8).empty;
    const w = buf.writer(session.arena_allocator);
    try w.print("{{", .{});
    try w.print("\"jsonrpc\":\"2.0\",", .{});
    try w.print("\"id\":2,", .{});
    try w.print("\"method\":\"textDocument/definition\",", .{});
    try w.print("\"params\":{{", .{});
    try w.print("\"textDocument\":{{\"uri\":\"{s}\"}},", .{session.uri});
    try w.print("\"position\":{{\"line\":{d},\"character\":{d}}}", .{ input.line, input.character });
    try w.print("}}}}", .{});
    const json_str = try buf.toOwnedSlice(session.arena_allocator);

    const response = try session.sendRequest(json_str, 2);
    var parsed = try json.parseFromSlice(json.Value, session.arena_allocator, response, .{});

    if (parsed.value != .object) return LspError.InvalidResponse;
    const result = parsed.value.object.get("result") orelse {
        return LspDefinitionOutput{ .definitions = &.{}, .found = false };
    };

    return try parse_definition_result(allocator, result, input.max_output);
}

pub fn lsp_definition_to_string(allocator: std.mem.Allocator, result: LspDefinitionOutput) ![]const u8 {
    if (!result.found or result.definitions.len == 0) {
        return try allocator.dupe(u8, "<found>false</found>");
    }

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    try w.print("<found>true</found>\n", .{});
    try w.print("<count>{d}</count>\n", .{result.definitions.len});
    try w.print("<definitions>\n", .{});

    for (result.definitions, 0..) |def, i| {
        try w.print("  <definition index=\"{d}\">\n", .{i + 1});
        try w.print("    <file_path>{s}</file_path>\n", .{def.file_path});
        try w.print("    <line>{d}</line>\n", .{def.line});
        try w.print("    <character>{d}</character>\n", .{def.character});
        if (def.end_line) |v| try w.print("    <end_line>{d}</end_line>\n", .{v});
        if (def.end_character) |v| try w.print("    <end_character>{d}</end_character>\n", .{v});
        if (def.origin_line) |v| try w.print("    <origin_line>{d}</origin_line>\n", .{v});
        if (def.origin_character) |v| try w.print("    <origin_character>{d}</origin_character>\n", .{v});
        try w.print("  </definition>\n", .{});
    }

    try w.print("</definitions>", .{});
    return try output.toOwnedSlice(allocator);
}

pub const lsp_definition_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_definition",
        .description =
        \\Go to definition of symbol at cursor position using LSP.
        \\Spawns lsp bin, initializes it, and queries the definition.
        \\Returns the file path, line, and character of the definition.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "lsp", .type = "string", .description = "LSP binary name like zls or pyls or path to binary" },
                .{ .name = "root_dir", .type = "string", .description = "Absolute path to the project root directory" },
                .{ .name = "file_path", .type = "string", .description = "Absolute path to the source file" },
                .{ .name = "line", .type = "number", .description = "Line number (0-indexed)" },
                .{ .name = "character", .type = "number", .description = "Character position (0-indexed)" },
                .{ .name = "max_output", .type = "number", .description = "Maximum number of results to return (default: 100)" },
            },
            .required = &.{ "lsp", "root_dir", "file_path", "line", "character" },
        },
    },
};

// =============================================================================
// LSP References
// =============================================================================

fn parse_references_location(allocator: std.mem.Allocator, loc_value: json.Value) !?LspLocation {
    if (loc_value != .object) return null;
    const obj = loc_value.object;

    const uri_val = obj.get("uri") orelse return null;
    if (uri_val != .string) return null;

    const range_val = obj.get("range") orelse return null;
    if (range_val != .object) return null;

    const start_val = range_val.object.get("start") orelse return null;
    if (start_val != .object) return null;

    const line_val = start_val.object.get("line") orelse return null;
    const char_val = start_val.object.get("character") orelse return null;
    if (line_val != .integer or char_val != .integer) return null;

    const result_uri = uri_val.string;
    const result_path = if (std.mem.startsWith(u8, result_uri, "file://")) result_uri[7..] else result_uri;

    var location = LspLocation{
        .file_path = try allocator.dupe(u8, result_path),
        .line = @intCast(line_val.integer),
        .character = @intCast(char_val.integer),
    };

    if (range_val.object.get("end")) |end| {
        if (end == .object) {
            if (end.object.get("line")) |el| {
                if (el == .integer) location.end_line = @intCast(el.integer);
            }
            if (end.object.get("character")) |ec| {
                if (ec == .integer) location.end_character = @intCast(ec.integer);
            }
        }
    }

    return location;
}

fn parse_references_result(allocator: std.mem.Allocator, result: json.Value, max_output: ?u32) !LspReferencesOutput {
    if (result == .null) {
        return LspReferencesOutput{ .definitions = &.{}, .found = false };
    }

    var locations = std.ArrayList(LspLocation).empty;
    defer locations.deinit(allocator);
    const limit = max_output orelse 100;

    if (result == .array) {
        for (result.array.items) |item| {
            if (locations.items.len >= limit) break;
            if (try parse_references_location(allocator, item)) |loc| {
                try locations.append(allocator, loc);
            }
        }
    }

    const refs = try locations.toOwnedSlice(allocator);
    return LspReferencesOutput{ .definitions = refs, .found = refs.len > 0 };
}

pub fn execute_lsp_references(allocator: std.mem.Allocator, input: LspReferencesInput) !LspReferencesOutput {
    var session = try LspSession.init_with_file(allocator, input.lsp, input.file_path, input.root_dir);
    defer session.deinit();

    var buf = std.ArrayList(u8).empty;
    const w = buf.writer(session.arena_allocator);
    try w.print("{{", .{});
    try w.print("\"jsonrpc\":\"2.0\",", .{});
    try w.print("\"id\":2,", .{});
    try w.print("\"method\":\"textDocument/references\",", .{});
    try w.print("\"params\":{{", .{});
    try w.print("\"textDocument\":{{\"uri\":\"{s}\"}},", .{session.uri});
    try w.print("\"position\":{{\"line\":{d},\"character\":{d}}},", .{ input.line, input.character });
    try w.print("\"context\":{{\"includeDeclaration\":{}}}", .{input.include_declaration});
    try w.print("}}}}", .{});
    const json_str = try buf.toOwnedSlice(session.arena_allocator);

    const response = try session.sendRequest(json_str, 2);
    var parsed = try json.parseFromSlice(json.Value, session.arena_allocator, response, .{});

    if (parsed.value != .object) return LspError.InvalidResponse;
    const result = parsed.value.object.get("result") orelse {
        return LspReferencesOutput{ .definitions = &.{}, .found = false };
    };

    return try parse_references_result(allocator, result, input.max_output);
}

pub fn lsp_references_to_string(allocator: std.mem.Allocator, result: LspReferencesOutput) ![]const u8 {
    if (!result.found or result.definitions.len == 0) {
        return try allocator.dupe(u8, "<found>false</found>");
    }

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    try w.print("<found>true</found>\n", .{});
    try w.print("<count>{d}</count>\n", .{result.definitions.len});
    try w.print("<references>\n", .{});

    for (result.definitions, 0..) |def, i| {
        try w.print("  <reference index=\"{d}\">\n", .{i + 1});
        try w.print("    <file_path>{s}</file_path>\n", .{def.file_path});
        try w.print("    <line>{d}</line>\n", .{def.line});
        try w.print("    <character>{d}</character>\n", .{def.character});
        if (def.end_line) |v| try w.print("    <end_line>{d}</end_line>\n", .{v});
        if (def.end_character) |v| try w.print("    <end_character>{d}</end_character>\n", .{v});
        try w.print("  </reference>\n", .{});
    }

    try w.print("</references>", .{});
    return try output.toOwnedSlice(allocator);
}

pub const lsp_references_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_references",
        .description =
        \\Find all references to a symbol at cursor position using LSP.
        \\Spawns lsp bin, initializes it, and queries textDocument/references.
        \\Returns all locations where the symbol is used.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "lsp", .type = "string", .description = "LSP binary name like zls or pyls or path to binary" },
                .{ .name = "root_dir", .type = "string", .description = "Absolute path to the project root directory" },
                .{ .name = "file_path", .type = "string", .description = "Absolute path to the source file" },
                .{ .name = "line", .type = "number", .description = "Line number (0-indexed)" },
                .{ .name = "character", .type = "number", .description = "Character position (0-indexed)" },
                .{ .name = "include_declaration", .type = "boolean", .description = "Include the declaration location in results (default: true)" },
                .{ .name = "max_output", .type = "number", .description = "Maximum number of results to return (default: 100)" },
            },
            .required = &.{ "lsp", "root_dir", "file_path", "line", "character" },
        },
    },
};

// =============================================================================
// LSP Workspace Symbol
// =============================================================================

fn parse_workspace_symbol(allocator: std.mem.Allocator, sym_value: json.Value) !?LspWorkspaceSymbol {
    if (sym_value != .object) return null;
    const obj = sym_value.object;

    const name_val = obj.get("name") orelse return null;
    if (name_val != .string) return null;

    const kind_val = obj.get("kind") orelse return null;
    if (kind_val != .integer) return null;

    var file_path: []u8 = undefined;
    var line: u32 = 0;
    var character: u32 = 0;

    if (obj.get("location")) |loc| {
        if (loc != .object) return null;
        const uri_val = loc.object.get("uri") orelse return null;
        if (uri_val != .string) return null;

        const result_uri = uri_val.string;
        file_path = if (std.mem.startsWith(u8, result_uri, "file://"))
            try allocator.dupe(u8, result_uri[7..])
        else
            try allocator.dupe(u8, result_uri);

        const range_val = loc.object.get("range") orelse return null;
        if (range_val != .object) return null;

        const start_val = range_val.object.get("start") orelse return null;
        if (start_val != .object) return null;

        const line_val = start_val.object.get("line") orelse return null;
        const char_val = start_val.object.get("character") orelse return null;
        if (line_val != .integer or char_val != .integer) return null;

        line = @intCast(line_val.integer);
        character = @intCast(char_val.integer);
    } else {
        const uri_val = obj.get("uri") orelse return null;
        if (uri_val != .string) return null;

        const result_uri = uri_val.string;
        file_path = if (std.mem.startsWith(u8, result_uri, "file://"))
            try allocator.dupe(u8, result_uri[7..])
        else
            try allocator.dupe(u8, result_uri);

        const range_val = obj.get("range") orelse obj.get("selectionRange");
        if (range_val) |r| {
            if (r == .object) {
                if (r.object.get("start")) |s| {
                    if (s == .object) {
                        if (s.object.get("line")) |lv| {
                            if (lv == .integer) line = @intCast(lv.integer);
                        }
                        if (s.object.get("character")) |cv| {
                            if (cv == .integer) character = @intCast(cv.integer);
                        }
                    }
                }
            }
        }
    }

    var container_name: ?[]u8 = null;
    if (obj.get("containerName")) |cv| {
        if (cv == .string) {
            container_name = try allocator.dupe(u8, cv.string);
        }
    }

    return LspWorkspaceSymbol{
        .name = try allocator.dupe(u8, name_val.string),
        .kind = @intCast(kind_val.integer),
        .file_path = file_path,
        .line = line,
        .character = character,
        .container_name = container_name,
    };
}

fn parse_workspace_symbol_result(allocator: std.mem.Allocator, result: json.Value, max_output: ?u32) !LspWorkspaceSymbolOutput {
    if (result == .null) {
        return LspWorkspaceSymbolOutput{ .symbols = &.{}, .found = false };
    }

    var symbols = std.ArrayList(LspWorkspaceSymbol).empty;
    defer symbols.deinit(allocator);
    const limit = max_output orelse 100;

    if (result == .array) {
        for (result.array.items) |item| {
            if (symbols.items.len >= limit) break;
            if (try parse_workspace_symbol(allocator, item)) |sym| {
                try symbols.append(allocator, sym);
            }
        }
    }

    const syms = try symbols.toOwnedSlice(allocator);
    return LspWorkspaceSymbolOutput{ .symbols = syms, .found = syms.len > 0 };
}

pub fn execute_lsp_workspace_symbol(allocator: std.mem.Allocator, input: LspWorkspaceSymbolInput) !LspWorkspaceSymbolOutput {
    var session = try LspSession.init_without_file(allocator, input.lsp, input.root_dir);
    defer session.deinit();

    var buf = std.ArrayList(u8).empty;
    const w = buf.writer(session.arena_allocator);
    try w.print("{{", .{});
    try w.print("\"jsonrpc\":\"2.0\",", .{});
    try w.print("\"id\":2,", .{});
    try w.print("\"method\":\"workspace/symbol\",", .{});
    try w.print("\"params\":{{", .{});
    try w.print("\"query\":\"{s}\"", .{input.query});
    try w.print("}}}}", .{});
    const json_str = try buf.toOwnedSlice(session.arena_allocator);

    const response = try session.sendRequest(json_str, 2);
    var parsed = try json.parseFromSlice(json.Value, session.arena_allocator, response, .{});

    if (parsed.value != .object) return LspError.InvalidResponse;
    const result = parsed.value.object.get("result") orelse {
        return LspWorkspaceSymbolOutput{ .symbols = &.{}, .found = false };
    };

    return try parse_workspace_symbol_result(allocator, result, input.max_output);
}

pub fn lsp_workspace_symbol_to_string(allocator: std.mem.Allocator, result: LspWorkspaceSymbolOutput) ![]const u8 {
    if (!result.found or result.symbols.len == 0) {
        return try allocator.dupe(u8, "<found>false</found>");
    }

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    try w.print("<found>true</found>\n", .{});
    try w.print("<count>{d}</count>\n", .{result.symbols.len});
    try w.print("<symbols>\n", .{});

    for (result.symbols, 0..) |sym, i| {
        try w.print("  <symbol index=\"{d}\">\n", .{i + 1});
        try w.print("    <name>{s}</name>\n", .{sym.name});
        try w.print("    <kind>{d}</kind>\n", .{sym.kind});
        try w.print("    <file_path>{s}</file_path>\n", .{sym.file_path});
        try w.print("    <line>{d}</line>\n", .{sym.line});
        try w.print("    <character>{d}</character>\n", .{sym.character});
        if (sym.container_name) |cn| try w.print("    <container_name>{s}</container_name>\n", .{cn});
        try w.print("  </symbol>\n", .{});
    }

    try w.print("</symbols>", .{});
    return try output.toOwnedSlice(allocator);
}

pub const lsp_workspace_symbol_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_workspace_symbol",
        .description =
        \\Search for symbols across the entire workspace using LSP.
        \\Spawns lsp bin, initializes it, and queries workspace/symbol.
        \\Returns all matching symbols with their names, kinds, and locations.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "lsp", .type = "string", .description = "LSP binary name like zls or pyls or path to binary" },
                .{ .name = "root_dir", .type = "string", .description = "Absolute path to the project root directory" },
                .{ .name = "query", .type = "string", .description = "Search query string to find symbols" },
                .{ .name = "max_output", .type = "number", .description = "Maximum number of results to return (default: 100)" },
            },
            .required = &.{ "lsp", "root_dir", "query" },
        },
    },
};

// =============================================================================
// LSP Document Symbol
// =============================================================================

fn parse_range(obj: json.ObjectMap) ?struct { line: u32, character: u32 } {
    const start_val = obj.get("start") orelse return null;
    if (start_val != .object) return null;

    const line_val = start_val.object.get("line") orelse return null;
    const char_val = start_val.object.get("character") orelse return null;
    if (line_val != .integer or char_val != .integer) return null;

    return .{ .line = @intCast(line_val.integer), .character = @intCast(char_val.integer) };
}

fn parse_document_symbol(allocator: std.mem.Allocator, sym_value: json.Value) !?LspDocumentSymbol {
    if (sym_value != .object) return null;
    const obj = sym_value.object;

    const name_val = obj.get("name") orelse return null;
    if (name_val != .string) return null;

    const kind_val = obj.get("kind") orelse return null;
    if (kind_val != .integer) return null;

    var detail: ?[]u8 = null;
    if (obj.get("detail")) |dv| {
        if (dv == .string) detail = try allocator.dupe(u8, dv.string);
    }

    var line: u32 = 0;
    var character: u32 = 0;
    var end_line: ?u32 = null;
    var end_character: ?u32 = null;
    var selection_line: ?u32 = null;
    var selection_character: ?u32 = null;

    if (obj.get("location")) |loc| {
        if (loc != .object) return null;
        const range_val = loc.object.get("range") orelse return null;
        if (range_val != .object) return null;

        if (parse_range(range_val.object)) |s| {
            line = s.line;
            character = s.character;
        }

        if (range_val.object.get("end")) |e| {
            if (e == .object) {
                if (e.object.get("line")) |l| {
                    if (l == .integer) end_line = @intCast(l.integer);
                }
                if (e.object.get("character")) |c| {
                    if (c == .integer) end_character = @intCast(c.integer);
                }
            }
        }
    } else {
        if (obj.get("range")) |rv| {
            if (rv == .object) {
                if (parse_range(rv.object)) |s| {
                    line = s.line;
                    character = s.character;
                }

                if (rv.object.get("end")) |e| {
                    if (e == .object) {
                        if (e.object.get("line")) |l| {
                            if (l == .integer) end_line = @intCast(l.integer);
                        }
                        if (e.object.get("character")) |c| {
                            if (c == .integer) end_character = @intCast(c.integer);
                        }
                    }
                }
            }
        }

        if (obj.get("selectionRange")) |srv| {
            if (srv == .object) {
                if (parse_range(srv.object)) |s| {
                    selection_line = s.line;
                    selection_character = s.character;
                }
            }
        }
    }

    var children: ?[]LspDocumentSymbol = null;
    if (obj.get("children")) |cv| {
        if (cv == .array) {
            var child_list = std.ArrayList(LspDocumentSymbol).empty;
            defer child_list.deinit(allocator);

            for (cv.array.items) |child_item| {
                if (try parse_document_symbol(allocator, child_item)) |c| {
                    try child_list.append(allocator, c);
                }
            }

            if (child_list.items.len > 0) {
                children = try child_list.toOwnedSlice(allocator);
            }
        }
    }

    return LspDocumentSymbol{
        .name = try allocator.dupe(u8, name_val.string),
        .kind = @intCast(kind_val.integer),
        .detail = detail,
        .line = line,
        .character = character,
        .end_line = end_line,
        .end_character = end_character,
        .selection_line = selection_line,
        .selection_character = selection_character,
        .children = children,
    };
}

fn parse_document_symbol_result(allocator: std.mem.Allocator, result: json.Value, max_output: ?u32) !LspDocumentSymbolOutput {
    if (result == .null) {
        return LspDocumentSymbolOutput{ .symbols = &.{}, .found = false };
    }

    var symbols = std.ArrayList(LspDocumentSymbol).empty;
    defer symbols.deinit(allocator);
    const limit = max_output orelse 100;

    if (result == .array) {
        for (result.array.items) |item| {
            if (symbols.items.len >= limit) break;
            if (try parse_document_symbol(allocator, item)) |s| {
                try symbols.append(allocator, s);
            }
        }
    }

    const syms = try symbols.toOwnedSlice(allocator);
    return LspDocumentSymbolOutput{ .symbols = syms, .found = syms.len > 0 };
}

fn write_symbol_to_xml(writer: anytype, sym: LspDocumentSymbol, indent_level: u32) !void {
    var indent_buf: [64]u8 = undefined;
    const indent = if (indent_level * 2 < indent_buf.len) indent_buf[0 .. indent_level * 2] else indent_buf[0..64];
    for (indent) |*c| c.* = ' ';

    try writer.print("{s}<symbol>\n", .{indent});
    try writer.print("{s}  <name>{s}</name>\n", .{ indent, sym.name });
    try writer.print("{s}  <kind>{d}</kind>\n", .{ indent, sym.kind });
    if (sym.detail) |d| try writer.print("{s}  <detail>{s}</detail>\n", .{ indent, d });
    try writer.print("{s}  <line>{d}</line>\n", .{ indent, sym.line });
    try writer.print("{s}  <character>{d}</character>\n", .{ indent, sym.character });
    if (sym.end_line) |v| try writer.print("{s}  <end_line>{d}</end_line>\n", .{ indent, v });
    if (sym.end_character) |v| try writer.print("{s}  <end_character>{d}</end_character>\n", .{ indent, v });
    if (sym.selection_line) |v| try writer.print("{s}  <selection_line>{d}</selection_line>\n", .{ indent, v });
    if (sym.selection_character) |v| try writer.print("{s}  <selection_character>{d}</selection_character>\n", .{ indent, v });

    if (sym.children) |children| {
        if (children.len > 0) {
            try writer.print("{s}  <children>\n", .{indent});
            for (children) |child| {
                try write_symbol_to_xml(writer, child, indent_level + 2);
            }
            try writer.print("{s}  </children>\n", .{indent});
        }
    }

    try writer.print("{s}</symbol>\n", .{indent});
}

pub fn execute_lsp_document_symbol(allocator: std.mem.Allocator, input: LspDocumentSymbolInput) !LspDocumentSymbolOutput {
    var session = try LspSession.init_with_file(allocator, input.lsp, input.file_path, input.root_dir);
    defer session.deinit();

    var buf = std.ArrayList(u8).empty;
    const w = buf.writer(session.arena_allocator);
    try w.print("{{", .{});
    try w.print("\"jsonrpc\":\"2.0\",", .{});
    try w.print("\"id\":2,", .{});
    try w.print("\"method\":\"textDocument/documentSymbol\",", .{});
    try w.print("\"params\":{{", .{});
    try w.print("\"textDocument\":{{\"uri\":\"{s}\"}}", .{session.uri});
    try w.print("}}}}", .{});
    const json_str = try buf.toOwnedSlice(session.arena_allocator);

    const response = try session.sendRequest(json_str, 2);
    var parsed = try json.parseFromSlice(json.Value, session.arena_allocator, response, .{});

    if (parsed.value != .object) return LspError.InvalidResponse;
    const result = parsed.value.object.get("result") orelse {
        return LspDocumentSymbolOutput{ .symbols = &.{}, .found = false };
    };

    return try parse_document_symbol_result(allocator, result, input.max_output);
}

pub fn lsp_document_symbol_to_string(allocator: std.mem.Allocator, result: LspDocumentSymbolOutput) ![]const u8 {
    if (!result.found or result.symbols.len == 0) {
        return try allocator.dupe(u8, "<found>false</found>");
    }

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    try w.print("<found>true</found>\n", .{});
    try w.print("<count>{d}</count>\n", .{result.symbols.len});
    try w.print("<symbols>\n", .{});

    for (result.symbols) |sym| {
        try write_symbol_to_xml(w, sym, 1);
    }

    try w.print("</symbols>", .{});
    return try output.toOwnedSlice(allocator);
}

pub const lsp_document_symbol_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_document_symbol",
        .description =
        \\Get all symbols in a specific document using LSP.
        \\Spawns lsp bin, initializes it, and queries textDocument/documentSymbol.
        \\Returns hierarchical symbol information for the document.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "lsp", .type = "string", .description = "LSP binary name like zls or pyls or path to binary" },
                .{ .name = "root_dir", .type = "string", .description = "Absolute path to the project root directory" },
                .{ .name = "file_path", .type = "string", .description = "Absolute path to the source file" },
                .{ .name = "max_output", .type = "number", .description = "Maximum number of results to return (default: 100)" },
            },
            .required = &.{ "lsp", "root_dir", "file_path" },
        },
    },
};

// =============================================================================
// LSP Hover
// =============================================================================

fn parse_hover_contents(allocator: std.mem.Allocator, contents: json.Value) !?[]u8 {
    switch (contents) {
        .string => return try allocator.dupe(u8, contents.string),
        .object => {
            const value_val = contents.object.get("value") orelse return null;
            if (value_val == .string) return try allocator.dupe(u8, value_val.string);
            return null;
        },
        .array => {
            var result = std.ArrayList(u8).empty;
            defer result.deinit(allocator);
            const w = result.writer(allocator);

            for (contents.array.items, 0..) |item, i| {
                if (i > 0) try w.print("\n\n", .{});
                switch (item) {
                    .string => try w.print("{s}", .{item.string}),
                    .object => {
                        if (item.object.get("value")) |v| {
                            if (v == .string) try w.print("{s}", .{v.string});
                        }
                    },
                    else => {},
                }
            }

            if (result.items.len > 0) return try result.toOwnedSlice(allocator);
            return null;
        },
        else => return null,
    }
}

fn parse_hover_result(allocator: std.mem.Allocator, result: json.Value) !LspHoverOutput {
    if (result == .null or result != .object) {
        return LspHoverOutput{ .contents = null, .found = false };
    }

    const obj = result.object;
    var contents: ?[]u8 = null;
    if (obj.get("contents")) |cv| {
        contents = try parse_hover_contents(allocator, cv);
    }

    var line: ?u32 = null;
    var character: ?u32 = null;
    var end_line: ?u32 = null;
    var end_character: ?u32 = null;

    if (obj.get("range")) |rv| {
        if (rv == .object) {
            if (rv.object.get("start")) |sv| {
                if (sv == .object) {
                    if (sv.object.get("line")) |lv| {
                        if (lv == .integer) line = @intCast(lv.integer);
                    }
                    if (sv.object.get("character")) |cv| {
                        if (cv == .integer) character = @intCast(cv.integer);
                    }
                }
            }
            if (rv.object.get("end")) |ev| {
                if (ev == .object) {
                    if (ev.object.get("line")) |lv| {
                        if (lv == .integer) end_line = @intCast(lv.integer);
                    }
                    if (ev.object.get("character")) |cv| {
                        if (cv == .integer) end_character = @intCast(cv.integer);
                    }
                }
            }
        }
    }

    return LspHoverOutput{
        .contents = contents,
        .line = line,
        .character = character,
        .end_line = end_line,
        .end_character = end_character,
        .found = contents != null,
    };
}

pub fn execute_lsp_hover(allocator: std.mem.Allocator, input: LspHoverInput) !LspHoverOutput {
    var session = try LspSession.init_with_file(allocator, input.lsp, input.file_path, input.root_dir);
    defer session.deinit();

    var buf = std.ArrayList(u8).empty;
    const w = buf.writer(session.arena_allocator);
    try w.print("{{", .{});
    try w.print("\"jsonrpc\":\"2.0\",", .{});
    try w.print("\"id\":2,", .{});
    try w.print("\"method\":\"textDocument/hover\",", .{});
    try w.print("\"params\":{{", .{});
    try w.print("\"textDocument\":{{\"uri\":\"{s}\"}},", .{session.uri});
    try w.print("\"position\":{{\"line\":{d},\"character\":{d}}}", .{ input.line, input.character });
    try w.print("}}}}", .{});
    const json_str = try buf.toOwnedSlice(session.arena_allocator);

    const response = try session.sendRequest(json_str, 2);
    var parsed = try json.parseFromSlice(json.Value, session.arena_allocator, response, .{});

    if (parsed.value != .object) return LspError.InvalidResponse;
    const result = parsed.value.object.get("result") orelse {
        return LspHoverOutput{ .contents = null, .found = false };
    };

    return try parse_hover_result(allocator, result);
}

pub fn lsp_hover_to_string(allocator: std.mem.Allocator, result: LspHoverOutput) ![]const u8 {
    if (!result.found or result.contents == null) {
        return try allocator.dupe(u8, "<found>false</found>");
    }

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    try w.print("<found>true</found>\n", .{});
    if (result.line) |v| try w.print("<line>{d}</line>\n", .{v});
    if (result.character) |v| try w.print("<character>{d}</character>\n", .{v});
    if (result.end_line) |v| try w.print("<end_line>{d}</end_line>\n", .{v});
    if (result.end_character) |v| try w.print("<end_character>{d}</end_character>\n", .{v});
    try w.print("<contents><![CDATA[{s}]]></contents>", .{result.contents.?});

    return try output.toOwnedSlice(allocator);
}

pub const lsp_hover_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_hover",
        .description =
        \\Get hover information (documentation/type info) for a symbol at cursor position using LSP.
        \\Spawns lsp bin, initializes it, and queries textDocument/hover.
        \\Returns hover contents with documentation and type information.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "lsp", .type = "string", .description = "LSP binary name like zls or pyls or path to binary" },
                .{ .name = "root_dir", .type = "string", .description = "Absolute path to the project root directory" },
                .{ .name = "file_path", .type = "string", .description = "Absolute path to the source file" },
                .{ .name = "line", .type = "number", .description = "Line number (0-indexed)" },
                .{ .name = "character", .type = "number", .description = "Character position (0-indexed)" },
            },
            .required = &.{ "lsp", "root_dir", "file_path", "line", "character" },
        },
    },
};

// =============================================================================
// Tests
// =============================================================================

test {
    _ = @import("lsp_definition_test.zig");
    _ = @import("lsp_references_test.zig");
    _ = @import("lsp_workspace_symbol_test.zig");
    _ = @import("lsp_document_symbol_test.zig");
    _ = @import("lsp_hover_test.zig");
}
