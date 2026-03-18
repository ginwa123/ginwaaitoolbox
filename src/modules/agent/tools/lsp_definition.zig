const std = @import("std");
const json = std.json;
const AgentTool = @import("models.zig").AgentTool;
pub const LspDefinitionInput = @import("models.zig").LspDefinitionInput;
const LspDefinitionOutput = @import("models.zig").LspDefinitionOutput;

// LSP error set
pub const LspError = error{
    FileNotFound,
    BinaryNotFound,
    ProcessSpawnFailed,
    InvalidResponse,
    DefinitionNotFound,
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

pub fn executeLspDefinition(allocator: std.mem.Allocator, input: LspDefinitionInput) !LspDefinitionOutput {
    // Verify file exists
    std.fs.accessAbsolute(input.file_path, .{}) catch return LspError.FileNotFound;

    // Read file content
    const file = try std.fs.cwd().openFile(input.file_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Use provided LSP binary directly
    var child = std.process.Child.init(&.{input.lsp}, allocator);
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

    // Build file URI
    const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{input.file_path});
    defer allocator.free(uri);

    // Use provided root_dir directly
    const root_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{input.root_dir});
    defer allocator.free(root_uri);

    // 1. Send initialize with rootUri
    var init_json_buf = std.ArrayList(u8).empty;
    defer init_json_buf.deinit(allocator);
    const init_writer = init_json_buf.writer(allocator);
    try init_writer.print("{{", .{});
    try init_writer.print("\"jsonrpc\":\"2.0\",", .{});
    try init_writer.print("\"id\":1,", .{});
    try init_writer.print("\"method\":\"initialize\",", .{});
    try init_writer.print("\"params\":{{", .{});
    try init_writer.print("\"processId\":null,", .{});
    try init_writer.print("\"rootUri\":\"{s}\",", .{root_uri});
    try init_writer.print("\"capabilities\":{{}}}}}}", .{});
    const init_json = try init_json_buf.toOwnedSlice(allocator);
    defer allocator.free(init_json);
    const init_msg = try createMessage(allocator, init_json);
    defer allocator.free(init_msg);
    try stdin.writeAll(init_msg);

    // Read initialize response (may need to skip notifications)
    var init_response: []u8 = undefined;
    var init_attempts: usize = 0;
    const max_init_attempts = 10;

    while (init_attempts < max_init_attempts) {
        const msg_data = try readMessage(allocator, stdout);

        // Parse to check if this is the response with id: 1
        var temp_parsed = json.parseFromSlice(json.Value, allocator, msg_data, .{}) catch {
            allocator.free(msg_data);
            init_attempts += 1;
            continue;
        };
        defer temp_parsed.deinit();

        if (temp_parsed.value.object.get("id")) |id_val| {
            if (id_val == .integer and id_val.integer == 1) {
                init_response = msg_data;
                break;
            }
        }

        // Not the response we're looking for, free and continue
        allocator.free(msg_data);
        init_attempts += 1;
    }

    if (init_attempts >= max_init_attempts) {
        return LspError.InvalidResponse;
    }
    defer allocator.free(init_response);
    std.debug.print("LSP init response: {s}\n", .{init_response});

    // 2. Send initialized notification
    const initialized_msg = try createMessage(allocator,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    defer allocator.free(initialized_msg);
    try stdin.writeAll(initialized_msg);

    // 3. Send didOpen - build JSON manually for simplicity
    const didopen_json = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","languageId":"zig","version":1,"text":"
    , .{uri});
    defer allocator.free(didopen_json);

    // Escape the content for JSON
    var escaped_content = std.ArrayList(u8).empty;
    defer escaped_content.deinit(allocator);
    for (content) |c| {
        switch (c) {
            '\\' => try escaped_content.appendSlice(allocator, "\\\\"),
            '"' => try escaped_content.appendSlice(allocator, "\\\""),
            '\n' => try escaped_content.appendSlice(allocator, "\\n"),
            '\r' => try escaped_content.appendSlice(allocator, "\\r"),
            '\t' => try escaped_content.appendSlice(allocator, "\\t"),
            else => try escaped_content.append(allocator, c),
        }
    }

    const didopen_end = "\"}}}}";
    // Note: closing is: "}}}} which is: quote + 4 closing braces for JSON structure

    const full_didopen = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ didopen_json, escaped_content.items, didopen_end });
    defer allocator.free(full_didopen);

    const didopen_msg = try createMessage(allocator, full_didopen);
    defer allocator.free(didopen_msg);
    std.debug.print("didOpen message: {s}\n", .{didopen_msg});
    try stdin.writeAll(didopen_msg);
    std.debug.print("Sent didOpen message\n", .{});

    // Small delay to let zls process the didOpen
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 4. Send definition request - build JSON using ArrayList
    var def_json = std.ArrayList(u8).empty;
    defer def_json.deinit(allocator);
    const w = def_json.writer(allocator);
    try w.print("{{", .{});
    try w.print("\"jsonrpc\":\"2.0\",", .{});
    try w.print("\"id\":2,", .{});
    try w.print("\"method\":\"textDocument/definition\",", .{});
    try w.print("\"params\":{{", .{});
    try w.print("\"textDocument\":{{\"uri\":\"{s}\"}},", .{uri});
    try w.print("\"position\":{{\"line\":{d},\"character\":{d}}}", .{ input.line, input.character });
    try w.print("}}}}", .{});

    const def_msg = try createMessage(allocator, def_json.items);
    defer allocator.free(def_msg);
    try stdin.writeAll(def_msg);

    // 5. Read definition response (may need to skip notifications)
    var def_response: []u8 = undefined;
    var attempts: usize = 0;
    const max_attempts = 10;

    while (attempts < max_attempts) {
        const msg_data = try readMessage(allocator, stdout);

        // Parse to check if this is the response with id: 2
        var temp_parsed = json.parseFromSlice(json.Value, allocator, msg_data, .{}) catch {
            allocator.free(msg_data);
            attempts += 1;
            continue;
        };
        defer temp_parsed.deinit();

        if (temp_parsed.value.object.get("id")) |id_val| {
            if (id_val == .integer and id_val.integer == 2) {
                def_response = msg_data;
                break;
            }
        }

        // Not the response we're looking for, free and continue
        allocator.free(msg_data);
        attempts += 1;
    }

    if (attempts >= max_attempts) {
        return LspError.InvalidResponse;
    }
    defer allocator.free(def_response);

    // Parse response
    var parsed = try json.parseFromSlice(json.Value, allocator, def_response, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return LspError.InvalidResponse;

    const result_opt = parsed.value.object.get("result");
    if (result_opt == null or result_opt.? == .null) {
        return LspDefinitionOutput{
            .file_path = try allocator.dupe(u8, ""),
            .line = 0,
            .character = 0,
            .found = false,
        };
    }

    const result = result_opt.?;

    // Handle single location or array
    var loc_obj: ?json.Value = null;
    if (result == .object) {
        loc_obj = result;
    } else if (result == .array and result.array.items.len > 0) {
        loc_obj = result.array.items[0];
    }

    if (loc_obj == null or loc_obj.? != .object) {
        return LspDefinitionOutput{
            .file_path = try allocator.dupe(u8, ""),
            .line = 0,
            .character = 0,
            .found = false,
        };
    }

    const obj = loc_obj.?;
    const uri_val = obj.object.get("uri") orelse return LspError.InvalidResponse;
    const range_val = obj.object.get("range") orelse return LspError.InvalidResponse;

    if (uri_val != .string or range_val != .object) return LspError.InvalidResponse;

    const start_val = range_val.object.get("start") orelse return LspError.InvalidResponse;
    if (start_val != .object) return LspError.InvalidResponse;

    const line_val = start_val.object.get("line") orelse return LspError.InvalidResponse;
    const char_val = start_val.object.get("character") orelse return LspError.InvalidResponse;

    if (line_val != .integer or char_val != .integer) return LspError.InvalidResponse;

    // Extract file path from URI
    const result_uri = uri_val.string;
    const result_path = if (std.mem.startsWith(u8, result_uri, "file://"))
        result_uri[7..]
    else
        result_uri;

    return LspDefinitionOutput{
        .file_path = try allocator.dupe(u8, result_path),
        .line = @intCast(line_val.integer),
        .character = @intCast(char_val.integer),
        .found = true,
    };
}

pub fn lspDefinitionToString(allocator: std.mem.Allocator, result: LspDefinitionOutput) ![]const u8 {
    if (result.found) {
        return try std.fmt.allocPrint(allocator,
            \\<file_path>{s}</file_path>
            \\n<line>{d}</line>
            \\n<character>{d}</character>
            \\n<found>true</found>
        , .{ result.file_path, result.line, result.character });
    } else {
        return try allocator.dupe(u8, "<found>false</found>");
    }
}

pub const lspDefinitionTool = AgentTool{
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
                .{
                    .name = "lsp",
                    .type = "string",
                    .description = "lsp bin name like zls or pyls or path to binary",
                },
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
    _ = @import("lsp_definition_test.zig");
}
