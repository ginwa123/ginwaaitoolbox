// Static-contract tests for the dynamic retry/bail error messages
// (plan: docs/superpowers/plans/2026-08-24-dynamic-retry-error-messages.md).
//
// These tests grep `workflow.zig`'s source for the contract that makes
// retry/bail diagnostics carry the ACTUAL server reason (HTTP status +
// body, scanner error, raw SSE sample) instead of only `@errorName`:
//
//   1. `saveRetryAttemptMessage` takes a `server_detail` param and
//      interpolates it into its format literal.
//   2. Both TooManyRetries bail diagnostics (soft + hard) interpolate
//      `last_retry_server_detail`.
//   3. `last_retry_server_detail` is captured on every retry and reset
//      at every site that resets `last_retry_error`.
//   4. All three diagnostic insertLLMHistories calls pass
//      `.is_skip_db = true` — diagnostics must NEVER persist to sqlite
//      (user constraint, 2026-08-24).
//
// Pattern follows tools_exec_spawn_sub_agent.zig's inline static-contract
// tests (grep impl source between function markers).

const std = @import("std");

const workflow_src = @embedFile("workflow.zig");

fn extractFnBody(src: []const u8, fn_marker: []const u8, next_marker: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, src, fn_marker) orelse return "";
    const end = std.mem.indexOfPos(u8, src, start + fn_marker.len, next_marker) orelse return "";
    return src[start..end];
}

test "saveRetryAttemptMessage takes server_detail param and interpolates it" {
    const body = extractFnBody(
        workflow_src,
        "fn saveRetryAttemptMessage(",
        "\nfn ",
    );
    try std.testing.expect(body.len > 0);
    // New parameter in the signature.
    try std.testing.expect(std.mem.indexOf(u8, body, "server_detail: []const u8") != null);
    // Format literal interpolates it (the literal line + arg tuple).
    try std.testing.expect(std.mem.indexOf(u8, body, "Server said:") != null);
}

test "retry-catch passes server_detail into saveRetryAttemptMessage" {
    const body = extractFnBody(
        workflow_src,
        "last_retry_source = \"callDynamicAgentNew\";",
        "fn saveRetryAttemptMessage(",
    );
    try std.testing.expect(body.len > 0);
    const call = std.mem.indexOf(u8, body, "try saveRetryAttemptMessage(") orelse
        return error.TestUnexpectedResult;
    _ = call;
    // The catch-site call must reference the detail variable.
    const call_start = std.mem.indexOf(u8, body, "try saveRetryAttemptMessage(").?;
    const call_end = std.mem.indexOfPos(u8, body, call_start, ");") orelse return error.TestUnexpectedResult;
    const call_args = body[call_start..call_end];
    try std.testing.expect(std.mem.indexOf(u8, call_args, "server_detail") != null);
}

test "both bail diagnostics interpolate last_retry_server_detail" {
    // Soft-bail diagnostic.
    const soft_body = extractFnBody(
        workflow_src,
        "UNATTENDED SOFT-BAIL",
        "Existing hard-bail",
    );
    try std.testing.expect(soft_body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, soft_body, "Server said: {s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, soft_body, "last_retry_server_detail") != null);

    // Hard-bail diagnostic.
    const hard_body = extractFnBody(
        workflow_src,
        "workflow halted after {} consecutive retries",
        "logger.errFmt(\"TooManyRetries exhausted",
    );
    try std.testing.expect(hard_body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hard_body, "Server said: {s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, hard_body, "last_retry_server_detail") != null);
}

test "last_retry_server_detail declared, captured, and reset alongside last_retry_error" {
    // Declared once.
    var decl_count: usize = 0;
    var it = std.mem.splitSequence(u8, workflow_src, "var last_retry_server_detail");
    while (it.next()) |_| decl_count += 1;
    try std.testing.expectEqual(@as(usize, 2), decl_count); // splitSequence yields n+1 parts

    // Captured at both retry sites + reset at all 3 reset points +
    // read at both bail sites → expect >= 6 total references.
    var ref_count: usize = 0;
    var it2 = std.mem.splitSequence(u8, workflow_src, "last_retry_server_detail");
    while (it2.next()) |_| ref_count += 1;
    try std.testing.expect(ref_count - 1 >= 6);
}

test "all three diagnostic sites keep is_skip_db=true (never persist to sqlite)" {
    // Soft-bail block.
    const soft_body = extractFnBody(workflow_src, "unattended-mode soft-bail after", "Existing hard-bail");
    try std.testing.expect(std.mem.indexOf(u8, soft_body, ".is_skip_db = true") != null);

    // Hard-bail block: window runs from the diagnostic literal to the
    // `return error.TooManyRetries` — covers the insertLLMHistories call.
    const hard_body = extractFnBody(workflow_src, "workflow halted after {} consecutive retries", "return error.TooManyRetries");
    try std.testing.expect(std.mem.indexOf(u8, hard_body, ".is_skip_db = true") != null);

    // Per-retry message helper.
    const helper_body = extractFnBody(workflow_src, "fn saveRetryAttemptMessage(", "\nfn ");
    try std.testing.expect(std.mem.indexOf(u8, helper_body, ".is_skip_db = true") != null);
}
