const std = @import("std");
const json = std.json;
const schemas = @import("schemas.zig");
const lsp_types = @import("lsp_types.zig");
const AgentTool = schemas.AgentTool;
pub const LspReferencesInput = lsp_types.LspReferencesInput;
const LspReferencesOutput = lsp_types.LspReferencesOutput;
const LspLocation = lsp_types.LspLocation;

// LSP error set
pub const LspError = error{
    FileNotFound,
    BinaryNotFound,
    ProcessSpawnFailed,
    InvalidResponse,
    ReferencesNotFound,
};

// JSON-RPC message helpers
pub fn createMessage(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ content.len, content });
}

// Read one JSON-RPC message from LSP stdout
fn readMessage(allocator: std.mem.Allocator, stdout: std.fs.File) ![]u8 {
    // Read headers until empty line
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

        // Check for \r\n\r\n
        if (header_len >= 4) {
            const end = header_buf[header_len - 4 .. header_len];
            if (std.mem.eql(u8, end, "\r\n\r\n")) {
                found_empty = true;
            }
        }
    }

    // Parse Content-Length
    const header = header_buf[0..header_len];
    const prefix = "Content-Length: ";
    const start = std.mem.indexOf(u8, header, prefix) orelse return LspError.InvalidResponse;
    const end = std.mem.indexOf(u8, header[start..], "\r\n") orelse return LspError.InvalidResponse;
    const len_str = header[start + prefix.len .. start + end];
    const content_len = std.fmt.parseInt(usize, len_str, 10) catch return LspError.InvalidResponse;

    // Read body
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

/// Parse a single LSP Location object
/// Returns the parsed LspLocation or null if parsing fails
fn parseLocation(allocator: std.mem.Allocator, loc_value: json.Value) !?LspLocation {
    if (loc_value != .object) return null;

    const obj = loc_value.object;

    // Location has "uri" (not targetUri like LocationLink)
    const uri_val = obj.get("uri") orelse return null;
    if (uri_val != .string) return null;

    const range_val = obj.get("range") orelse return null;
    if (range_val != .object) return null;

    const start_val = range_val.object.get("start") orelse return null;
    if (start_val != .object) return null;

    const line_val = start_val.object.get("line") orelse return null;
    const char_val = start_val.object.get("character") orelse return null;
    if (line_val != .integer or char_val != .integer) return null;

    // Extract file path from URI
    const result_uri = uri_val.string;
    const result_path = if (std.mem.startsWith(u8, result_uri, "file://"))
        result_uri[7..]
    else
        result_uri;

    var location = LspLocation{
        .file_path = try allocator.dupe(u8, result_path),
        .line = @intCast(line_val.integer),
        .character = @intCast(char_val.integer),
    };

    // Parse optional end position
    const end_val = range_val.object.get("end");
    if (end_val) |end| {
        if (end == .object) {
            const end_line = end.object.get("line");
            const end_char = end.object.get("character");
            if (end_line) |el| {
                if (el == .integer) {
                    location.end_line = @intCast(el.integer);
                }
            }
            if (end_char) |ec| {
                if (ec == .integer) {
                    location.end_character = @intCast(ec.integer);
                }
            }
        }
    }

    return location;
}

/// Parse LSP references response result
/// References always returns: null or Location[]
fn parseReferencesResult(allocator: std.mem.Allocator, result: json.Value, max_output: ?u32) !LspReferencesOutput {
    // Handle null result
    if (result == .null) {
        return LspReferencesOutput{
            .definitions = &.{},
            .found = false,
        };
    }

    var locations = std.ArrayList(LspLocation).empty;
    defer locations.deinit(allocator);

    const limit = max_output orelse 100;

    // References always returns an array of Location
    if (result == .array) {
        for (result.array.items) |item| {
            if (locations.items.len >= limit) break;
            const loc = try parseLocation(allocator, item);
            if (loc) |l| {
                try locations.append(allocator, l);
            }
        }
    }

    const refs = try locations.toOwnedSlice(allocator);

    return LspReferencesOutput{
        .definitions = refs,
        .found = refs.len > 0,
    };
}

pub fn executeLspReferences(allocator: std.mem.Allocator, input: LspReferencesInput) !LspReferencesOutput {
    // Use arena allocator for all temporary allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Verify file exists
    std.fs.accessAbsolute(input.file_path, .{}) catch return LspError.FileNotFound;

    // Read file content (temporary - goes in arena)
    const file = try std.fs.cwd().openFile(input.file_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(arena_allocator, 1024 * 1024);

    // Use provided LSP binary directly (arena for process setup)
    var child = std.process.Child.init(&.{input.lsp}, arena_allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    defer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const stdin = child.stdin.?;
    const stdout = child.stdout.?;

    // Build file URI (temporary - goes in arena)
    const uri = try std.fmt.allocPrint(arena_allocator, "file://{s}", .{input.file_path});

    // Use provided root_dir directly (temporary - goes in arena)
    const root_uri = try std.fmt.allocPrint(arena_allocator, "file://{s}", .{input.root_dir});

    // 1. Send initialize with rootUri
    var init_json_buf = std.ArrayList(u8).empty;
    const init_writer = init_json_buf.writer(arena_allocator);
    try init_writer.print("{{", .{});
    try init_writer.print("\"jsonrpc\":\"2.0\",", .{});
    try init_writer.print("\"id\":1,", .{});
    try init_writer.print("\"method\":\"initialize\",", .{});
    try init_writer.print("\"params\":{{", .{});
    try init_writer.print("\"processId\":null,", .{});
    try init_writer.print("\"rootUri\":\"{s}\",", .{root_uri});
    try init_writer.print("\"capabilities\":{{}}}}}}", .{});
    const init_json = try init_json_buf.toOwnedSlice(arena_allocator);
    const init_msg = try createMessage(arena_allocator, init_json);
    try stdin.writeAll(init_msg);

    // Read initialize response (may need to skip notifications)
    var init_response: []u8 = undefined;
    var init_attempts: usize = 0;
    const max_init_attempts = 10;

    while (init_attempts < max_init_attempts) {
        const msg_data = try readMessage(arena_allocator, stdout);

        // Parse to check if this is the response with id: 1
        var temp_parsed = json.parseFromSlice(json.Value, arena_allocator, msg_data, .{}) catch {
            init_attempts += 1;
            continue;
        };

        if (temp_parsed.value.object.get("id")) |id_val| {
            if (id_val == .integer and id_val.integer == 1) {
                init_response = msg_data;
                break;
            }
        }

        // Not the response we're looking for, continue
        init_attempts += 1;
    }

    if (init_attempts >= max_init_attempts) {
        return LspError.InvalidResponse;
    }

    // 2. Send initialized notification
    const initialized_msg = try createMessage(arena_allocator,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    try stdin.writeAll(initialized_msg);

    // 3. Send didOpen - build JSON manually for simplicity
    const didopen_json = try std.fmt.allocPrint(arena_allocator,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","languageId":"zig","version":1,"text":"
    , .{uri});

    // Escape the content for JSON
    var escaped_content = std.ArrayList(u8).empty;
    const escaped_writer = escaped_content.writer(arena_allocator);
    for (content) |c| {
        switch (c) {
            '\\' => try escaped_writer.print("\\\\", .{}),
            '"' => try escaped_writer.print("\\\"", .{}),
            '\n' => try escaped_writer.print("\\n", .{}),
            '\r' => try escaped_writer.print("\\r", .{}),
            '\t' => try escaped_writer.print("\\t", .{}),
            else => try escaped_writer.print("{c}", .{c}),
        }
    }

    const didopen_end = "\"}}}}";
    const full_didopen = try std.fmt.allocPrint(arena_allocator, "{s}{s}{s}", .{ didopen_json, escaped_content.items, didopen_end });

    const didopen_msg = try createMessage(arena_allocator, full_didopen);
    try stdin.writeAll(didopen_msg);

    // Small delay to let zls process the didOpen
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 4. Send references request - build JSON using ArrayList
    var refs_json = std.ArrayList(u8).empty;
    const w = refs_json.writer(arena_allocator);
    try w.print("{{", .{});
    try w.print("\"jsonrpc\":\"2.0\",", .{});
    try w.print("\"id\":2,", .{});
    try w.print("\"method\":\"textDocument/references\",", .{});
    try w.print("\"params\":{{", .{});
    try w.print("\"textDocument\":{{\"uri\":\"{s}\"}},", .{uri});
    try w.print("\"position\":{{\"line\":{d},\"character\":{d}}},", .{ input.line, input.character });
    try w.print("\"context\":{{\"includeDeclaration\":{}}}", .{input.include_declaration});
    try w.print("}}}}", .{});

    const refs_msg = try createMessage(arena_allocator, refs_json.items);
    try stdin.writeAll(refs_msg);

    // 5. Read references response (may need to skip notifications)
    var refs_response: []u8 = undefined;
    var attempts: usize = 0;
    const max_attempts = 10;

    while (attempts < max_attempts) {
        const msg_data = try readMessage(arena_allocator, stdout);

        // Parse to check if this is the response with id: 2
        var temp_parsed = json.parseFromSlice(json.Value, arena_allocator, msg_data, .{}) catch {
            attempts += 1;
            continue;
        };

        if (temp_parsed.value.object.get("id")) |id_val| {
            if (id_val == .integer and id_val.integer == 2) {
                refs_response = msg_data;
                break;
            }
        }

        // Not the response we're looking for, continue
        attempts += 1;
    }

    if (attempts >= max_attempts) {
        return LspError.InvalidResponse;
    }

    // Parse response
    var parsed = try json.parseFromSlice(json.Value, arena_allocator, refs_response, .{});

    if (parsed.value != .object) return LspError.InvalidResponse;

    const result_opt = parsed.value.object.get("result");
    if (result_opt == null) {
        return LspReferencesOutput{
            .definitions = &.{},
            .found = false,
        };
    }

    // Use the original allocator for the final result (lives beyond this function)
    return try parseReferencesResult(allocator, result_opt.?, input.max_output);
}

pub fn lspReferencesToString(allocator: std.mem.Allocator, result: LspReferencesOutput) ![]const u8 {
    if (!result.found or result.definitions.len == 0) {
        return try allocator.dupe(u8, "<found>false</found>");
    }

    // Build XML string for multiple references
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.print("<found>true</found>\n", .{});
    try writer.print("<count>{d}</count>\n", .{result.definitions.len});
    try writer.print("<references>\n", .{});

    for (result.definitions, 0..) |def, i| {
        try writer.print("  <reference index=\"{d}\">\n", .{i + 1});
        try writer.print("    <file_path>{s}</file_path>\n", .{def.file_path});
        try writer.print("    <line>{d}</line>\n", .{def.line});
        try writer.print("    <character>{d}</character>\n", .{def.character});
        if (def.end_line) |end_line| {
            try writer.print("    <end_line>{d}</end_line>\n", .{end_line});
        }
        if (def.end_character) |end_char| {
            try writer.print("    <end_character>{d}</end_character>\n", .{end_char});
        }
        try writer.print("  </reference>\n", .{});
    }

    try writer.print("</references>", .{});

    return try output.toOwnedSlice(allocator);
}

pub const lspReferencesTool = AgentTool{
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
                .{
                    .name = "lsp",
                    .type = "string",
                    .description = "LSP binary name like zls or pyls or path to binary",
                },
                .{
                    .name = "root_dir",
                    .type = "string",
                    .description = "Absolute path to the project root directory",
                },
                .{
                    .name = "file_path",
                    .type = "string",
                    .description = "Absolute path to the source file",
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
                .{
                    .name = "include_declaration",
                    .type = "boolean",
                    .description = "Include the declaration location in results (default: true)",
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description = "Maximum number of results to return (default: 100)",
                },
            },
            .required = &.{ "lsp", "root_dir", "file_path", "line", "character" },
        },
    },
};

test {
    _ = @import("lsp_references_test.zig");
}
