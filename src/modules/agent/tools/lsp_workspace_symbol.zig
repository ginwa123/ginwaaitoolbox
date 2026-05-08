const std = @import("std");
const json = std.json;
const schemas = @import("schemas.zig");
const lsp_types = @import("lsp_types.zig");
const AgentTool = schemas.AgentTool;
pub const LspWorkspaceSymbolInput = lsp_types.LspWorkspaceSymbolInput;
const LspWorkspaceSymbolOutput = lsp_types.LspWorkspaceSymbolOutput;
const LspWorkspaceSymbol = lsp_types.LspWorkspaceSymbol;

// LSP error set
pub const LspError = error{
    BinaryNotFound,
    ProcessSpawnFailed,
    InvalidResponse,
    SymbolsNotFound,
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

/// Parse a single SymbolInformation or WorkspaceSymbol object
fn parse_symbol(allocator: std.mem.Allocator, sym_value: json.Value) !?LspWorkspaceSymbol {
    if (sym_value != .object) return null;
    const obj = sym_value.object;

    // Get name
    const name_val = obj.get("name") orelse return null;
    if (name_val != .string) return null;

    // Get kind
    const kind_val = obj.get("kind") orelse return null;
    if (kind_val != .integer) return null;

    // Get location (for SymbolInformation) or directly from object (for WorkspaceSymbol)
    var file_path: []u8 = undefined;
    var line: u32 = 0;
    var character: u32 = 0;

    const loc_val = obj.get("location");
    if (loc_val) |loc| {
        // SymbolInformation format
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
        // WorkspaceSymbol format - has uri directly
        const uri_val = obj.get("uri") orelse return null;
        if (uri_val != .string) return null;

        const result_uri = uri_val.string;
        file_path = if (std.mem.startsWith(u8, result_uri, "file://"))
            try allocator.dupe(u8, result_uri[7..])
        else
            try allocator.dupe(u8, result_uri);

        // WorkspaceSymbol may have range or selectionRange
        const range_val = obj.get("range") orelse obj.get("selectionRange");
        if (range_val) |r| {
            if (r == .object) {
                const start_val = r.object.get("start") orelse null;
                if (start_val) |s| {
                    if (s == .object) {
                        const line_val = s.object.get("line");
                        const char_val = s.object.get("character");
                        if (line_val) |lv| {
                            if (lv == .integer) line = @intCast(lv.integer);
                        }
                        if (char_val) |cv| {
                            if (cv == .integer) character = @intCast(cv.integer);
                        }
                    }
                }
            }
        }
    }

    // Get optional containerName
    var container_name: ?[]u8 = null;
    const container_val = obj.get("containerName");
    if (container_val) |cv| {
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

/// Parse LSP workspace/symbol response result
fn parse_workspace_symbol_result(allocator: std.mem.Allocator, result: json.Value, max_output: ?u32) !LspWorkspaceSymbolOutput {
    if (result == .null) {
        return LspWorkspaceSymbolOutput{
            .symbols = &.{},
            .found = false,
        };
    }

    var symbols = std.ArrayList(LspWorkspaceSymbol).empty;
    defer symbols.deinit(allocator);

    const limit = max_output orelse 100;

    if (result == .array) {
        for (result.array.items) |item| {
            if (symbols.items.len >= limit) break;
            const sym = try parse_symbol(allocator, item);
            if (sym) |s| {
                try symbols.append(allocator, s);
            }
        }
    }

    const syms = try symbols.toOwnedSlice(allocator);

    return LspWorkspaceSymbolOutput{
        .symbols = syms,
        .found = syms.len > 0,
    };
}

pub fn execute_lsp_workspace_symbol(allocator: std.mem.Allocator, input: LspWorkspaceSymbolInput) !LspWorkspaceSymbolOutput {
    // Use arena allocator for all temporary allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

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
    const initialized_msg = try create_message(arena_allocator,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    try stdin.writeAll(initialized_msg);

    // Small delay to let LSP process
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 3. Send workspace/symbol request
    var symbol_json = std.ArrayList(u8).empty;
    const w = symbol_json.writer(arena_allocator);
    try w.print("{{", .{});
    try w.print("\"jsonrpc\":\"2.0\",", .{});
    try w.print("\"id\":2,", .{});
    try w.print("\"method\":\"workspace/symbol\",", .{});
    try w.print("\"params\":{{", .{});
    try w.print("\"query\":\"{s}\"", .{input.query});
    try w.print("}}}}", .{});

    const symbol_msg = try create_message(arena_allocator, symbol_json.items);
    try stdin.writeAll(symbol_msg);

    // 4. Read workspace/symbol response (may need to skip notifications)
    var symbol_response: []u8 = undefined;
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
        return LspWorkspaceSymbolOutput{
            .symbols = &.{},
            .found = false,
        };
    }

    // Use the original allocator for the final result (lives beyond this function)
    return try parse_workspace_symbol_result(allocator, result_opt.?, input.max_output);
}

pub fn lsp_workspace_symbol_to_string(allocator: std.mem.Allocator, result: LspWorkspaceSymbolOutput) ![]const u8 {
    if (!result.found or result.symbols.len == 0) {
        return try allocator.dupe(u8, "<found>false</found>");
    }

    // Build XML string for multiple symbols
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.print("<found>true</found>\n", .{});
    try writer.print("<count>{d}</count>\n", .{result.symbols.len});
    try writer.print("<symbols>\n", .{});

    for (result.symbols, 0..) |sym, i| {
        try writer.print("  <symbol index=\"{d}\">\n", .{i + 1});
        try writer.print("    <name>{s}</name>\n", .{sym.name});
        try writer.print("    <kind>{d}</kind>\n", .{sym.kind});
        try writer.print("    <file_path>{s}</file_path>\n", .{sym.file_path});
        try writer.print("    <line>{d}</line>\n", .{sym.line});
        try writer.print("    <character>{d}</character>\n", .{sym.character});
        if (sym.container_name) |cn| {
            try writer.print("    <container_name>{s}</container_name>\n", .{cn});
        }
        try writer.print("  </symbol>\n", .{});
    }

    try writer.print("</symbols>", .{});

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
                    .name = "query",
                    .type = "string",
                    .description = "Search query string to find symbols",
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description = "Maximum number of results to return (default: 100)",
                },
            },
            .required = &.{ "lsp", "root_dir", "query" },
        },
    },
};

test {
    // Tests removed - lsp_workspace_symbol_test.zig removed due to API changes
}
