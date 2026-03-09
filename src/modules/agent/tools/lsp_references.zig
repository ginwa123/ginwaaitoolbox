const std = @import("std");
const json = std.json;
const lsp_client_core = @import("lsp_client_core.zig");
const AgentTool = @import("models.zig").AgentTool;

// JSON-RPC references request with custom serialization
const ReferencesRequestParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
    context: Context,

    const TextDocumentIdentifier = struct {
        uri: []const u8,

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try jws.beginObject();
            try jws.objectField("uri");
            try jws.write(self.uri);
            try jws.endObject();
        }
    };

    const Position = struct {
        line: u32,
        character: u32,

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try jws.beginObject();
            try jws.objectField("line");
            try jws.write(self.line);
            try jws.objectField("character");
            try jws.write(self.character);
            try jws.endObject();
        }
    };

    const Context = struct {
        includeDeclaration: bool = true,
    };

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("textDocument");
        try jws.write(self.textDocument);
        try jws.objectField("position");
        try jws.write(self.position);
        try jws.objectField("context");
        try jws.write(self.context);
        try jws.endObject();
    }
};

const ReferencesRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: i32,
    method: []const u8 = "textDocument/references",
    params: ReferencesRequestParams,

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

pub const LspReferencesInput = struct {
    session_id: []const u8,
    file_uri: []const u8,
    line: u32,
    character: u32,
};

pub const LspReferencesOutput = struct {
    file_uri: []u8,
    line: u32,
    character: u32,
    references: []lsp_client_core.Location,
};

pub fn executeLspReferences(allocator: std.mem.Allocator, input: LspReferencesInput) !LspReferencesOutput {
    const sessions_ptr = lsp_client_core.getSessions();
    const client = sessions_ptr.get(input.session_id) orelse return lsp_client_core.LspError.SessionNotFound;

    if (!client.initialized) return lsp_client_core.LspError.NotInitialized;

    const request_id = client.next_request_id;
    client.next_request_id += 1;

    // Use arena allocator for JSON building
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Build references request using the struct with jsonStringify
    const params = ReferencesRequestParams{
        .textDocument = .{ .uri = input.file_uri },
        .position = .{ .line = input.line, .character = input.character },
        .context = .{ .includeDeclaration = true },
    };

    const request = ReferencesRequest{
        .id = request_id,
        .params = params,
    };

    // Serialize to JSON string
    var aw: std.io.Writer.Allocating = .init(arena_alloc);
    try aw.writer.print("{f}", .{std.json.fmt(request, .{})});
    const json_str = try aw.toOwnedSlice();
    defer arena_alloc.free(json_str);

    try lsp_client_core.writeMessage(client.stdin, json_str);

    // Read response
    const response = lsp_client_core.readMessage(client.stdout, allocator) catch return lsp_client_core.LspError.InvalidResponse;
    defer allocator.free(response);

    var parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
        return lsp_client_core.LspError.InvalidResponse;
    };
    defer parsed.deinit();

    var references = std.ArrayList(lsp_client_core.Location).empty;
    errdefer {
        for (references.items) |r| {
            allocator.free(r.uri);
        }
        references.deinit(allocator);
    }

    if (parsed.value == .object) {
        const result_opt = parsed.value.object.get("result");
        if (result_opt) |result_val| {
            // Handle null result
            if (result_val == .null) {
                return LspReferencesOutput{
                    .file_uri = try allocator.dupe(u8, input.file_uri),
                    .line = input.line,
                    .character = input.character,
                    .references = &.{},
                };
            }

            // result is Location[]
            if (result_val == .array) {
                for (result_val.array.items) |loc_val| {
                    if (loc_val != .object) continue;

                    const uri_opt = loc_val.object.get("uri");
                    if (uri_opt == null) continue;
                    const uri_val = uri_opt.?;

                    const range_opt = loc_val.object.get("range");
                    var start_line: u32 = 0;
                    var start_char: u32 = 0;
                    var end_line: u32 = 0;
                    var end_char: u32 = 0;

                    if (range_opt) |range_val| {
                        if (range_val == .object) {
                            const start_opt = range_val.object.get("start");
                            const end_opt = range_val.object.get("end");
                            if (start_opt) |s| {
                                if (s == .object) {
                                    const l = s.object.get("line");
                                    const c = s.object.get("character");
                                    if (l != null and l.? == .integer) start_line = @intCast(l.?.integer);
                                    if (c != null and c.? == .integer) start_char = @intCast(c.?.integer);
                                }
                            }
                            if (end_opt) |e| {
                                if (e == .object) {
                                    const l = e.object.get("line");
                                    const c = e.object.get("character");
                                    if (l != null and l.? == .integer) end_line = @intCast(l.?.integer);
                                    if (c != null and c.? == .integer) end_char = @intCast(c.?.integer);
                                }
                            }
                        }
                    }

                    const uri_str = if (uri_val == .string) uri_val.string else "";
                    try references.append(allocator, .{
                        .uri = try allocator.dupe(u8, uri_str),
                        .range = .{
                            .start = .{ .line = start_line, .character = start_char },
                            .end = .{ .line = end_line, .character = end_char },
                        },
                    });
                }
            }
        }
    }

    return .{
        .file_uri = try allocator.dupe(u8, input.file_uri),
        .line = input.line,
        .character = input.character,
        .references = references.items,
    };
}

pub fn lspReferencesToString(allocator: std.mem.Allocator, result: LspReferencesOutput) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "<file_uri>");
    try output.appendSlice(allocator, result.file_uri);
    try output.appendSlice(allocator, "</file_uri>\n<line>");
    try output.writer(allocator).print("{d}", .{result.line});
    try output.appendSlice(allocator, "</line>\n<character>");
    try output.writer(allocator).print("{d}", .{result.character});
    try output.appendSlice(allocator, "</character>\n<references>");

    for (result.references) |r| {
        try output.appendSlice(allocator, "<reference>");
        try output.appendSlice(allocator, "<uri>");
        try output.appendSlice(allocator, r.uri);
        try output.appendSlice(allocator, "</uri>");
        try output.appendSlice(allocator, "<range>");
        try output.writer(allocator).print("{}:{}:{d}:{d}", .{
            r.range.start.line, r.range.start.character, r.range.end.line, r.range.end.character
        });
        try output.appendSlice(allocator, "</range>");
        try output.appendSlice(allocator, "</reference>");
    }

    try output.appendSlice(allocator, "</references>");
    return try allocator.dupe(u8, output.items);
}

pub const lspReferencesTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_references",
        .description = "Find all references to symbol at cursor position",
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
                .{
                    .name = "line",
                    .type = "number",
                    .description = "Line number (0-indexed)",
                },
                .{
                    .name = "character",
                    .type = "number",
                    .description = "Character position (0-indexed)",
                },
            },
            .required = &.{ "session_id", "file_uri", "line", "character" },
        },
    },
};

test {
    _ = @import("lsp_references_test.zig");
}
