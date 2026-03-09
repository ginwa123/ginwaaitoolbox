const std = @import("std");
const json = std.json;
const lsp_client_core = @import("lsp_client_core.zig");
const AgentTool = @import("models.zig").AgentTool;

// JSON-RPC didOpen notification with custom serialization
const DidOpenTextDocumentParams = struct {
    textDocument: TextDocumentItem,

    const TextDocumentItem = struct {
        uri: []const u8,
        languageId: []const u8 = "zig",
        version: i32 = 1,
        text: []const u8,

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try jws.beginObject();
            try jws.objectField("uri");
            try jws.write(self.uri);
            try jws.objectField("languageId");
            try jws.write(self.languageId);
            try jws.objectField("version");
            try jws.write(self.version);
            try jws.objectField("text");
            try jws.write(self.text);
            try jws.endObject();
        }
    };

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("textDocument");
        try jws.write(self.textDocument);
        try jws.endObject();
    }
};

const DidOpenNotification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8 = "textDocument/didOpen",
    params: DidOpenTextDocumentParams,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write(self.jsonrpc);
        try jws.objectField("method");
        try jws.write(self.method);
        try jws.objectField("params");
        try jws.write(self.params);
        try jws.endObject();
    }
};

pub const LspDiagnosticsInput = struct {
    session_id: []const u8,
    file_uri: []const u8,
};

pub const LspDiagnosticsOutput = struct {
    file_uri: []u8,
    diagnostics: []lsp_client_core.Diagnostic,
};

pub fn executeLspDiagnostics(allocator: std.mem.Allocator, input: LspDiagnosticsInput) !LspDiagnosticsOutput {
    const sessions_ptr = lsp_client_core.getSessions();
    const client = sessions_ptr.get(input.session_id) orelse return lsp_client_core.LspError.SessionNotFound;

    if (!client.initialized) return lsp_client_core.LspError.NotInitialized;

    // Read the file content
    const file_path = if (std.mem.startsWith(u8, input.file_uri, "file://"))
        input.file_uri[7..]
    else
        input.file_uri;

    const file_content = std.fs.cwd().readFileAlloc(allocator, file_path, std.math.maxInt(usize)) catch {
        return lsp_client_core.LspError.InvalidResponse;
    };
    defer allocator.free(file_content);

    // Use arena allocator for JSON building
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Build didOpen notification using std.json.fmt
    const text_document_item = DidOpenTextDocumentParams.TextDocumentItem{
        .uri = input.file_uri,
        .text = file_content,
    };
    const params = DidOpenTextDocumentParams{
        .textDocument = text_document_item,
    };
    const notification = DidOpenNotification{
        .params = params,
    };

    var aw: std.io.Writer.Allocating = .init(arena_alloc);
    try aw.writer.print("{f}", .{std.json.fmt(notification, .{})});
    const json_str = try aw.toOwnedSlice();
    defer arena_alloc.free(json_str);

    try lsp_client_core.writeMessage(client.stdin, json_str);

    // Wait for diagnostics notification
    var diagnostics = std.ArrayList(lsp_client_core.Diagnostic).empty;
    errdefer {
        for (diagnostics.items) |d| {
            allocator.free(d.message);
        }
        diagnostics.deinit(allocator);
    }

    // Read messages until we get diagnostics or timeout
    var timeout: usize = 0;
    while (timeout < 30) {
        const response = lsp_client_core.readMessage(client.stdout, allocator) catch break;
        defer allocator.free(response);

        var parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
            timeout += 1;
            continue;
        };
        defer parsed.deinit();

        // Check for method field
        if (parsed.value == .object) {
            const method_opt = parsed.value.object.get("method");
            if (method_opt) |method_val| {
                if (method_val == .string and std.mem.eql(u8, method_val.string, "textDocument/publishDiagnostics")) {
                    const params_opt = parsed.value.object.get("params");
                    if (params_opt) |params_val| {
                        const diags_opt = params_val.object.get("diagnostics");
                        if (diags_opt) |diags_val| {
                            if (diags_val == .array) {
                                for (diags_val.array.items) |diag_val| {
                                    if (diag_val != .object) continue;

                                    const msg_opt = diag_val.object.get("message");
                                    if (msg_opt == null or msg_opt.? != .string) continue;
                                    const msg = try allocator.dupe(u8, msg_opt.?.string);

                                    var severity: i32 = 1;
                                    const sev_opt = diag_val.object.get("severity");
                                    if (sev_opt) |sev| {
                                        if (sev == .integer) severity = @intCast(sev.integer);
                                    }

                                    const range_opt = diag_val.object.get("range");
                                    var start_line: u32 = 0;
                                    var start_char: u32 = 0;
                                    var end_line: u32 = 0;
                                    var end_char: u32 = 0;

                                    if (range_opt) |range_val| {
                                        if (range_val == .object) {
                                            const start_opt = range_val.object.get("start");
                                            if (start_opt) |start_val| {
                                                if (start_val == .object) {
                                                    const line_opt = start_val.object.get("line");
                                                    const char_opt = start_val.object.get("character");
                                                    if (line_opt != null and line_opt.? == .integer) start_line = @intCast(line_opt.?.integer);
                                                    if (char_opt != null and char_opt.? == .integer) start_char = @intCast(char_opt.?.integer);
                                                }
                                            }
                                            const end_opt = range_val.object.get("end");
                                            if (end_opt) |end_val| {
                                                if (end_val == .object) {
                                                    const line_opt = end_val.object.get("line");
                                                    const char_opt = end_val.object.get("character");
                                                    if (line_opt != null and line_opt.? == .integer) end_line = @intCast(line_opt.?.integer);
                                                    if (char_opt != null and char_opt.? == .integer) end_char = @intCast(char_opt.?.integer);
                                                }
                                            }
                                        }
                                    }

                                    try diagnostics.append(allocator, .{
                                        .severity = severity,
                                        .message = msg,
                                        .range = .{
                                            .start = .{ .line = start_line, .character = start_char },
                                            .end = .{ .line = end_line, .character = end_char },
                                        },
                                    });
                                }
                            }
                        }
                    }
                    break;
                }
            }
        }
        timeout += 1;
    }

    return .{
        .file_uri = try allocator.dupe(u8, input.file_uri),
        .diagnostics = diagnostics.items,
    };
}

pub fn lspDiagnosticsToString(allocator: std.mem.Allocator, result: LspDiagnosticsOutput) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "<file_uri>");
    try output.appendSlice(allocator, result.file_uri);
    try output.appendSlice(allocator, "</file_uri>\n<diagnostics>");

    for (result.diagnostics) |d| {
        try output.appendSlice(allocator, "<diagnostic>");
        try output.appendSlice(allocator, "<severity>");
        try output.writer(allocator).print("{d}", .{d.severity});
        try output.appendSlice(allocator, "</severity>");
        try output.appendSlice(allocator, "<message>");
        try output.appendSlice(allocator, d.message);
        try output.appendSlice(allocator, "</message>");
        try output.appendSlice(allocator, "<range>");
        try output.writer(allocator).print("{}:{}:{d}:{d}", .{
            d.range.start.line, d.range.start.character, d.range.end.line, d.range.end.character
        });
        try output.appendSlice(allocator, "</range>");
        try output.appendSlice(allocator, "</diagnostic>");
    }

    try output.appendSlice(allocator, "</diagnostics>");
    return try allocator.dupe(u8, output.items);
}

pub const lspDiagnosticsTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_diagnostics",
        .description = "Get errors/warnings for a file via textDocument/publishDiagnostics",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "session_id",
                    .type = "string",
                    .description = "Session identifier",
                },
                .{
                    .name = "file_uri",
                    .type = "string",
                    .description = "File URI (e.g., file:///path/to/file.zig)",
                },
            },
            .required = &.{ "session_id", "file_uri" },
        },
    },
};

test {
    _ = @import("lsp_definition_test.zig");
}
