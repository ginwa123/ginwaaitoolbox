const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const list_directory_mod = nalarcore.list_directory;
const wrapToolOutput = tools.wrapToolOutput;

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
