const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const ReadFileInput = nalarcore.tool_models.ReadFileInput;
const ReadFileOptions = nalarcore.read_file.ReadFileOptions;
const readFile = nalarcore.read_file.readFile;
const toXMLSuccess = nalarcore.read_file.toXMLSuccess;
const wrapToolOutput = tools.wrapToolOutput;
const testing = std.testing;

pub fn execReadFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx.db;
    _ = ctx.session_id;

    // Parse arguments JSON to ReadFileInput
    const parsed = std.json.parseFromSlice(
        ReadFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // Security: reject absolute paths.
    if (try nalarcore.path_security.rejectAbsolutePath(
        ctx.allocator, "read_file", "path", parsed.value.path, ctx.cwd
    )) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // Resolve the relative path against ctx.cwd_override ?? ctx.cwd to
    // produce the absolute path the underlying readFile needs. The
    // underlying function uses std.Io.Dir.cwd() (the OS process cwd),
    // NOT ctx.cwd — so without this resolution the LLM-supplied
    // relative path would be read from the wrong directory.
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

    const read_opts = ReadFileOptions{
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
    };

    const read_result = readFile(ctx.allocator, ctx.io, resolved_path, read_opts) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_file failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer read_result.deinit(ctx.allocator);

    // Single allocation: combines path and content into XML result.
    // Path is the RELATIVE form so the LLM sees the path it sent,
    // not the resolved absolute filesystem path.
    const inner = try toXMLSuccess(ctx.allocator, read_result, relative_output_path);
    const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// 2026-08-14 — end-to-end proof that RELATIVE paths work on every
// tool wired with the absolute-path ban (PR #259 follow-up). Uses
// arena to absorb pre-existing leaks in the underlying readFile
// function (read_result.content is a heap slice not freed by
// exec wrapper). The test's job is to prove the validator +
// resolver are wired, not to catch those leaks.
test "execReadFile: relative path resolves against ctx.cwd and reads content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.txt", .data = "relative-path-proof" });

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
    const tc = agent.ToolCall{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "read_file", .arguments = "{\"path\":\"hello.txt\"}" },
    };

    const result = try execReadFile(ctx, tc);
    defer if (result.output_allocated) a.free(result.output);

    try testing.expect(std.mem.indexOf(u8, result.output, "absolute paths are not allowed") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "relative-path-proof") != null);
}
