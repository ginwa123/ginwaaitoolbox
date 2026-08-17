const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const text_replace_mod = nalarcore.text_replace_tool;
const wrapToolOutput = tools.wrapToolOutput;
const testing = std.testing;

pub fn execTextReplace(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        text_replace_mod.TextReplaceInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "text_replace failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // Security: reject absolute paths.
    if (try nalarcore.path_security.rejectAbsolutePath(
        ctx.allocator, "text_replace", "path", parsed.value.path, ctx.cwd
    )) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // Resolve the relative path against ctx.cwd_override ?? ctx.cwd.
    // The underlying executeTextReplace uses std.Io.Dir.cwd() (the OS
    // process cwd), NOT ctx.cwd — so without this resolution the
    // LLM-supplied relative path would patch the wrong file.
    const resolved_path = try nalarcore.path_security.resolveCwd(
        ctx.allocator, ctx.cwd, ctx.cwd_override, parsed.value.path
    );
    defer ctx.allocator.free(resolved_path);

    const result = text_replace_mod.executeTextReplace(
        ctx.allocator,
        ctx.io,
        resolved_path,
        parsed.value.old_str,
        parsed.value.new_str,
    ) catch |err| {
        const inner = text_replace_mod.toXmlError(
            ctx.allocator,
            err,
            resolved_path,
            parsed.value.old_str,
        );
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "text_replace failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = text_replace_mod.toXmlSuccess(ctx.allocator, result, resolved_path);
    const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// 2026-08-14 — end-to-end proof that RELATIVE paths work on every
// tool wired with the absolute-path ban (PR #259 follow-up).
test "execTextReplace: relative path resolves and patches file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "patch.txt", .data = "old text here" });

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
        .function = .{
            .name = "text_replace",
            .arguments = "{\"path\":\"patch.txt\",\"old_str\":\"old text\",\"new_str\":\"NEW text\"}",
        },
    };

    const result = try execTextReplace(ctx, tc);
    defer if (result.output_allocated) a.free(result.output);

    try testing.expect(std.mem.indexOf(u8, result.output, "absolute paths are not allowed") == null);

    const abs_path = try std.fs.path.join(a, &.{ root_abs, "patch.txt" });
    const content = try std.Io.Dir.cwd().readFileAlloc(testing.io, abs_path, a, std.Io.Limit.limited(1024));
    try testing.expectEqualStrings("NEW text here", content);
}