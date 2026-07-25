const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const llm_history = nalarcore.llm_history;
const set_git_worktree_mod = nalarcore.set_git_worktree;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execSetGitWorktree(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        set_git_worktree_mod.SetGitWorktreeInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "set_git_worktree failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // executeSetGitWorktreeToString returns ![]const u8 — errors are
    // also encoded as <error>...</error> in the XML on success paths.
    // We must catch the error union separately.
    const inner = set_git_worktree_mod.executeSetGitWorktreeToString(
        ctx.allocator,
        ctx.io,
        ctx.db,
        ctx.cwd,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "set_git_worktree failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // SUCCESS: persist the new git_worktree_cwd to the DB so the
    // session remembers it across tool calls. For CLEAR, pass null
    // (the function treats null and "" identically as "clear the
    // binding"). For SET, extract the <path>...</path> from the
    // inner XML and persist it.
    const effective: ?[]const u8 = if (parsed.value.clear) null else blk: {
        const path_start = (std.mem.indexOf(u8, inner, "<path>") orelse 0) + "<path>".len;
        const path_end = std.mem.indexOf(u8, inner[path_start..], "</path>") orelse inner.len;
        const worktree_path = inner[path_start .. path_start + path_end];
        if (worktree_path.len == 0) break :blk null;
        // Borrow the slice from `inner` (still alive for the duration
        // of this call). `updateSessionGitWorktreeCwd` only reads it
        // and never frees it, so this is safe.
        break :blk worktree_path;
    };

    llm_history.updateSessionGitWorktreeCwd(ctx.allocator, ctx.db, ctx.session_id, effective) catch |err| {
        ctx.logger.errFmt("set_git_worktree: failed to persist git_worktree_cwd: {s}", .{@errorName(err)});
    };

    const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}