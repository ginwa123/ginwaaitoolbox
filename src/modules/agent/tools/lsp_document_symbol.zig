const std = @import("std");
const json = std.json;
const schemas = @import("schemas.zig");
const lsp_types = @import("lsp_types.zig");
const AgentTool = schemas.AgentTool;
pub const LspDocumentSymbolInput = lsp_types.LspDocumentSymbolInput;
const LspDocumentSymbolOutput = lsp_types.LspDocumentSymbolOutput;
const LspDocumentSymbol = lsp_types.LspDocumentSymbol;

// LSP error set
pub const LspError = error{
    FileNotFound,
    BinaryNotFound,
    ProcessSpawnFailed,
    InvalidResponse,
    SymbolsNotFound,
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

/// Parse a range object from JSON
fn parseRange(obj: json.ObjectMap) ?struct { line: u32, character: u32 } {
    const start_val = obj.get("start") orelse return null;
    if (start_val != .object) return null;

    const line_val = start_val.object.get("line") orelse return null;
    const char_val = start_val.object.get("character") orelse return null;
    if (line_val != .integer or char_val != .integer) return null;

    return .{
        .line = @intCast(line_val.integer),
        .character = @intCast(char_val.integer),
    };
}

/// Parse a single DocumentSymbol or SymbolInformation object recursively
fn parseDocumentSymbol(allocator: std.mem.Allocator, sym_value: json.Value) !?LspDocumentSymbol {
    if (sym_value != .object) return null;
    const obj = sym_value.object;

    // Get name
    const name_val = obj.get("name") orelse return null;
    if (name_val != .string) return null;

    // Get kind
    const kind_val = obj.get("kind") orelse return null;
    if (kind_val != .integer) return null;

    // Get detail (optional)
    var detail: ?[]u8 = null;
    const detail_val = obj.get("detail");
    if (detail_val) |dv| {
        if (dv == .string) {
            detail = try allocator.dupe(u8, dv.string);
        }
    }

    var line: u32 = 0;
    var character: u32 = 0;
    var end_line: ?u32 = null;
    var end_character: ?u32 = null;
    var selection_line: ?u32 = null;
    var selection_character: ?u32 = null;

    // Check if this is SymbolInformation (has location) or DocumentSymbol (has range directly)
    const loc_val = obj.get("location");
    if (loc_val) |loc| {
        // SymbolInformation format
        if (loc != .object) return null;

        const range_val = loc.object.get("range") orelse return null;
        if (range_val != .object) return null;

        const start = parseRange(range_val.object);
        if (start) |s| {
            line = s.line;
            character = s.character;
        }

        const end_val = range_val.object.get("end");
        if (end_val) |e| {
            if (e == .object) {
                const el = e.object.get("line");
                const ec = e.object.get("character");
                if (el) |l| {
                    if (l == .integer) end_line = @intCast(l.integer);
                }
                if (ec) |c| {
                    if (c == .integer) end_character = @intCast(c.integer);
                }
            }
        }
    } else {
        // DocumentSymbol format - has range directly
        const range_val = obj.get("range");
        if (range_val) |rv| {
            if (rv == .object) {
                const start = parseRange(rv.object);
                if (start) |s| {
                    line = s.line;
                    character = s.character;
                }

                const end_val = rv.object.get("end");
                if (end_val) |e| {
                    if (e == .object) {
                        const el = e.object.get("line");
                        const ec = e.object.get("character");
                        if (el) |l| {
                            if (l == .integer) end_line = @intCast(l.integer);
                        }
                        if (ec) |c| {
                            if (c == .integer) end_character = @intCast(c.integer);
                        }
                    }
                }
            }
        }

        // DocumentSymbol has selectionRange
        const sel_range_val = obj.get("selectionRange");
        if (sel_range_val) |srv| {
            if (srv == .object) {
                const sel_start = parseRange(srv.object);
                if (sel_start) |s| {
                    selection_line = s.line;
                    selection_character = s.character;
                }
            }
        }
    }

    // Parse children recursively
    var children: ?[]LspDocumentSymbol = null;
    const children_val = obj.get("children");
    if (children_val) |cv| {
        if (cv == .array) {
            var child_list = std.ArrayList(LspDocumentSymbol).empty;
            defer child_list.deinit(allocator);

            for (cv.array.items) |child_item| {
                const child = try parseDocumentSymbol(allocator, child_item);
                if (child) |c| {
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

/// Parse LSP document/symbol response result
fn parseDocumentSymbolResult(allocator: std.mem.Allocator, result: json.Value, max_output: ?u32) !LspDocumentSymbolOutput {
    if (result == .null) {
        return LspDocumentSymbolOutput{
            .symbols = &.{},
            .found = false,
        };
    }

    var symbols = std.ArrayList(LspDocumentSymbol).empty;
    defer symbols.deinit(allocator);

    const limit = max_output orelse 100;

    if (result == .array) {
        for (result.array.items) |item| {
            if (symbols.items.len >= limit) break;
            const sym = try parseDocumentSymbol(allocator, item);
            if (sym) |s| {
                try symbols.append(allocator, s);
            }
        }
    }

    const syms = try symbols.toOwnedSlice(allocator);

    return LspDocumentSymbolOutput{
        .symbols = syms,
        .found = syms.len > 0,
    };
}

/// Recursively write symbol to XML
fn writeSymbolToXml(writer: anytype, sym: LspDocumentSymbol, indent_level: u32) !void {
    // Build indentation string
    var indent_buf: [64]u8 = undefined;
    const indent = if (indent_level * 2 < indent_buf.len)
        indent_buf[0..indent_level * 2]
    else
        indent_buf[0..64];
    for (indent) |*c| c.* = ' ';

    try writer.print("{s}<symbol>\n", .{indent});
    try writer.print("{s}  <name>{s}</name>\n", .{ indent, sym.name });
    try writer.print("{s}  <kind>{d}</kind>\n", .{ indent, sym.kind });
    if (sym.detail) |d| {
        try writer.print("{s}  <detail>{s}</detail>\n", .{ indent, d });
    }
    try writer.print("{s}  <line>{d}</line>\n", .{ indent, sym.line });
    try writer.print("{s}  <character>{d}</character>\n", .{ indent, sym.character });
    if (sym.end_line) |el| {
        try writer.print("{s}  <end_line>{d}</end_line>\n", .{ indent, el });
    }
    if (sym.end_character) |ec| {
        try writer.print("{s}  <end_character>{d}</end_character>\n", .{ indent, ec });
    }
    if (sym.selection_line) |sl| {
        try writer.print("{s}  <selection_line>{d}</selection_line>\n", .{ indent, sl });
    }
    if (sym.selection_character) |sc| {
        try writer.print("{s}  <selection_character>{d}</selection_character>\n", .{ indent, sc });
    }

    // Recursively write children
    if (sym.children) |children| {
        if (children.len > 0) {
            try writer.print("{s}  <children>\n", .{indent});
            for (children) |child| {
                try writeSymbolToXml(writer, child, indent_level + 2);
            }
            try writer.print("{s}  </children>\n", .{indent});
        }
    }

    try writer.print("{s}</symbol>\n", .{indent});
}

pub fn executeLspDocumentSymbol(allocator: std.mem.Allocator, input: LspDocumentSymbolInput) !LspDocumentSymbolOutput {
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

    // Small delay to let LSP process the didOpen
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 4. Send documentSymbol request
    var symbol_json = std.ArrayList(u8).empty;
    const w = symbol_json.writer(arena_allocator);
    try w.print("{{", .{});
    try w.print("\"jsonrpc\":\"2.0\",", .{});
    try w.print("\"id\":2,", .{});
    try w.print("\"method\":\"textDocument/documentSymbol\",", .{});
    try w.print("\"params\":{{", .{});
    try w.print("\"textDocument\":{{\"uri\":\"{s}\"}}", .{uri});
    try w.print("}}}}", .{});

    const symbol_msg = try createMessage(arena_allocator, symbol_json.items);
    try stdin.writeAll(symbol_msg);

    // 5. Read documentSymbol response (may need to skip notifications)
    var symbol_response: []u8 = undefined;
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
                symbol_response = msg_data;
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
    var parsed = try json.parseFromSlice(json.Value, arena_allocator, symbol_response, .{});

    if (parsed.value != .object) return LspError.InvalidResponse;

    const result_opt = parsed.value.object.get("result");
    if (result_opt == null) {
        return LspDocumentSymbolOutput{
            .symbols = &.{},
            .found = false,
        };
    }

    // Use the original allocator for the final result (lives beyond this function)
    return try parseDocumentSymbolResult(allocator, result_opt.?, input.max_output);
}

pub fn lspDocumentSymbolToString(allocator: std.mem.Allocator, result: LspDocumentSymbolOutput) ![]const u8 {
    if (!result.found or result.symbols.len == 0) {
        return try allocator.dupe(u8, "<found>false</found>");
    }

    // Build XML string for symbols
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.print("<found>true</found>\n", .{});
    try writer.print("<count>{d}</count>\n", .{result.symbols.len});
    try writer.print("<symbols>\n", .{});

    for (result.symbols) |sym| {
        try writeSymbolToXml(writer, sym, 1);
    }

    try writer.print("</symbols>", .{});

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
                    .name = "max_output",
                    .type = "number",
                    .description = "Maximum number of results to return (default: 100)",
                },
            },
            .required = &.{ "lsp", "root_dir", "file_path" },
        },
    },
};

test {
    _ = @import("lsp_document_symbol_test.zig");
}
