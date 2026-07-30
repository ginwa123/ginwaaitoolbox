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

| File | Inline tests |
|---|---|
| `mod.zig` | (none — pure re-exports) |
| `sse.zig` | ✅ 3 (`SseEvent` defaults, field round-trip) |
| `llm_history.zig` | ✅ 4 (defaults, full-field deinit, nullable-skip, empty `image_urls`) |
| `session_skills.zig` | ✅ 4 (`SkillInfo` defaults, deinit, loaded_at safety) |
| `is_session_kanban.zig` | ✅ 6 (kanban, non-kanban, unknown, empty, no-task, mixed) |
| `is_worker_running.zig` | ✅ 4 (empty, missing id, fresh insert, empty session_id) |
| `is_worker_cancelled.zig` | ✅ 4 (empty, fresh worker, flipped flag, defensive parse) |
| `has_queue_messagge.zig` | ✅ 5 (empty, single, different session, image_url, LIMIT 1) |
| `get_queue_message.zig` | ✅ 7 (empty, no-match, single, multi, heap-survival, empty image, session filter) |
| `update_worker.zig` | ✅ 7 (insert, ON CONFLICT overwrite, session updated_at, task updated_at, SSE skip) |
| `delete_worker.zig` | ✅ 5 (remove, no-op, partial, SSE skip) |
| `insert_queue_message.zig` | ✅ 5 (insert, empty image, multi-row order, session filter, SSE skip) |
| `delete_queue_worker.zig` | ✅ 4 (remove, no-op, both-filter, SSE skip) |
| `insert_llm_histories.zig` | ✅ 13 (insert × 3, fields × 5, nullable columns × 2, image_url × 2, SSE skip × 2) |
| `get_llm_histories.zig` | ✅ 12 (empty, ordering, LEFT JOIN × 2, numeric parse, bool parse, feed filter, NULL feed, image split × 3, nullable fields × 2) |
| `sse_send_event_worker.zig` | ✅ 7 (event_type mapping × 4, JSON shape, routing key, heap copy) |
| `sse_on_event_send_llm_history.zig` | ✅ 6 (event type, JSON fields, content sanitize × 2, null content, central broadcast) |
| `sse_on_event_send_queue_message.zig` | (placeholder — empty file, no tests needed) |
| `compaction_context.zig` | ✅ 10 (parseReadFilePath × 4, fetchUserChatHistory, fetchReadFilePaths, enrichCompactionXml × 4) |
| `test_runner.zig` | (none — just imports the test-bearing files for discovery) |

**Total: 107 inline test "..." blocks + 1 `test_runner.test_0` = 108 tests
discovered in this directory.** Run
`zig build test --summary all` from the project root to execute them.

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
