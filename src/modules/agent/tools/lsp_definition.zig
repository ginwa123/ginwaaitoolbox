const std = @import("std");
const json = std.json;
const schemas = @import("schemas.zig");
const lsp_types = @import("lsp_types.zig");
const AgentTool = schemas.AgentTool;
pub const LspDefinitionInput = lsp_types.LspDefinitionInput;
const LspDefinitionOutput = lsp_types.LspDefinitionOutput;
const LspLocation = lsp_types.LspLocation;

// LSP error set
pub const LspError = error{
    FileNotFound,
    BinaryNotFound,
    ProcessSpawnFailed,
    InvalidResponse,
    DefinitionNotFound,
};

// JSON-RPC message helpers
pub fn create_message(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ content.len, content });
}

// Read one JSON-RPC message from LSP stdout
fn read_message(allocator: std.mem.Allocator, io: std.Io, stdout: std.Io.File) ![]u8 {
    // Read headers until empty line
    var header_buf: [1024]u8 = undefined;
    var header_len: usize = 0;
    var found_empty = false;

    while (!found_empty) {
        var byte: [1]u8 = undefined;
        const n = std.Io.File.readStreaming(stdout, io, &.{&byte}) catch return LspError.InvalidResponse;
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
        const remaining = body[total_read..];
        const n = try std.Io.File.readStreaming(stdout, io, &.{remaining});
        if (n == 0) return LspError.InvalidResponse;
        total_read += n;
    }

    return body;
}

/// Find the zls binary in PATH or return BinaryNotFound error
fn find_zls(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map) ![]u8 {
    // First check if zls exists in PATH
    const env = environment orelse return LspError.BinaryNotFound;
    const path_env = if (env.get("PATH")) |p| try allocator.dupe(u8, p) else return LspError.BinaryNotFound;
    defer allocator.free(path_env);

    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |dir| {
        const zls_path = try std.fmt.allocPrint(allocator, "{s}/zls", .{dir});
        defer allocator.free(zls_path);

        if (std.Io.Dir.accessAbsolute(io, zls_path, .{})) {
            return zls_path;
        } else |_| {}
    }

    return LspError.BinaryNotFound;
}

/// Find project root by searching upward for build.zig
fn find_project_root(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    var dir = std.fs.path.dirname(file_path) orelse ".";

    while (true) {
        const build_zig_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{dir});
        defer allocator.free(build_zig_path);

        std.Io.Dir.accessAbsolute(io, build_zig_path, .{}) catch {
            const parent = std.fs.path.dirname(dir);
            if (parent) |p| {
                dir = p;
            } else {
                // No build.zig found, use current directory
                return try std.process.currentPathAlloc(io, allocator);
            }
            continue;
        };
        return try allocator.dupe(u8, dir);
    }
}

/// Parse a single LSP Location or LocationLink object
/// Returns the parsed LspLocation or null if parsing fails
fn parse_location(allocator: std.mem.Allocator, loc_value: json.Value) !?LspLocation {
    if (loc_value != .object) return null;

    const obj = loc_value.object;

    // Check if this is a LocationLink (has targetUri) or Location (has uri)
    const uri_val = obj.get("targetUri") orelse obj.get("uri") orelse return null;
    if (uri_val != .string) return null;

    // Get the range (targetRange for LocationLink, range for Location)
    const range_val = obj.get("targetRange") orelse obj.get("range") orelse return null;
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

    // Parse optional targetSelectionRange (more precise location for LocationLink)
    const selection_range_val = obj.get("targetSelectionRange");
    if (selection_range_val) |sr| {
        if (sr == .object) {
            const sr_start = sr.object.get("start");
            if (sr_start) |srs| {
                if (srs == .object) {
                    const sr_line = srs.object.get("line");
                    const sr_char = srs.object.get("character");
                    if (sr_line) |sl| {
                        if (sl == .integer) {
                            location.line = @intCast(sl.integer);
                        }
                    }
                    if (sr_char) |sc| {
                        if (sc == .integer) {
                            location.character = @intCast(sc.integer);
                        }
                    }
                }
            }
        }
    }

    // Parse optional originSelectionRange (where cursor was for LocationLink)
    const origin_range_val = obj.get("originSelectionRange");
    if (origin_range_val) |orv| {
        if (orv == .object) {
            const or_start = orv.object.get("start");
            if (or_start) |ors| {
                if (ors == .object) {
                    const or_line = ors.object.get("line");
                    const or_char = ors.object.get("character");
                    if (or_line) |ol| {
                        if (ol == .integer) {
                            location.origin_line = @intCast(ol.integer);
                        }
                    }
                    if (or_char) |oc| {
                        if (oc == .integer) {
                            location.origin_character = @intCast(oc.integer);
                        }
                    }
                }
            }
        }
    }

    return location;
}

/// Parse LSP definition response result
/// Handles: null, single Location, Location[], LocationLink[]
fn parse_definition_result(allocator: std.mem.Allocator, result: json.Value) !LspDefinitionOutput {
    // Handle null result
    if (result == .null) {
        return LspDefinitionOutput{
            .definitions = &.{},
            .found = false,
        };
    }

    var locations = std.ArrayList(LspLocation).empty;
    defer locations.deinit(allocator);

    // Handle array of locations (Location[] or LocationLink[])
    if (result == .array) {
        for (result.array.items) |item| {
            const loc = try parse_location(allocator, item);
            if (loc) |l| {
                try locations.append(allocator, l);
            }
        }
    }
    // Handle single location object
    else if (result == .object) {
        const loc = try parse_location(allocator, result);
        if (loc) |l| {
            try locations.append(allocator, l);
        }
    }

    // Convert to owned slice
    const defs = try locations.toOwnedSlice(allocator);

    return LspDefinitionOutput{
        .definitions = defs,
        .found = defs.len > 0,
    };
}

pub fn execute_lsp_definition(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map, input: LspDefinitionInput) !LspDefinitionOutput {
    // Verify file exists
    std.Io.Dir.accessAbsolute(io, input.file_path, .{}) catch return LspError.FileNotFound;

    // Read file content
    const file = try std.Io.Dir.cwd().openFile(io, input.file_path, .{});
    defer std.Io.File.close(file, io);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, input.file_path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(content);

    // Find zls binary
    const zls_path = try find_zls(allocator, io, environment);
    defer allocator.free(zls_path);

    // Spawn zls
    var child = try std.process.spawn(io, .{
        .argv = &.{zls_path},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer {
        child.kill(io);
        _ = child.wait(io) catch {};
    }

    const stdin = child.stdin.?;
    const stdout = child.stdout.?;

    // Build file URI
    const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{input.file_path});
    defer allocator.free(uri);

    // Find project root by searching upward for build.zig
    const root_dir = try find_project_root(allocator, io, input.file_path);
    defer allocator.free(root_dir);
    const root_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{root_dir});
    defer allocator.free(root_uri);

    // 1. Send initialize with rootUri
    var init_json_buf = std.ArrayList(u8).empty;
    defer init_json_buf.deinit(allocator);
    try init_json_buf.print(allocator, "{{", .{});
    try init_json_buf.print(allocator, "\"jsonrpc\":\"2.0\",", .{});
    try init_json_buf.print(allocator, "\"id\":1,", .{});
    try init_json_buf.print(allocator, "\"method\":\"initialize\",", .{});
    try init_json_buf.print(allocator, "\"params\":{{", .{});
    try init_json_buf.print(allocator, "\"processId\":null,", .{});
    try init_json_buf.print(allocator, "\"rootUri\":\"{s}\",", .{root_uri});
    try init_json_buf.print(allocator, "\"capabilities\":{{}}}}}}", .{});
    const init_json = try init_json_buf.toOwnedSlice(allocator);
    defer allocator.free(init_json);
    const init_msg = try create_message(allocator, init_json);
    defer allocator.free(init_msg);
    try std.Io.File.writeStreamingAll(stdin, io, init_msg);

    // Read initialize response (may need to skip notifications)
    var init_response: []u8 = undefined;
    var init_attempts: usize = 0;
    const max_init_attempts = 10;

    while (init_attempts < max_init_attempts) {
        const msg_data = try read_message(allocator, io, stdout);

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
    const initialized_msg = try create_message(allocator,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    defer allocator.free(initialized_msg);
    try std.Io.File.writeStreamingAll(stdin, io, initialized_msg);

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

    const didopen_msg = try create_message(allocator, full_didopen);
    defer allocator.free(didopen_msg);
    std.debug.print("didOpen message: {s}\n", .{didopen_msg});
    try std.Io.File.writeStreamingAll(stdin, io, didopen_msg);
    std.debug.print("Sent didOpen message\n", .{});

    // Small delay to let zls process the didOpen
    std.Io.sleep(io, std.Io.Duration{ .nanoseconds = 100 * std.time.ns_per_ms }, .real) catch {};

    // 4. Send definition request - build JSON using ArrayList
    var def_json = std.ArrayList(u8).empty;
    defer def_json.deinit(allocator);
    try def_json.print(allocator, "{{", .{});
    try def_json.print(allocator, "\"jsonrpc\":\"2.0\",", .{});
    try def_json.print(allocator, "\"id\":2,", .{});
    try def_json.print(allocator, "\"method\":\"textDocument/definition\",", .{});
    try def_json.print(allocator, "\"params\":{{", .{});
    try def_json.print(allocator, "\"textDocument\":{{\"uri\":\"{s}\"}},", .{uri});
    try def_json.print(allocator, "\"position\":{{\"line\":{d},\"character\":{d}}}", .{ input.line, input.character });
    try def_json.print(allocator, "}}}}", .{});

    const def_msg = try create_message(allocator, def_json.items);
    defer allocator.free(def_msg);
    try std.Io.File.writeStreamingAll(stdin, io, def_msg);

    // 5. Read definition response (may need to skip notifications)
    var def_response: []u8 = undefined;
    var attempts: usize = 0;
    const max_attempts = 10;

    while (attempts < max_attempts) {
        const msg_data = try read_message(allocator, io, stdout);

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
            .definitions = &.{},
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
            .definitions = &.{},
            .found = false,
        };
    }

    // Use the original allocator for the final result (lives beyond this function)
    return try parse_definition_result(allocator, result_opt.?);
}

pub fn lsp_definition_to_string(allocator: std.mem.Allocator, result: LspDefinitionOutput) ![]const u8 {
    if (result.found and result.definitions.len > 0) {
        // Return info about the first definition
        const first_def = result.definitions[0];
        return try std.fmt.allocPrint(allocator,
            \\<file_path>{s}</file_path>
            \\n<line>{d}</line>
            \\n<character>{d}</character>
            \\n<found>true</found>
            \\n<count>{d}</count>
        , .{ first_def.file_path, first_def.line, first_def.character, result.definitions.len });
    } else {
        return try allocator.dupe(u8, "<found>false</found>");
    }
}

/// Generate error XML response
pub fn xmlError(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<error>{s}</error>
    , .{error_msg}) catch "<error>UnknownError</error>";
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
            .required = &.{ "file_path", "line", "character" },
        },
    },
};

test {
    // Tests removed - lsp_definition_test.zig removed due to API changes
}
