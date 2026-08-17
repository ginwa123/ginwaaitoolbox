const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const write_file_mod = nalarcore.write_file;
const wrapToolOutput = tools.wrapToolOutput;
const testing = std.testing;

pub fn execWriteFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        write_file_mod.WriteFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "write_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // Security: reject absolute paths.
    if (try nalarcore.path_security.rejectAbsolutePath(
        ctx.allocator, "write_file", "path", parsed.value.path, ctx.cwd
    )) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // Resolve the relative path against ctx.cwd_override ?? ctx.cwd.
    // The underlying writeFile uses std.Io.Dir.cwd() (the OS process
    // cwd), NOT ctx.cwd — so without this resolution the LLM-supplied
    // relative path would write to the wrong directory.
    const resolved_path = try nalarcore.path_security.resolveCwd(
        ctx.allocator, ctx.cwd, ctx.cwd_override, parsed.value.path
    );
    defer ctx.allocator.free(resolved_path);

    // Compute the relative path used in the OUTPUT (so the LLM sees
    // "src/main.zig" instead of "/home/user/proj/src/main.zig").
    const base = ctx.cwd_override orelse ctx.cwd;
    const relative_output_path = try nalarcore.path_security.relativePath(
        ctx.allocator, base, resolved_path
    );
    defer ctx.allocator.free(relative_output_path);

    var input = parsed.value;
    input.path = resolved_path;
    const write_result = write_file_mod.writeFile(ctx.allocator, ctx.io, input) catch |err| {
        const inner = write_file_mod.toXmlError(ctx.allocator, err, relative_output_path);
        defer ctx.allocator.free(inner);
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "write_file failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    // write_result.path is the absolute path the file was actually
    // written to. We want the success envelope to show the RELATIVE
    // path the LLM asked for, so build a synthetic WriteFileResult
    // with the relative path for the toXmlSuccess call (avoid
    // mutating write_result.path since it's allocator-owned by
    // writeFile and that would leak its absolute-path allocation).
    var display_result = write_result;
    display_result.path = try ctx.allocator.dupe(u8, relative_output_path);
    const inner = write_file_mod.toXmlSuccess(ctx.allocator, display_result);
    display_result.deinit(ctx.allocator);
    write_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// 2026-08-14 — end-to-end proof that RELATIVE paths work on every
// tool wired with the absolute-path ban (PR #259 follow-up). Uses
// arena to absorb pre-existing leaks in the underlying writeFile
// function.
test "execWriteFile: relative path resolves and writes file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a, .io = std.testing.io, .db = undefined,
        .logger = undefined, .session_id = "test", .model = "test",
        .cwd = root_abs, .api_key = "test", .base_url = "test",
        .config = undefined, .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool, .environment = null,
        .active_loops = undefined,
    };
    const tc = agent.ToolCall{
        .id = "call_1", .type = "function",
        .function = .{ .name = "write_file", .arguments = "{\"path\":\"written.txt\",\"content\":\"relative-write-proof\"}" },
    };

    const result = try execWriteFile(ctx, tc);
    defer if (result.output_allocated) a.free(result.output);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "absolute paths are not allowed") == null);
    // Verify the file was written by reading it back.
    const abs_path = try std.fs.path.join(a, &.{ root_abs, "written.txt" });
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, abs_path, a, std.Io.Limit.limited(1024));
    try std.testing.expectEqualStrings("relative-write-proof", content);
}