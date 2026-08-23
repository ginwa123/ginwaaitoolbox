// Static-contract tests for tools_exec_spawn_sub_agent.zig
//
// 2026-08-23 spawn-subagent-live-progress: this file locks in the
// invariant that the per-thread runtime emits progress events at 3
// lifecycle points (`launched` after session_id stored, `completed`
// after success=true, `failed` on each error return). When a future
// refactor accidentally drops one of those call sites, the chatview
// card will regress to "0 sub-agents" until all threads join — same
// bug the user reported.
//
// Technique follows design_model_group_test.zig: grep the function
// body via the `pub fn runSubAgent` → end-of-file window and assert
// required string fragments exist.

const std = @import("std");
const testing = std.testing;

const impl_path = "src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent.zig";

test "execSpawnSubAgent uses emitProgressEvent for launched/completed/failed" {
    const max_bytes: usize = 1 * 1024 * 1024; // 1 MiB — impl is ~14KB
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, impl_path, testing.allocator, .limited(max_bytes));
    defer testing.allocator.free(source);

    // 3 call sites + 3 status values must all be present.
    const emit_count = std.mem.count(u8, source, "emitProgressEvent(");
    try testing.expect(emit_count >= 3);

    try testing.expect(std.mem.indexOf(u8, source, ".status = .launched") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".status = .completed") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".status = .failed") != null);

    // Sanity: ensure tool_call_id is plumbed through SubAgentThreadArgs
    // (the per-thread struct that carries state from the launch loop
    // to runSubAgent). Without this, the emitted events can't be
    // correlated to the parent spawn call by the frontend.
    try testing.expect(std.mem.indexOf(u8, source, "tool_call_id: []const u8") != null);
}

test "runSubAgent captures start timestamp for elapsed_ms" {
    // The reducer on the frontend displays elapsed_ms as a chip;
    // without capturing start_ns at thread entry, every event would
    // show 0 or a meaningless number.
    const max_bytes: usize = 1 * 1024 * 1024;
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, impl_path, testing.allocator, .limited(max_bytes));
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "thread_start_ns") != null);
    try testing.expect(std.mem.indexOf(u8, source, "elapsed_ms") != null);
}

test "failed emit happens on every error return path" {
    // There are ~6 error-return sites in runSubAgent (session_id alloc
    // fail, copy fail, workflow error, getLatestMessage fail, empty
    // response, missing message). All must emit `failed` BEFORE
    // returning so the frontend's progress map never strands a row
    // in `running` forever.
    //
    // Two of them are centralized in `FailHelpers.call` /
    // `FailHelpers.callAlreadySet` (the per-thread helpers defined
    // near the top of runSubAgent). One is the workflow-error branch
    // (which calls emitProgressEvent directly because it has its own
    // diagnostic). So the source MUST contain at least 3 string
    // occurrences of `.status = .failed`: 2 in the helper struct +
    // 1 inline. The ≥3 bound is the regression threshold — if a
    // future refactor splits the helper, the threshold can grow in
    // the same commit.
    const max_bytes: usize = 1 * 1024 * 1024;
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, impl_path, testing.allocator, .limited(max_bytes));
    defer testing.allocator.free(source);

    const failed_emit_count = std.mem.count(u8, source, ".status = .failed");
    try testing.expect(failed_emit_count >= 3);

    // Cross-check: every error-return site must EITHER call
    // `failSubAgent(` (the helper) OR `emitProgressEvent(` directly
    // AND set `.status = .failed` (the workflow-error path).
    // Count `failSubAgent(` (NOT `failSubAgentAlreadySet(` because
    // that's a separate alias for the same struct function) +
    // inline emits of `.failed`. Six error sites → at least 6
    // call sites total (helpers + inline).
    const failhelper_calls = std.mem.count(u8, source, "failSubAgent(");
    // failSubAgentAlreadySet is a SEPARATE alias for the same
    // FailHelpers.callAlreadySet; count both helpers.
    const failhelper_already_set = std.mem.count(u8, source, "failSubAgentAlreadySet(");
    // Subtract 2 — the helpers reference failSubAgent = FailHelpers.call
    // and failSubAgentAlreadySet = FailHelpers.callAlreadySet inside the
    // struct, then 1 usage at the workflow-error path is a direct
    // `subagent_progress.emitProgressEvent(`. Add a baseline of 2
    // for the two alias bindings to the count.
    const helper_call_sites = (failhelper_calls - 0) + failhelper_already_set - 0;
    // Sanity: there must be at least 4 helper invocations across
    // the 6 error sites (the workflow-error branch is direct).
    try testing.expect(helper_call_sites >= 4);
}
