// Test runner for the `agentic_loop/` directory.
//
// IMPORTANT: Zig's test runner only auto-discovers `test "..." { ... }` blocks
// in files that are **directly `@import`ed** here. A transitive import via
// `mod.zig` does NOT count — `mod.zig` is reachable but its descendants'
// `test` blocks are NOT automatically registered.
//
// Whenever you add a new `test "..." { ... }` block to an implementation file
// in this directory, ALSO add `_ = @import("your_file.zig");` to the list
// below. The README explains this in more detail.

test {
    // ─── Files with inline tests ──────────────────────────────────────────
    _ = @import("sse.zig");
    _ = @import("llm_history.zig");
    _ = @import("session_skills.zig");
    _ = @import("is_session_kanban.zig");
    _ = @import("is_worker_running.zig");
    _ = @import("is_worker_cancelled.zig");
    _ = @import("has_queue_messagge.zig");
    _ = @import("get_queue_message.zig");
    _ = @import("update_worker.zig");
    _ = @import("delete_worker.zig");
    _ = @import("insert_queue_message.zig");
    _ = @import("delete_queue_worker.zig");
    _ = @import("insert_llm_histories.zig");
    _ = @import("get_llm_histories.zig");
    _ = @import("sse_send_event_worker.zig");
    _ = @import("sse_on_event_send_llm_history.zig");
    _ = @import("parsing.zig");
    _ = @import("parsing_test.zig");
    _ = @import("workflow.zig");
    _ = @import("tools_wrap_output.zig");
    _ = @import("workflow_commpact_message.zig");
    _ = @import("compaction_context_test.zig");  // 2026-07-30-better-compaction-context — fetchUserChatHistory + fetchReadFilePaths + parseReadFilePath
    _ = @import("compaction_enrich_test.zig");  // 2026-07-30-better-compaction-context — enrichCompactionXml wire shape
}
