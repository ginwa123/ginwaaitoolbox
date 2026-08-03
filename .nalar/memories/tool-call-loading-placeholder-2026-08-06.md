# Tool-call loading placeholder (2026-08-06)

## Symptom (user report, task `task_1785784899843`)

After the agent crashes mid-tool-execution (or `bash` /
`spawn_sub_agent` hangs, or the `nalar` process is killed), the
next LLM request fails with:

```
400 Bad Request
Invalid function ID tool call error
```

The conversation has an assistant message declaring
`tool_calls=[A, B, C]` but only some of the `role=tool` rows
landed in the DB. OpenAI's API requires ALL `tool_call_id`s in the
assistant message to have matching tool rows — even one missing
fails the request, and every subsequent request fails the same
way.

## Why the current code fails

`src/ai_workflow/tui/agentic_loop/handle_tool.zig::handle_tool()`:

```zig
// Phase 1: SINGLE INSERT — declares tool_calls=[A, B, C]
_ = try llm_history.saveMessage(... { role=assistant, tool_calls=tc, ... });

// Phase 2: for-loop — each iteration runs long-running tools then INSERTs the row
for (tc) |tool_call| {
    const exec_result = try dispatchTool(ctx, tool_call);  // LONG-RUNNING
    try saveAndSendToolResult(... tool_call.id ...);      // crashes here → orphan id
}
```

If the crash is mid-Phase-2, the assistant row exists but some
tool rows don't. Next LLM call → API reject → stuck forever.

## The fix (3-phase pattern)

```
Phase 1 (sync)  ── INSERT placeholder rows for ALL tool_calls
Phase 2 (sync)  ── INSERT the assistant message with tool_calls
Phase 3 (async) ── for each tool_call: run + UPDATE the row in place
```

If we crash between Phase 1 and Phase 3, the placeholders stay in
the DB. A startup hook
(`resolveStaleLoadingToolResults(session_id)`) replaces them with
a synthetic "Tool execution interrupted" message before the next
LLM call, satisfying the API contract by ID.

## Files (planned)

| File | Change |
|---|---|
| `src/migrations/migration.zig` | New `Migration068AddToolCallLoading` (adds `is_loading` column) |
| `src/migrations/migration_068_test.zig` (new) | Behavioural tests for the migration |
| `src/ai_workflow/tui/llm_history.zig` | `saveToolResultPlaceholder`, `updateToolResultById`, `resolveStaleLoadingToolResults` helpers + inline tests |
| `src/ai_workflow/tui/agentic_loop/handle_tool.zig` | Rewrite `handle_tool()` into 3-phase pattern |
| `src/ai_workflow/tui/agentic_loop/handle_tool_loading_placeholder_test.zig` (new) | Behavioural tests |
| `src/ai_workflow/tui/agentic_loop/workflow.zig` | Call `resolveStaleLoadingToolResults` at top of worker loop |

## Why the placeholder MUST have `is_feed_to_llm=1`

If we mark it `is_feed_to_llm=0`, the conversation payload sent to
the LLM omits the placeholder row → assistant message's
`tool_calls=[A, B, C]` has no matching tool result for B/C → API
rejects.

The placeholder is sent to the LLM with empty content. The LLM
sees "tool call A completed with empty content" — acceptable as a
"still running" sentinel. The startup hook upgrades stranded
placeholders to a real "interrupted" message before the next call.

## Pitfalls

- **The UNIQUE INDEX on `tool_call_id`** (partial, WHERE
  `tool_call_id IS NOT NULL AND tool_call_id != ''`) prevents
  duplicate placeholders. Migration 068 must include it.
- **The UPDATE preserves `created_at` and `created_iso`** —
  those are the placeholder's "started at" time. Don't drift them
  on UPDATE; the LLM benefits from the gap between assistant and
  tool completion (visible in tooltips).
- **The startup hook is idempotent** — calling it on a session
  with 0 stranded rows is a no-op. Calling it on a session with
  stranded rows is also safe to call twice (the second call finds
  0 stranded rows because the first already cleared them).
- **MCP tools** (in `handle_mcp_tool.zig`) also go through
  `saveAndSendToolResult` — they get the same 3-phase benefit
  automatically because `handle_tool()` is the single dispatch
  point.
- **`spawn_sub_agent`** specifically benefits: a child-agent run
  that takes 30+ minutes and gets killed at minute 20 leaves a
  placeholder that resolves to "interrupted" on next start
  (instead of permanently orphaning the tool_call_id).

## Verification

```bash
# Backend
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
timeout 360 bash -c 'rm -rf zig-out/bin && zig build'

# Cross-compile smoke (MANDATORY for SQL helpers — lazy analysis
# can hide SQL prepare errors):
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
```

## Related

- Cross-project memory: `~/.config/nalar/memories/openai-tool-call-api-contract.md`
  (the API contract + general 3-phase pattern)
- Plan doc: `docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md`
- Spec: still pending (will be added when implementation lands)

## Out of scope (deferred)

- **Per-tool recovery strategy**: for v1, all stranded tool
  results get a generic "interrupted" message. A future
  improvement could attempt to re-run idempotent tools (most are
  NOT — defer).
- **Live "tool running" UI**: the chat view's existing Queue/Stop
  button is the visible indicator. No new UI needed.
- **Migration backfill**: the startup hook handles any existing
  stranded rows on next launch. No separate backfill migration.
- **Streaming placeholder content**: v1 commits empty content; a
  future enhancement could stream live updates via SSE.