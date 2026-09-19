const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const llm_history = nalarcore.llm_history;
const set_pull_request_mod = nalarcore.set_pull_request;
const wrapToolOutput = tools.wrapToolOutput;

fn payloadString(inner_parsed: ?std.json.Parsed(std.json.Value), field: []const u8) ?[]const u8 {
    const p = inner_parsed orelse return null;
    if (p.value != .object) return null;
    const v = p.value.object.get(field) orelse return null;
    if (v != .string) return null;
    if (v.string.len == 0) return null;
    return v.string;
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

    const inner = set_pull_request_mod.executeSetPullRequestToJSON(
        ctx.allocator,
        ctx.io,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "set_pull_request failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "set_pull_request", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    var inner_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch null;
    defer if (inner_parsed) |*p| p.deinit();

    if (payloadString(inner_parsed, "error")) |err_msg| {
        const output = try wrapToolOutput(ctx.allocator, "set_pull_request", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // SUCCESS: persist the attached PR binding so the session (and its
    // right panel) remembers it across tool calls. For CLEAR, pass
    // nulls (updateSessionPrUrl treats null and "" identically as
    // "clear the binding"). For SET, read `url` + `provider` from the
    // inner JSON (slices borrow from `inner`, still alive here;
    // updateSessionPrUrl only reads them).
    if (parsed.value.clear) {
        llm_history.updateSessionPrUrl(ctx.allocator, ctx.db, ctx.session_id, null, null) catch |err| {
            ctx.logger.errFmt("set_pull_request: failed to clear pr_url: {s}", .{@errorName(err)});
        };
    } else {
        const url = payloadString(inner_parsed, "url");
        const provider = payloadString(inner_parsed, "provider");
        llm_history.updateSessionPrUrl(ctx.allocator, ctx.db, ctx.session_id, url, provider) catch |err| {
            ctx.logger.errFmt("set_pull_request: failed to persist pr_url: {s}", .{@errorName(err)});
        };
    }

    const output = try wrapToolOutput(ctx.allocator, "set_pull_request", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
