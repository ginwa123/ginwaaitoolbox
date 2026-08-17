const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const glob_tool_mod = nalarcore.glob_tool;
const wrapToolOutput = tools.wrapToolOutput;
const testing = std.testing;

pub fn execGlob(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = std.json.parseFromSlice(
        glob_tool_mod.GlobInput,
        ctx.allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "glob failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // Security: reject absolute paths.
    if (try nalarcore.path_security.rejectAbsolutePath(
        ctx.allocator, "glob", "path", parsed.value.path, ctx.cwd
    )) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // Resolve the relative path against ctx.cwd_override ?? ctx.cwd.
    // The underlying executeGlob uses std.Io.Dir.cwd() (the OS process
    // cwd), NOT ctx.cwd — so without this resolution the LLM-supplied
    // relative path would be walked from the wrong directory.
    const resolved_path = try nalarcore.path_security.resolveCwd(
        ctx.allocator, ctx.cwd, ctx.cwd_override, parsed.value.path
    );
    defer ctx.allocator.free(resolved_path);

    var input = parsed.value;
    input.path = resolved_path;
    var glob_result = glob_tool_mod.executeGlob(ctx.allocator, ctx.io, input) catch |err| {
        // Map the new domain errors to LLM-friendly messages. Each one
        // names the fix the LLM can try (different pattern, narrower
        // path, smaller max_results, etc).
        const err_msg: []const u8 = blk: {
            switch (err) {
                error.EmptyPattern => break :blk "glob pattern was empty — pass a non-empty pattern (this is a caller bug, not 'no match')",
                error.WhitespaceOnlyPattern => break :blk "glob pattern contained only whitespace characters — pass a real pattern (this is a caller bug, not 'no match')",
                error.PatternContainsNulByte => break :blk "glob pattern contained a NUL (0x00) byte — patterns must be valid UTF-8 with no embedded NULs",
                error.PathDoesNotExist => break :blk "glob path does not exist or is not a directory — verify the path exists and points to a directory (not a file)",
                error.InvalidFileType => break :blk "glob file_type must be 'f', 'file', 'd', or 'directory' (or omitted for all types)",
                error.InvalidMaxResults => break :blk "glob max_results must be > 0 (omit the field or use a positive integer; the default is 100)",
                error.InvalidBraceExpansion => break :blk "glob pattern has unmatched braces ('{' without '}') — fix the brace expansion syntax",
                else => {},
            }
            // Fall-through for unrecognised errors: build the allocPrint
            // result and break with that.
            const msg = std.fmt.allocPrint(ctx.allocator, "glob failed: {s}", .{@errorName(err)}) catch "glob failed with an unknown error";
            break :blk msg;
        };
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = try glob_tool_mod.toXmlSuccess(ctx.allocator, glob_result, parsed.value.pattern);
    glob_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
// 2026-08-14 — end-to-end proof that RELATIVE paths work on every
// tool wired with the absolute-path ban (PR #259 follow-up).
test "execGlob: relative path '.' resolves and matches files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "alpha.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "beta.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "gamma.md", .data = "" });

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
            .name = "glob",
            .arguments = "{\"path\":\".\",\"pattern\":\"*.zig\",\"respect_ignore_files\":false}",
        },
    };

    const result = try execGlob(ctx, tc);
    defer if (result.output_allocated) a.free(result.output);

    try testing.expect(std.mem.indexOf(u8, result.output, "absolute paths are not allowed") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "alpha.zig") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "beta.zig") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "gamma.md") == null);
}
