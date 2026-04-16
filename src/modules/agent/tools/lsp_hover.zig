const std = @import("std");
const json = std.json;
const schemas = @import("schemas.zig");
const lsp_types = @import("lsp_types.zig");
const AgentTool = schemas.AgentTool;
pub const LspHoverInput = lsp_types.LspHoverInput;
const LspHoverOutput = lsp_types.LspHoverOutput;

// LSP error set
pub const LspError = error{
    FileNotFound,
    BinaryNotFound,
    ProcessSpawnFailed,
    InvalidResponse,
    HoverNotFound,
};

// JSON-RPC message helpers
pub fn create_message(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ content.len, content });
}

// Read one JSON-RPC message from LSP stdout
fn read_message(allocator: std.mem.Allocator, stdout: std.fs.File) ![]u8 {
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

/// Parse hover contents which can be:
/// - string (plain text)
/// - { kind: "markdown" | "plaintext", value: string }
/// - string[] (array of strings)
/// - { kind: ..., value: ... }[] (array of marked strings)
fn parse_hover_contents(allocator: std.mem.Allocator, contents: json.Value) !?[]u8 {
    switch (contents) {
        .string => {
            return try allocator.dupe(u8, contents.string);
        },
        .object => {
            // { kind: "markdown" | "plaintext", value: string }
            const value_val = contents.object.get("value") orelse return null;
            if (value_val == .string) {
                return try allocator.dupe(u8, value_val.string);
            }
            return null;
        },
        .array => {
            // Array of strings or marked strings
            var result = std.ArrayList(u8).empty;
            defer result.deinit(allocator);
            const writer = result.writer(allocator);

            for (contents.array.items, 0..) |item, i| {
                if (i > 0) {
                    try writer.print("\n\n", .{});
                }

                switch (item) {
                    .string => {
                        try writer.print("{s}", .{item.string});
                    },
                    .object => {
                        const value_val = item.object.get("value") orelse continue;
                        if (value_val == .string) {
                            try writer.print("{s}", .{value_val.string});
                        }
                    },
                    else => {},
                }
            }

            if (result.items.len > 0) {
                return try result.toOwnedSlice(allocator);
            }
            return null;
        },
        else => return null,
    }
}

/// Parse LSP hover response result
fn parse_hover_result(allocator: std.mem.Allocator, result: json.Value) !LspHoverOutput {
    if (result == .null) {
        return LspHoverOutput{
            .contents = null,
            .found = false,
        };
    }

    if (result != .object) {
        return LspHoverOutput{
            .contents = null,
            .found = false,
        };
    }

    const obj = result.object;

    // Parse contents
    var contents: ?[]u8 = null;
    const contents_val = obj.get("contents");
    if (contents_val) |cv| {
        contents = try parse_hover_contents(allocator, cv);
    }

    // Parse range
    var line: ?u32 = null;
    var character: ?u32 = null;
    var end_line: ?u32 = null;
    var end_character: ?u32 = null;

    const range_val = obj.get("range");
    if (range_val) |rv| {
        if (rv == .object) {
            const start_val = rv.object.get("start");
            if (start_val) |sv| {
                if (sv == .object) {
                    const line_val = sv.object.get("line");
                    const char_val = sv.object.get("character");
                    if (line_val) |lv| {
                        if (lv == .integer) line = @intCast(lv.integer);
                    }
                    if (char_val) |cv| {
                        if (cv == .integer) character = @intCast(cv.integer);
                    }
                }
            }

            const end_v = rv.object.get("end");
            if (end_v) |ev| {
                if (ev == .object) {
                    const line_val = ev.object.get("line");
                    const char_val = ev.object.get("character");
                    if (line_val) |lv| {
                        if (lv == .integer) end_line = @intCast(lv.integer);
                    }
                    if (char_val) |cv| {
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
    const init_msg = try create_message(arena_allocator, init_json);
    try stdin.writeAll(init_msg);

    // Read initialize response (may need to skip notifications)
    var init_response: []u8 = undefined;
    var init_attempts: usize = 0;
    const max_init_attempts = 10;

    while (init_attempts < max_init_attempts) {
        const msg_data = try read_message(arena_allocator, stdout);

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
    const initialized_msg = try create_message(allocator,
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

    const didopen_msg = try create_message(arena_allocator, full_didopen);
    try stdin.writeAll(didopen_msg);

    // Small delay to let LSP process the didOpen
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 4. Send hover request
    var hover_json = std.ArrayList(u8).empty;
    const w = hover_json.writer(arena_allocator);
    try w.print("{{", .{});
    try w.print("\"jsonrpc\":\"2.0\",", .{});
    try w.print("\"id\":2,", .{});
    try w.print("\"method\":\"textDocument/hover\",", .{});
    try w.print("\"params\":{{", .{});
    try w.print("\"textDocument\":{{\"uri\":\"{s}\"}},", .{uri});
    try w.print("\"position\":{{\"line\":{d},\"character\":{d}}}", .{ input.line, input.character });
    try w.print("}}}}", .{});

    const hover_msg = try create_message(arena_allocator, hover_json.items);
    try stdin.writeAll(hover_msg);

    // 5. Read hover response (may need to skip notifications)
    var hover_response: []u8 = undefined;
    var attempts: usize = 0;
    const max_attempts = 10;

    while (attempts < max_attempts) {
        const msg_data = try read_message(arena_allocator, stdout);

        // Parse to check if this is the response with id: 2
        var temp_parsed = json.parseFromSlice(json.Value, arena_allocator, msg_data, .{}) catch {
            attempts += 1;
            continue;
        };

        if (temp_parsed.value.object.get("id")) |id_val| {
            if (id_val == .integer and id_val.integer == 2) {
                hover_response = msg_data;
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
    var parsed = try json.parseFromSlice(json.Value, arena_allocator, hover_response, .{});

    if (parsed.value != .object) return LspError.InvalidResponse;

    const result_opt = parsed.value.object.get("result");
    if (result_opt == null) {
        return LspHoverOutput{
            .contents = null,
            .found = false,
        };
    }

    // Use the original allocator for the final result (lives beyond this function)
    return try parse_hover_result(allocator, result_opt.?);
}

pub fn lsp_hover_to_string(allocator: std.mem.Allocator, result: LspHoverOutput) ![]const u8 {
    if (!result.found or result.contents == null) {
        return try allocator.dupe(u8, "<found>false</found>");
    }

    // Build XML string for hover info
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.print("<found>true</found>\n", .{});

    if (result.line) |line| {
        try writer.print("<line>{d}</line>\n", .{line});
    }
    if (result.character) |char| {
        try writer.print("<character>{d}</character>\n", .{char});
    }
    if (result.end_line) |el| {
        try writer.print("<end_line>{d}</end_line>\n", .{el});
    }
    if (result.end_character) |ec| {
        try writer.print("<end_character>{d}</end_character>\n", .{ec});
    }

    try writer.print("<contents><![CDATA[", .{});
    try writer.print("{s}", .{result.contents.?});
    try writer.print("]]></contents>", .{});

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
            },
            .required = &.{ "lsp", "root_dir", "file_path", "line", "character" },
        },
    },
};

test {
    _ = @import("lsp_hover_test.zig");
}
