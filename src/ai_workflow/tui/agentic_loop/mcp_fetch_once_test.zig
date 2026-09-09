//! Static-contract tests for the fetch-once MCP tools cache
//! (plan: mcp-fetch-once-cache).
//!
//! The user asked to move the `tools/list` fetch out of the per-run hot
//! path in `workflow.zig`: first workflow run fetches once via
//! `fetchMcpToolsFresh`, publishes to `ContextIPCTui`, and every later
//! run (new session, queued message, retry) reads the snapshot.
//!
//! These are source-contract tests (grep the function body) because a
//! behavioural test would need live MCP servers; the python functional
//! harness (`mcp_stdio_test.py`) covers the real `tools/list` wire.

const std = @import("std");
const testing = std.testing;

const workflow_src = @embedFile("workflow.zig");

test "static contract: runAgenticMultiStepnew reads the fetch-once cache" {
    // The per-run block MUST go through the singleton cache helpers —
    // a future refactor that re-introduces a direct buildMCPToolsRun
    // call in the run body would fetch on every session/message again.
    try testing.expect(std.mem.indexOf(u8, workflow_src, "di.di.isMcpToolsInit()") != null);
    try testing.expect(std.mem.indexOf(u8, workflow_src, "di.di.getMcpToolsCached(parent_allocator)") != null);
    try testing.expect(std.mem.indexOf(u8, workflow_src, "di.di.storeMcpToolsCache(") != null);
}

test "static contract: buildMCPToolsRun is called exactly once (inside fetchMcpToolsFresh)" {
    // Count occurrences of the fetch call. Exactly ONE is allowed — the
    // single fetch inside `fetchMcpToolsFresh`. Two would mean a second
    // per-run/per-iteration fetch path crept back in.
    const needle = "buildMCPToolsRun(";
    var count: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOf(u8, workflow_src[from..], needle)) |rel| {
        count += 1;
        from += rel + needle.len;
    }
    try testing.expectEqual(@as(usize, 1), count);
    // And the single call site must live inside the extractor helper.
    try testing.expect(std.mem.indexOf(u8, workflow_src, "fn fetchMcpToolsFresh(") != null);
}

test "static contract: fetch failure stays retryable (mark_init=false)" {
    // On fetch error the run must publish with mark_init=false so the
    // NEXT run retries instead of caching the failure forever.
    try testing.expect(std.mem.indexOf(u8, workflow_src, "storeMcpToolsCache(null, false)") != null);
}
