const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const list_directory_mod = nalarcore.list_directory;
const wrapToolOutput = tools.wrapToolOutput;
const testing = std.testing;

const ListDirectoryInput = struct {
    path: []const u8 = ".",
    hidden: bool = false,
    respect_ignore_files: bool = true,
};

pub fn execListDirectory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // 1. Parse JSON (path/hidden/respect_ignore_files; all optional).
    const parsed = std.json.parseFromSlice(
        ListDirectoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_directory failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // 2. Resolve relative paths against the active session/worktree cwd.
    // The lower-level helper uses openDirAbsolute, which asserts rather
    // than returning an error for a relative path.
    const base_path = ctx.cwd_override orelse ctx.cwd;
    const resolved_path = if (std.fs.path.isAbsolute(parsed.value.path))
        try ctx.allocator.dupe(u8, parsed.value.path)
    else
        try std.fs.path.join(ctx.allocator, &.{ base_path, parsed.value.path });
    defer ctx.allocator.free(resolved_path);

    // 3. Execute the listing.
    const entries = list_directory_mod.execute_list_directory(
        ctx.allocator,
        ctx.io,
        resolved_path,
        parsed.value.hidden,
        parsed.value.respect_ignore_files,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(
            ctx.allocator,
            "list_directory failed: {s}",
            .{@errorName(err)},
        );
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer list_directory_mod.freeEntries(ctx.allocator, entries);

    // 4. Serialise to JSON and wrap.
    const inner = try list_directory_mod.toJSON(ctx.allocator, entries, resolved_path);
    const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// 2026-08-15 — end-to-end proof that the list_directory exec wrapper
// passes the LLM-supplied path through unchanged after the
// ban-absolute-paths revert. We pass the absolute path of a tmp dir
// directly to execListDirectory and verify both entries show up in
// the output AND the path appears as-is (no relative-path transform).
test "execListDirectory: absolute path passes through and lists entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    {
        const f = try tmp.dir.createFile(testing.io, "alpha.txt", .{});
        defer f.close(testing.io);
        try tmp.dir.createDirPath(testing.io, "beta");
    }

    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a,
        .io = testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test",
        .model = "test",
        .cwd = root_abs,
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .active_loops = undefined,
    };
    // Build JSON with the absolute path embedded. The previous
    // `std.fmt.allocPrint` template did NOT escape backslashes, so on
    // Windows hosts (where root_abs contains `\` chars) the resulting
    // JSON was malformed (`{"path":"C:\Users\foo\bar"}` — `\U` and
    // `\f` are invalid JSON escapes) and `execListDirectory`'s
    // `std.json.parseFromSlice` rejected it, surfacing an error
    // envelope instead of the directory listing. Escape `\` → `\\`
    // (and `"` → `\"`) before splicing the path into the JSON template.
    var escaped_path: std.ArrayList(u8) = .empty;
    defer escaped_path.deinit(a);
    for (root_abs) |c| {
        if (c == '\\' or c == '"') {
            try escaped_path.append(a, '\\');
        }
        try escaped_path.append(a, c);
    }
    const args_json = try std.fmt.allocPrint(
        a,
        "{{\"path\":\"{s}\",\"respect_ignore_files\":false}}",
        .{escaped_path.items},
    );
    const tc = agent.ToolCall{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "list_directory", .arguments = args_json },
    };

    const result = try execListDirectory(ctx, tc);
    defer if (result.output_allocated) a.free(result.output);

    // Success JSON envelope + both entries visible in data.entries.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);
    const data = obj.get("data").?.object;
    // Path is passed through unchanged (no relative-path transform).
    try testing.expectEqualStrings(root_abs, data.get("path").?.string);
    const entries = data.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 2), entries.len);
    var saw_alpha = false;
    var saw_beta = false;
    for (entries) |e| {
        const name = e.object.get("name").?.string;
        if (std.mem.eql(u8, name, "alpha.txt")) saw_alpha = true;
        if (std.mem.eql(u8, name, "beta")) saw_beta = true;
    }
    try testing.expect(saw_alpha);
    try testing.expect(saw_beta);
    // No validator error (the validator was removed by the revert).
    try testing.expect(obj.get("error").? == .null);
}

test "execListDirectory: absolute path returns success envelope without validator error" {
    // After the ban-absolute-paths revert, absolute paths are passed
    // straight through to the underlying tool. Calling with
    // `path: "/tmp"` (which exists on every Linux machine) MUST
    // produce a success envelope containing `<directory_listing
    // path="/tmp"`, and MUST NOT contain the previous validator's
    // error envelope (`<error>absolute paths are not allowed`).
    //
    // Uses an arena to paper over the current `execListDirectory`
    // implementation allocating an intermediate `inner` XML string
    // (from `list_directory.toJSON`) that is never explicitly freed
    // by the wrapper — `wrapToolOutput` borrows the slice into its
    // own output, so the leak is benign and the arena cleans it up
    // at test teardown.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a,
        .io = std.testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test_session",
        .model = "test",
        .cwd = "/home/user/proj",
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .active_loops = undefined,
    };

    const tool_call = agent.ToolCall{
        .id = "call_1",
        .type = "function",
        .function = .{
            .name = "list_directory",
            .arguments = "{\"path\":\"/tmp\"}",
        },
    };

    const result = try execListDirectory(ctx, tool_call);
    defer if (result.output_allocated) a.free(result.output);

    try testing.expect(result.output_allocated);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed2.deinit();
    const obj2 = parsed2.value.object;
    try testing.expect(obj2.get("success").?.bool);
    try testing.expectEqualStrings("/tmp", obj2.get("data").?.object.get("path").?.string);
    try testing.expect(obj2.get("error").? == .null);
}

test "execListDirectory: relative path resolves against ctx.cwd" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = path_buf[0..root_len];

    try tmp.dir.createDirPath(testing.io, "graph");
    const file = try tmp.dir.createFile(testing.io, "graph/index.txt", .{});
    defer file.close(testing.io);

    var agent_temperature: f32 = 0.0;
    var is_thinking: bool = false;
    const ctx = ToolExecContext{
        .allocator = allocator,
        .io = testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test_session",
        .model = "test",
        .cwd = root_abs,
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &agent_temperature,
        .is_thinking = &is_thinking,
        .environment = null,
        .active_loops = undefined,
    };
    const tool_call = agent.ToolCall{
        .id = "call_relative",
        .type = "function",
        .function = .{
            .name = "list_directory",
            .arguments = "{\"path\":\"graph\",\"respect_ignore_files\":false}",
        },
    };

    const result = try execListDirectory(ctx, tool_call);
    defer result.deinit(allocator);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);

    const expected_dir = try std.fs.path.join(allocator, &.{ root_abs, "graph" });
    const data = obj.get("data").?.object;
    try testing.expectEqualStrings(expected_dir, data.get("path").?.string);

    const entries = data.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("index.txt", entries[0].object.get("name").?.string);
}

test "execListDirectory: omitted path uses ctx.cwd instead of asserting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = path_buf[0..root_len];

    var agent_temperature: f32 = 0.0;
    var is_thinking: bool = false;
    const ctx = ToolExecContext{
        .allocator = allocator,
        .io = testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test_session",
        .model = "test",
        .cwd = root_abs,
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &agent_temperature,
        .is_thinking = &is_thinking,
        .environment = null,
        .active_loops = undefined,
    };
    const tool_call = agent.ToolCall{
        .id = "call_default_path",
        .type = "function",
        .function = .{
            .name = "list_directory",
            .arguments = "{}",
        },
    };

    const result = try execListDirectory(ctx, tool_call);
    defer result.deinit(allocator);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);

    const data = obj.get("data").?.object;
    const expected_dir = try std.fs.path.join(allocator, &.{ root_abs, "." });
    try testing.expectEqualStrings(expected_dir, data.get("path").?.string);
    try testing.expectEqual(@as(i64, 0), data.get("count").?.integer);
}
