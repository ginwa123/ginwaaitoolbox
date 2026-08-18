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

    // 2. Security: reject absolute paths.
    if (try nalarcore.path_security.rejectAbsolutePath(
        ctx.allocator, "list_directory", "path", parsed.value.path, ctx.cwd
    )) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // 3. Resolve path: relative/null/empty → ctx.cwd_override ?? ctx.cwd.
    const resolved_path = try nalarcore.path_security.resolveCwd(
        ctx.allocator, ctx.cwd, ctx.cwd_override, parsed.value.path
    );
    defer ctx.allocator.free(resolved_path);

    // 4. Execute the listing.
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

    // 5. Serialise to XML and wrap.
    const inner = try list_directory_mod.toXml(ctx.allocator, entries, resolved_path);
    const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// 2026-08-14 — end-to-end proof that RELATIVE paths work on every
// tool wired with the absolute-path ban (PR #259 follow-up).
test "execListDirectory: relative path '.' resolves and lists entries" {
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
        .allocator = a, .io = testing.io, .db = undefined,
        .logger = undefined, .session_id = "test", .model = "test",
        .cwd = root_abs, .api_key = "test", .base_url = "test",
        .config = undefined, .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool, .environment = null,
        .active_loops = undefined,
    };
    const tc = agent.ToolCall{
        .id = "call_1", .type = "function",
        .function = .{ .name = "list_directory", .arguments = "{\"path\":\".\",\"respect_ignore_files\":false}" },
    };

    const result = try execListDirectory(ctx, tc);
    defer if (result.output_allocated) a.free(result.output);

    try testing.expect(std.mem.indexOf(u8, result.output, "absolute paths are not allowed") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "alpha.txt") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "beta") != null);
}
