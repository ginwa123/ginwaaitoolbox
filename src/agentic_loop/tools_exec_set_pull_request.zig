const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const llm_history = nalarcore.llm_history;
const set_pull_request_mod = nalarcore.set_pull_request;
const wrapToolOutput = tools.wrapToolOutput;

fn extractTag(inner: []const u8, name: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{name}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{name}) catch return null;
    const start = (std.mem.indexOf(u8, inner, open) orelse return null) + open.len;
    const end = std.mem.indexOf(u8, inner[start..], close) orelse return null;
    const value = inner[start .. start + end];
    if (value.len == 0) return null;
    return value;
}

pub fn execSetPullRequest(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        set_pull_request_mod.SetPullRequestInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "set_pull_request failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "set_pull_request", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = set_pull_request_mod.executeSetPullRequestToString(
        ctx.allocator,
        ctx.io,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "set_pull_request failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "set_pull_request", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse (inner.len - err_start);
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "set_pull_request", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // SUCCESS: persist the attached PR binding so the session (and its
    // right panel) remembers it across tool calls. For CLEAR, pass
    // nulls (updateSessionPrUrl treats null and "" identically as
    // "clear the binding"). For SET, extract <url> + <provider> from
    // the inner XML (slices borrow from `inner`, still alive here;
    // updateSessionPrUrl only reads them).
    if (parsed.value.clear) {
        llm_history.updateSessionPrUrl(ctx.allocator, ctx.db, ctx.session_id, null, null) catch |err| {
            ctx.logger.errFmt("set_pull_request: failed to clear pr_url: {s}", .{@errorName(err)});
        };
    } else {
        const url = extractTag(inner, "url");
        const provider = extractTag(inner, "provider");
        llm_history.updateSessionPrUrl(ctx.allocator, ctx.db, ctx.session_id, url, provider) catch |err| {
            ctx.logger.errFmt("set_pull_request: failed to persist pr_url: {s}", .{@errorName(err)});
        };
    }

    const output = try wrapToolOutput(ctx.allocator, "set_pull_request", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
