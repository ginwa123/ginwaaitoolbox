# agentic_loop/

Per-session agentic-loop helpers used by `workflow.zig` and the HTTP handlers.
Each file owns one DB-or-pure-data helper plus, where appropriate, its own
**inline `test` blocks** at the bottom of the file.

## Testing convention — **inline, not separate `_test.zig`**

Tests for the helpers in this directory live **inside** the implementation
file as `test "..." { ... }` blocks at the bottom — NOT in sibling
`<file>_test.zig` files. This matches the canonical pattern already in the
directory: [`is_session_kanban.zig`](./is_session_kanban.zig) ships six
inline tests for `isSessionKanban` and no separate `_test.zig`.

The rest of the nalar codebase (e.g. `src/ai_workflow/tui/compaction_*.zig`,
`http_handlers/*_test.zig`) generally uses separate `_test.zig` files.
**`agentic_loop/` is the exception**, not the standard — keep tests inline
here for consistency with the existing files.

### Why inline here

1. **Each helper is small and self-contained.** Most files are 30-200 lines
   of pure logic against a 1-2 table SQLite fixture. Pulling the tests out
   into a separate file would scatter the fixture helpers and the assertions
   they cover across two files.
2. **Tests sit next to the code they exercise.** A future contributor who
   changes `is_worker_running.zig` sees the `test "..."` blocks at the
   bottom and runs them mentally as they read — no "find the test file"
   hop.

### ⚠️ Discovery is NOT automatic — you MUST register the file

**Zig's test runner only auto-discovers `test "..."` blocks in files that
are DIRECTLY `@import`ed by the test runner.** A transitive import chain
through `mod.zig` does **NOT** pull in test blocks.

`agentic_loop/mod.zig` imports every other file in the directory — but
that's not enough. `agentic_loop/test_runner.zig` must explicitly list
each file whose `test "..."` blocks should run. **Before commit**, run
`zig build test --summary all` and confirm:

```
$ rg 'agentic_loop' .zig-cache/o/*/test 2>/dev/null | sort -u | head
<file>.test.<test_name>...OK
```

If your test file appears but its `test "..."` lines do not, the file is
NOT imported by `agentic_loop/test_runner.zig` — add it.

#### Concrete failure mode

`is_session_kanban.zig` shipped 6 inline tests in commit `6a6bea58` but was
**never imported by `test_runner.zig`** — the tests compiled silently but
never ran. The first time they executed was when this README's author added
`_ = @import("is_session_kanban.zig");` to `test_runner.zig`. Don't repeat
the mistake.

### When to still create a separate `_test.zig`

The inline convention is a stylistic choice. Break out a separate test file
**only** if:

- The test file would dwarf the impl file (>2x the impl size), e.g. a
  fixture-helper library test that needs hundreds of lines of `setupDb`
  variations.
- A test is purely about asserting on the *file itself* (a
  static-contract / shape test on the impl source) rather than on the
  public API. Even then, prefer a single inline `test` with `readFile` +
  `indexOf` over a new file.

If you do create a new `_test.zig`, register it in
`agentic_loop/test_runner.zig` with `_ = @import("foo_test.zig");`.

## Files

As of 2026-08-14 (the [flatten-tui-into-agentic-loop](
../../../../docs/superpowers/plans/2026-08-14-flatten-tui-into-agentic-loop.md)
refactor), every `.zig` file that used to live at `src/ai_workflow/tui/`
top-level now lives here. The 3 exceptions are the entry-point files
that stay at `tui/` for backwards compat:
- `mod.zig` — re-exports the public API surface (`nalarcore.ai_mod.*`).
- `test_runner.zig` — top-level test discovery for tests that live at
  `tui/` (currently only `compaction_*_test.zig` was here pre-refactor
  but was deleted in Phase 7).
- `agentic_loop/test_runner.zig` — discovery for all `agentic_loop/` tests.

| File | Type | Notes |
|---|---|---|
| `mod.zig` | re-exports | Surfaces `nalarcore.ai_mod.*` for backwards compat. |
| `ActiveLoops.zig` | impl | Per-session agentic-loop registry. |
| `agent_memories.zig` | impl + inline tests | saveMemory / loadMemoriesByFts / getMemoryById. |
| `agentic_loop.zig` | — | (placeholder) |
| `background_process.zig` | impl | Background process tracking. |
| `compaction_*_test.zig` | tests | Inlined into `workflow.zig` + `workflow_compact_message.zig` (Phase 7). |
| `delete_queue_worker.zig` | impl + inline tests | DB queue cleanup. |
| `delete_worker.zig` | impl + inline tests | |
| `design_io.zig` | impl + inline tests | sanitizeFilename + atomicWriteFile. |
| `design_model.zig` | impl + inline tests | ~6k lines, design canvas DB layer. |
| `design_model_*_test.zig` (×7) | tests | Inlined as separate `_test.zig` files (Phase 6 deviation: design_model.zig is too large to inline). |
| `design_model_reorder_test.zig` | orphaned | Pre-existing schema/setup bugs (5 SIGABRT + 2 assertion failures). NOT registered in `test_runner.zig` — fix separately. |
| `extract_base64_image_urls_test.zig` | — | DELETED (was already disabled in test_runner.zig). |
| `get_queue_message.zig` | impl + inline tests | |
| `get_session_list_test.zig` | tests | Inlined as separate _test.zig (was at `tui/get_session_list_test.zig`). |
| `has_queue_messagge.zig` | impl + inline tests | |
| `inherited_context.zig` | impl + inline tests | |
| `insert_llm_histories.zig` | impl + inline tests | |
| `insert_queue_message.zig` | impl + inline tests | |
| `is_session_kanban.zig` | impl + inline tests | |
| `is_worker_cancelled.zig` | impl + inline tests | |
| `is_worker_running.zig` | impl + inline tests | |
| `llm_history.zig` | impl + inline tests | Big file (~6k lines). The "row" struct is in `llm_history_row.zig` (small, separate file to avoid name collision with this big file). |
| `llm_history_row.zig` | impl + inline tests | `LLMHistory` struct (used by 4 sibling files). Renamed from `llm_history.zig` in Phase 5 so the BIG file could land at `llm_history.zig` after the small one moved out. |
| `llm_history_*_test.zig` (×10) | tests | Kept as separate `_test.zig` files in Phase 5 (same reason as design_model — impl file is too large). |
| `markHistoryNotForLLMRun.zig` | impl | (placeholder) |
| `models.zig` | impl + inline tests | Shared type definitions (`TUIHistory`). |
| `on_event_design.zig` | impl + inline tests | |
| `on_event_sent.zig` | impl + inline tests | |
| `on_event_sent_design.zig` | impl + inline tests | |
| `on_event_sent_kanban.zig` | impl + inline tests | |
| `parsing.zig` | impl + inline tests | |
| `prompts_*.zig` (×6) | impl + inline tests | |
| `retry_delay_ms.zig` | impl + inline tests | |
| `save_agent.zig` | impl + inline tests | |
| `save_skill.zig` | — | Impl never landed (Phase 1 deleted the orphaned test file too). |
| `session_skills.zig` | impl + inline tests | |
| `session_update_test.zig` | tests | Kept as separate `_test.zig` (Phase 7 — inlining pushed llm_history.zig over 256KB static-contract test limit). |
| `sse_on_event_send_session.zig` | impl + inline tests | |
| `sse.zig` | impl + inline tests | |
| `test_runner.zig` | re-exports | Registers every test-bearing file for `zig build test` discovery. |
| `tools.zig` | impl + inline tests | Tool registry. |
| `tools_equipped.zig` | impl + inline tests | Tool default-state. |
| `tools_exec_*.zig` (×40+) | impl + inline tests | Per-tool exec logic. |
| `tools_wrap_output.zig` | impl + inline tests | |
| `update_session_name.zig` | impl + inline tests | |
| `update_task_name.zig` | — | (placeholder) |
| `update_worker.zig` | impl + inline tests | |
| `workflow.zig` | impl + inline tests | The agentic loop orchestrator. ~1.8k lines. |
| `workflow_commpact_message.zig` | impl + inline tests | ~1.7k lines. |
| `workflow_compact_message.zig` | impl + inline tests | ~1.5k lines. |
| `workflow_compact_call_agent_test.zig` | tests | |
| `workflow_compaction_envelope_test.zig` | tests | |
| `workspace_items_update_name_test.zig` | tests | Kept as separate `_test.zig` (Phase 7 — same 256KB reason). |

## Running the tests

From the project root:

```bash
zig build test --summary all
```

The `agentic_loop/` tests are part of the full suite and counted in the
`test success` line at the end. To verify just `agentic_loop` tests:

```bash
TEST_BIN=$(find .zig-cache/o -name test -type f -executable \
    | xargs file 2>/dev/null | grep "x86-64" | grep -v windows \
    | sort | tail -n 1 | cut -d: -f1)
timeout 60 "$TEST_BIN" 2>&1 | rg 'agentic_loop' | sort -u
```

## Adding a test to a new helper

1. Write the helper in its own file, e.g. `foo.zig`, and re-export it from
   `mod.zig` so the rest of the codebase picks it up via
   `nalarcore.ai_mod.ai_workflow.agentic_loop.foo`.
2. Append `test "..." { ... }` blocks to the **bottom** of `foo.zig`.
   Use `testing.allocator` for any heap allocations; the project's
   `zig-0.16-inmemory-sqlite-test-setup` pattern (`std.Io.Threaded.init +
   db.init(io, ":memory:")`) is the right fixture for tests that need a DB.
3. **Add `_ = @import("foo.zig");`** to the `test { ... }` block in
   `agentic_loop/test_runner.zig`. Without this, the test compiles but
   never runs.
4. Run `zig build test --summary all` and confirm the new test appears in
   the per-test output of the test binary:
   ```
   $ TEST_BIN=$(find .zig-cache/o -name test -type f -executable | tail -n 1 | cut -d: -f1)
   $ "$TEST_BIN" 2>&1 | rg 'agentic_loop\.foo\.test\.'
   ai_workflow.tui.agentic_loop.foo.test.<your test name>...OK
   ```
5. Commit. The next contributor who runs `zig build test` will see the
   test pass on their machine too.

## Known production bugs surfaced by tests

Adding tests occasionally surfaces pre-existing bugs in production code.
When that happens:

1. **Fix the test to side-step the bug** if the bug is in adjacent code you
   don't want to touch in this PR. Add a comment in the test citing the bug.
2. **Fix the production bug** if it's a one-line surgical fix.
3. **Defer the fix to a follow-up PR** with a TODO comment in the test.

The example from this directory: `LLMHistory.deinit` unconditionally calls
`allocator.free` on `.agent`/`.session_name`/`.tool_name`, which panic
with "Invalid free" when those fields hold their string-literal defaults.
`getLLMHistories.zig` always heap-dupes those fields so production is safe,
but a defensive fix (making the three fields `?[]const u8 = null` with
conditional frees, or splitting the struct into "raw row" + "optional
agent fields") would close the gap.

## When tests need a real `EventBus`

`update_worker`, `delete_worker`, `insert_queue_message`,
`delete_queue_worker`, `sse_send_event_worker`, and
`sse_on_event_send_llMHistory` all emit via the `event_bus` SSE channel.
Tests that want to verify the SSE branch actually fires must:

1. Create a `std.Io.Threaded` (gives a real `std.Io` for the bus + logger).
2. Create an `event_bus.EventBus.init("test_bus", alloc, io)`.
3. Subscribe a top-level `fn (SseEvent) void` callback that captures the
   emitted event into a module-level `var captured: ?SseEvent = null`.
4. Call the helper with `event_bus = &bus`.
5. Assert on `captured.?.event_type`, parse `captured.?.data` as JSON, etc.

Tests that only want the DB-write behavior can pass `event_bus = null` +
`is_emit_sse = true` to confirm the SSE branch is skipped safely.

`onEventSendLLMHistory` also dereferences `logger.?` (line 89 of
`sse_on_event_send_llm_history.zig`), so the test must construct a real
`Logger` via `Logger.init(alloc, io, .{})` rather than passing `null`.

## Refactor history

**2026-08-14** — [Flattened from `src/ai_workflow/tui/`](
../../../../docs/superpowers/plans/2026-08-14-flatten-tui-into-agentic-loop.md).
All 40+ impl files that previously sat at `tui/` top-level (next to the
two entry-point files `mod.zig` + `test_runner.zig`) now live here. The
`mod.zig` + `test_runner.zig` at `tui/` are kept as thin re-export /
test-discovery surfaces so the public `nalarcore.ai_mod.*` API surface
stays stable.

Phases 1-8 in the plan:
- **Phase 1**: 5 leaf files (`ActiveLoops`, `models`, `background_process`,
  `save_agent`, `startup`) + deleted `save_skill_test.zig` (orphaned).
- **Phase 2**: 4 event handlers (`on_event_sent`, `on_event_design`,
  `on_event_sent_design`, `on_event_sent_kanban`) + inlined 12 tests
  from `on_event_sent_sanitize_test.zig` + `on_event_sent_design_test.zig`.
- **Phase 3**: `inherited_context` + `agent_memories` + inlined ~40 tests.
- **Phase 4**: `kanban_model` + `design_io` + inlined 34 tests.
- **Phase 5**: `llm_history` + 8 `_test.zig` files — **deviation**:
  kept the 50 tests as separate `_test.zig` files (inlining would have
  blown llm_history.zig past the 256KB `.limited()` cap that the
  http_handlers static-contract tests use).
- **Phase 6**: `design_model` + 8 `_test.zig` files — **deviation**:
  same reason as Phase 5. Plus `design_model_reorder_test.zig` is
  intentionally NOT registered (pre-existing schema/setup bugs).
- **Phase 7**: Moved 3 orphan tests to their natural homes
  (`migrations/`, `modules/agent/tools/`), inlined 2 compaction
  tests into `workflow*.zig`, kept 2 session_update/workspace_items
  tests separate (256KB reason), deleted 2 disabled/orphaned files
  (`extract_base64_image_urls_test.zig`, `gitignore_vendor_sqlite3_test.zig`).
- **Phase 8** (this commit): Final cleanup of `tui/mod.zig` and this
  README.
