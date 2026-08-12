# 2026-08-12: Fix `session.updated` SSE event so sidebar task name updates live

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the LLM auto-renames a task on first user message (or the user renames a task via the sidebar), the sidebar task row reflects the new name WITHOUT requiring a page refresh.

**Architecture:** Two coupled bugs — (1) the backend's `onEventSendSessions` function emits `event_type = "session_unknown"` for `action = "updated"` because the if/else cascade only knows about `created`/`deleted` and falls through to a "future-proofing" default; (2) the frontend's `createUnifiedSseConnection` pre-registers `session_created` / `session_deleted` in `additionalEventTypes` but NOT `session_updated`, and its `onEvent` dispatch only routes those two names to the `sessions` channel callback. The fix is to add `session_updated` to the wire-format mapping in BOTH Zig event senders and to BOTH the registration list AND the dispatch check on the TypeScript side. The downstream consumers (the workspaces store's `installSessionEventHandlers` and ChatsList's `onSessionEvent`) already correctly handle `event.action === 'updated'` — the bug is purely in the wire-format name → named-event mapping.

**Tech Stack:** Zig 0.16 (backend SSE emitter), TypeScript + Vue 3 + vitest (frontend SSE consumer).

## Global Constraints

- **CRITICAL**: never kill port 8081 — use 8080 for local smoke. (N/A here, no server start required.)
- **CRITICAL**: every change must work on Linux + macOS + Windows. Both Zig and TypeScript code paths are platform-neutral here.
- **CRITICAL**: NO new static-contract tests (user rule 2026-07-29). EXCEPTION: the SSE wire-format tests in `http_handlers/sse_handshake_test.zig` are the existing pattern for this exact class of bug — follow that pattern, don't invent a new one.
- File paths: 2 backend `.zig` files (event senders) + 1 frontend `.ts` file (SSE factory) + 1 frontend test file (`unifiedSseBuffer.spec.ts`).
- Pre-commit:
  - `cd src/apps/desktop && bun run build && bunx vitest run` (frontend type-check + tests)
  - `zig build test:ai_workflow:tui` (backend static-source tests)

---

## File Structure

| File | Change |
|---|---|
| `src/ai_workflow/tui/agentic_loop/sse_on_event_send_session.zig` | Add `"updated" → "session_updated"` branch; update stale comment |
| `src/ai_workflow/tui/on_event_sent.zig` | Add `"updated" → "session_updated"` branch; update stale comment |
| `src/ai_workflow/tui/http_handlers/session_event_type_test.zig` | NEW — static-source contract test pinning `session_updated` emission in BOTH emitters |
| `src/ai_workflow/tui/test_runner.zig` | Register the new test file |
| `src/apps/desktop/src/api/index.ts` | Add `'session_updated'` to `additionalEventTypes`; add it to the named-event dispatch check |
| `src/apps/desktop/src/__tests__/unifiedSseBuffer.spec.ts` | Add `'session_updated'` to `REQUIRED_EVENT_TYPES`; add behavioural test that simulates a `session_updated` wire event and asserts the `sessions` callback fires |

---

## Background — what's happening today

The user opens the sidebar, clicks "+ Add Item → Standard Chat" (the new-chat flow), picks a name in the picker dialog (or accepts the auto-name "New Chat"), and sends a first message. The backend's LLM call generates a session name (see `agentic_loop/workflow.zig:1399`) and calls `updateSessionName` (defined in `agentic_loop/update_session_name.zig`). That function:

1. Writes `sessions.name = ?` (line 17-18).
2. Calls `onEventSendSessions(allocator, eb, .{ .action = "updated", ... })` (line 24-34).

That call goes to `sse_on_event_send_session.zig:19`. The function builds the payload, picks the SSE wire-format `event:` name via:

```zig
const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "created"))
    "session_created"
else if (std.mem.eql(u8, input.action, "deleted"))
    "session_deleted"
else
    "session_unknown"; // future-proofing for new actions
```

For `action = "updated"` this falls through to `"session_unknown"`.

The browser's EventSource then sees `event: session_unknown` on the wire. The frontend's `createSseClient` was told via `additionalEventTypes` to register listeners for `session_created` and `session_deleted` ONLY (see `api/index.ts:2925-2926`). The browser never dispatches `session_unknown` to the JS handler — it just sits in the buffer. (See SseClient JSDoc + project memory `browser-eventsource-named-events.md` for why this happens.)

The downstream `onEvent(raw, "session_unknown")` path goes into the default-message fallback at `api/index.ts:3077-3143`. The default-message buffer accumulates the bytes until a `{...}` pair parses, then shape-discriminates by `action` + `status` + `cwd`. **In theory** this should dispatch to `opts.channels.sessions(...)`. **In practice** it doesn't, because the named-event listener never fires for `session_unknown` (no listener registered for that name) → bytes never reach `onEvent` → the default-message path never sees the event. So the rename is silently dropped.

On page refresh, `loadChats()` (ChatsList) and the workspace tree's task fetch (workspaces store) re-read from the API and display the new name — which is why the user sees it only after refresh.

A second emitter (`on_event_sent.zig:362-414`) has the IDENTICAL bug pattern — it serves the LLM-history session events (`updateSessionAutoRetryUntilStop`, `updateSessionLastFinishReason`, etc.). It must be fixed in the same pass so all "updated" actions emit `session_updated`.

---

## Task 1: Frontend registers + dispatches `session_updated` (RED → GREEN)

The frontend needs two changes in `src/apps/desktop/src/api/index.ts`:

1. Add `'session_updated'` to the `additionalEventTypes` array (line 2915-2945).
2. Add `eventType === 'session_updated'` to the named-event dispatch check (line 3047-3059).

**Files:**
- EDIT: `src/apps/desktop/src/api/index.ts`
- EDIT: `src/apps/desktop/src/__tests__/unifiedSseBuffer.spec.ts`

### Step 1.1 — Write the failing test

In `src/apps/desktop/src/__tests__/unifiedSseBuffer.spec.ts`, find the `REQUIRED_EVENT_TYPES` array (line 592-617) inside the `describe('createUnifiedSseConnection: pre-registers all granular event names', ...)` block. Add `'session_updated'` to the list, AFTER `'session_deleted'`:

```ts
const REQUIRED_EVENT_TYPES = [
  'kanban_column',
  'kanban_task',
  'queue_queued',
  'queue_deleted',
  'llm_chunk',
  'llm_full',
  'worker_created',
  'worker_updated',
  'worker_deleted',
  'session_created',
  'session_deleted',
  'session_updated', // ← NEW — auto-rename-on-first-message cascade (task_1786507100896)
  'design_element_created',
  'design_element_updated',
  'design_element_deleted',
  'design_elements_geometry_batch_updated',
]
```

Also update the file's documentation comment (around line 588-589) to include `session_updated`:

```ts
 *   - worker_created, worker_updated, worker_deleted
 *   - session_created, session_deleted, session_updated
```

Run the test to confirm it fails (RED):

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop && bunx vitest run unifiedSseBuffer
```

Expected: the `'registers every required event type as an additionalEventType'` test FAILS with a message that says `'session_updated' is not in the registered list` (the assertion loops through `REQUIRED_EVENT_TYPES` and bails on the first missing name).

### Step 1.2 — Add `session_updated` to the `additionalEventTypes` array

In `src/apps/desktop/src/api/index.ts`, find the `additionalEventTypes` array literal (around line 2915-2945). Add `'session_updated'` to it, between `'session_deleted'` and the design-mode entries:

```ts
additionalEventTypes: [
  'kanban_column',
  'kanban_task',
  'queue_queued',
  'queue_deleted',
  'llm_chunk',
  'llm_full',
  'worker_created',
  'worker_updated',
  'worker_deleted',
  'session_created',
  'session_deleted',
  'session_updated', // ← NEW — required for live task-name rename (see task_1786507100896)
  'design_element_created',
  'design_element_updated',
  'design_element_deleted',
  'design_elements_geometry_batch_updated',
],
```

### Step 1.3 — Add `session_updated` to the named-event dispatch check

Still in `src/apps/desktop/src/api/index.ts`, find the named-event dispatch for session events (around line 3043-3059):

```ts
// Session events. The backend sets `session_created` |
// `session_deleted` based on `OnEventInputSessions.action`. Today
// only `created` is emitted; `deleted` is wired in `on_event_sent.zig`
// for future use.
if (
  eventType === 'session_created' ||
  eventType === 'session_deleted'
) {
  if (!opts.channels.sessions) return
  try {
    const data = JSON.parse(raw)
    opts.channels.sessions(data as SessionEvent)
  } catch (err) {
    console.error('[unifiedSSE] session event parse failed:', err, raw)
  }
  return
}
```

Replace it with:

```ts
// Session events. The backend emits `session_created` (on first
// message of a fresh chat), `session_updated` (on auto-rename after
// the first user message + on unattended-mode toggle + on
// last_finish_reason refresh; see llm_history.zig:2896 + the cascade
// in update_session_name.zig:24), and `session_deleted`. All three
// share the `SessionEvent` payload shape; the consumer dispatches by
// `event.action`. The pre-registration in `additionalEventTypes`
// above is what wires the browser's EventSource to fire onEvent
// for these names — without it, the wire event is dropped on the
// floor (see project memory browser-eventsource-named-events.md).
if (
  eventType === 'session_created' ||
  eventType === 'session_updated' ||
  eventType === 'session_deleted'
) {
  if (!opts.channels.sessions) return
  try {
    const data = JSON.parse(raw)
    opts.channels.sessions(data as SessionEvent)
  } catch (err) {
    console.error('[unifiedSSE] session event parse failed:', err, raw)
  }
  return
}
```

### Step 1.4 — Re-run the test to confirm GREEN

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop && bunx vitest run unifiedSseBuffer
```

Expected: the test now passes.

### Step 1.5 — Add a behavioural test that simulates the wire event

Still in `src/apps/desktop/src/__tests__/unifiedSseBuffer.spec.ts`, find the `describe('createUnifiedSseConnection: pre-registers all granular event names', ...)` block and ADD a new `it()` test at the end (after the existing `'registers every required event type as an additionalEventType'` test). This test simulates the FULL pipeline: fire a `session_updated` event through the wire format and verify the consumer's `sessions` callback fires.

```ts
/**
 * Regression test for task_1786507100896: when the backend emits a
 * session rename on first user message (LLM auto-name), the
 * downstream consumer's `sessions` callback MUST fire. Pre-fix, the
 * backend emitted `event_type = "session_unknown"` (the fallthrough
 * in sse_on_event_send_session.zig's if/else) and the frontend's
 * additionalEventTypes didn't include the new name, so the browser's
 * EventSource dropped the event and the sidebar task row kept
 * showing the old name until refresh.
 *
 * This test simulates the wire format: caller fires
 * `(rawJsonString, 'session_updated')` into the factory's
 * onEvent callback. We assert the sessions channel callback runs
 * exactly once with the parsed SessionEvent.
 */
it('routes session_updated wire events to the sessions channel callback', () => {
  const sessionsCb = vi.fn()
  let capturedOnEvent: ((raw: string, eventType: string) => void) | null = null
  const localSpy = vi.spyOn(sseClient, 'createSseClient')
  localSpy.mockImplementation(((opts: sseClient.SseClientOptions) => {
    capturedOnEvent = opts.onEvent
    return {
      close: vi.fn(),
      reconnect: vi.fn(),
      getState: () => 'open' as const,
      onStateChange: () => () => {},
    }
  }) as unknown as typeof sseClient.createSseClient)

  createUnifiedSseConnection({
    channels: { sessions: sessionsCb },
  })

  expect(capturedOnEvent).not.toBeNull()

  // Simulate the wire-format payload the backend emits on
  // updateSessionName cascade (see
  // agentic_loop/update_session_name.zig:24-34 + the
  // OnEventInputSessions struct in sse_on_event_send_session.zig:7-17).
  const payload = JSON.stringify({
    action: 'updated',
    id: 'session_abc',
    name: 'Auto-generated name',
    status: 'idle',
    cwd: '/tmp',
    created_at: '2026-08-12T10:00:00Z',
    updated_at: '2026-08-12T10:00:05Z',
    selected_profile_model: '',
    git_worktree_cwd: '',
  })
  capturedOnEvent!(payload, 'session_updated')

  expect(sessionsCb).toHaveBeenCalledTimes(1)
  expect(sessionsCb).toHaveBeenCalledWith(
    expect.objectContaining({
      action: 'updated',
      id: 'session_abc',
      name: 'Auto-generated name',
    }),
  )

  localSpy.mockRestore()
})
```

### Step 1.6 — Run the new behavioural test (RED before backend fix, GREEN after both)

```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop && bunx vitest run unifiedSseBuffer
```

This test should ALREADY pass after Step 1.4, because the frontend's wire-format → callback path is now wired. (The backend bug doesn't affect this test — we synthesise the event in-test.) If it doesn't pass, double-check that Step 1.3 correctly added `session_updated` to the dispatch check.

### Step 1.7 — Commit

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/apps/desktop/src/api/index.ts src/apps/desktop/src/__tests__/unifiedSseBuffer.spec.ts
git commit -m "fix(frontend): route SSE session_updated events to ChatsList

Pre-fix, the unified SSE factory's additionalEventTypes list only
registered session_created and session_deleted. The browser's
EventSource drops named events whose listener isn't pre-registered,
so the backend's auto-rename-on-first-message cascade (which emits
action='updated') was silently swallowed at the wire boundary.

Symptoms:
  - Sidebar task row keeps showing 'New Chat' after the LLM
    auto-names the session on first user message.
  - Only a manual page refresh would show the new name.

Fix:
  - Add 'session_updated' to additionalEventTypes (api/index.ts:2925).
  - Add 'session_updated' to the named-event dispatch check that
    routes to opts.channels.sessions (api/index.ts:3047).
  - Update the stale comment that said only 'created' is emitted.

Regression tests in unifiedSseBuffer.spec.ts:
  - REQUIRED_EVENT_TYPES now includes 'session_updated' so a
    future omission fails the registration-assertion test.
  - New behavioural test fires (payload, 'session_updated')
    through the factory and asserts sessionsCb fires with the
    parsed SessionEvent.

Refs task_1786507100896."
```

---

## Task 2: Backend emits `session_updated` instead of `session_unknown` (RED → GREEN)

Two `.zig` files emit session SSE events with the same buggy `event_type_name` if/else cascade. Both need the same surgical fix.

**Files:**
- EDIT: `src/ai_workflow/tui/agentic_loop/sse_on_event_send_session.zig`
- EDIT: `src/ai_workflow/tui/on_event_sent.zig`

### Step 2.1 — Write the failing static-source test

Create `src/ai_workflow/tui/http_handlers/session_event_type_test.zig`. Follow the existing static-source-test pattern from `sse_handshake_test.zig` and `task_update_test.zig` (reads the .zig file from disk and asserts a substring is present). The test enforces that BOTH emitters map `"updated"` → `"session_updated"` in the wire-format `event_type_name` if/else.

```zig
//! Static regression check for the SSE session event_type_name
//! mapping.
//!
//! Why this file exists
//! ────────────────────
//! The backend has TWO emitters that share the same
//! `OnEventInputSessions.action` → SSE `event:` name mapping:
//!   - src/ai_workflow/tui/agentic_loop/sse_on_event_send_session.zig
//!     (serves the workflow-driven rename cascade via
//!      update_session_name.zig)
//!   - src/ai_workflow/tui/on_event_sent.zig
//!     (serves the llm_history.zig-driven unattended flag + finish
//!      reason updates; also used by session_create.zig for the
//!      initial created event)
//!
//! Pre-fix, both files had the SAME bug pattern: the if/else
//! cascade that picks the wire-format `event_type_name` only
//! knew about `created` and `deleted`, falling through to
//! `"session_unknown"` for any other action (including the
//! common `"updated"` case). The frontend's
//! `createUnifiedSseConnection` only pre-registers
//! `session_created` and `session_deleted` in additionalEventTypes
//! (api/index.ts:2925-2926), so the browser's EventSource dropped
//! the `session_unknown` event on the floor before the JS handler
//! ever saw it.
//!
//! Result: the auto-rename-on-first-message cascade and the
//! unattended-mode toggle both silently failed to update the
//! sidebar task row. The user had to refresh to see the new
//! name. See task_1786507100896 for the user report.
//!
//! These tests pin the wire-format contract: both files MUST
//! contain the `"updated"` → `"session_updated"` mapping in the
//! event_type_name if/else. A regression that drops the branch
//! (or renames it to `session_unknown`) fails the test.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const SSE_ON_EVENT_SEND_SESSION_PATH =
    "src/ai_workflow/tui/agentic_loop/sse_on_event_send_session.zig";
const ON_EVENT_SENT_PATH = "src/ai_workflow/tui/on_event_sent.zig";

/// Read a source file from disk, normalising CRLF → LF.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

/// Extract the body of the `onEventSendSessions` function from a
/// source file. We find the `pub fn onEventSendSessions(` signature
/// and walk forward until the next `pub fn ` or end-of-file — the
/// slice between is the function body (newline-delimited, same
/// pattern as task_update_test.zig).
fn extractOnEventSendSessionsBody(source: []const u8) []const u8 {
    const sig = "pub fn onEventSendSessions(";
    const sig_idx = std.mem.indexOf(u8, source, sig) orelse {
        std.debug.print(
            "\n!! Could not find `pub fn onEventSendSessions(` !!\n",
            .{},
        );
        return source; // fall through — the substring check below will fail
    };
    const after_sig = sig_idx + sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    return source[after_sig..next_pub_fn];
}

// ─── Contract 1: agentic_loop emitter maps "updated" → "session_updated" ────

test "sse_on_event_send_session.zig maps action='updated' to event_type 'session_updated'" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, SSE_ON_EVENT_SEND_SESSION_PATH);
    defer allocator.free(source);

    const body = extractOnEventSendSessionsBody(source);

    // The mapping must be present. We check for the EXACT 3-token
    // substring `"updated"\n        "session_updated"` (with enough
    // leading whitespace to anchor the position in the if/else
    // ladder). A regression to "session_unknown" fails this test.
    const needle =
        "\"updated\"\n" ++
        "        \"session_updated\"";
    if (std.mem.indexOf(u8, body, needle) == null) {
        std.debug.print(
            "\n!! {s} does not map action='updated' to event_type='session_updated' !!\n" ++
                "   The pre-fix bug mapped it to 'session_unknown' (the if/else\n" ++
                "   fallthrough), which the frontend's additionalEventTypes doesn't\n" ++
                "   register, so the browser's EventSource drops the event. Result:\n" ++
                "   sidebar task rows never update from 'New Chat' to the LLM-generated\n" ++
                "   name until a manual page refresh.\n" ++
                "   Fix: add an `else if (std.mem.eql(u8, input.action, \"updated\"))`\n" ++
                "   branch to the event_type_name if/else that returns\n" ++
                "   \"session_updated\".\n" ++
                "   See task_1786507100896 and the parallel test below.\n",
            .{SSE_ON_EVENT_SEND_SESSION_PATH},
        );
        return error.SessionUpdatedMissing;
    }
}

// ─── Contract 2: on_event_sent emitter maps "updated" → "session_updated" ───

test "on_event_sent.zig maps action='updated' to event_type 'session_updated'" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, ON_EVENT_SENT_PATH);
    defer allocator.free(source);

    const body = extractOnEventSendSessionsBody(source);

    const needle =
        "\"updated\"\n" ++
        "        \"session_updated\"";
    if (std.mem.indexOf(u8, body, needle) == null) {
        std.debug.print(
            "\n!! {s} does not map action='updated' to event_type='session_updated' !!\n" ++
                "   Same bug class as the agentic_loop emitter above — see that test's\n" ++
                "   failure message for the full context.\n",
            .{ON_EVENT_SENT_PATH},
        );
        return error.SessionUpdatedMissing;
    }
}
```

### Step 2.2 — Run the test to confirm RED

```bash
cd /home/ginwa/ginwaaitoolbox && zig build test:ai_workflow:tui
```

Expected: both new tests FAIL with `SessionUpdatedMissing` and the diagnostic message points at the offending file.

### Step 2.3 — Fix `sse_on_event_send_session.zig`

Edit `src/ai_workflow/tui/agentic_loop/sse_on_event_send_session.zig`, lines 49-57 (the `event_type_name` if/else + stale comment). Replace:

```zig
    // Granular event name drives the SSE wire format `event:` line.
    // Today only `created` is emitted; the if/else covers future actions.
    // (Zig 0.16 can't `switch` on `[]const u8`.)
    const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "created"))
        "session_created"
    else if (std.mem.eql(u8, input.action, "deleted"))
        "session_deleted"
    else
        "session_unknown"; // future-proofing for new actions
```

With:

```zig
    // Granular event name drives the SSE wire format `event:` line.
    // Three actions are mapped:
    //   - "created" → "session_created" (initial session row insert)
    //   - "updated" → "session_updated" (auto-rename on first user message,
    //     unattended-mode toggle, last_finish_reason refresh)
    //   - "deleted" → "session_deleted"
    // The frontend's createUnifiedSseConnection pre-registers all three
    // names in additionalEventTypes (api/index.ts:2925-2926) so the
    // browser's EventSource dispatches each to the JS handler. A new
    // action NOT in this map still falls through to "session_unknown"
    // (the future-proofing default), which is currently NOT registered
    // by the frontend — by design, so unknown actions don't leak into
    // the session channel callback without an explicit contract.
    // (Zig 0.16 can't `switch` on `[]const u8`.)
    const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "created"))
        "session_created"
    else if (std.mem.eql(u8, input.action, "updated"))
        "session_updated"
    else if (std.mem.eql(u8, input.action, "deleted"))
        "session_deleted"
    else
        "session_unknown"; // future-proofing for new actions
```

### Step 2.4 — Fix `on_event_sent.zig` (same patch shape)

Edit `src/ai_workflow/tui/on_event_sent.zig`, lines 396-404. Apply the IDENTICAL fix (the `event_type_name` if/else + comment block is duplicated verbatim between the two files). Read lines 396-404 of the current file first to confirm, then patch with the same shape as Step 2.3.

The replacement adds the `"updated"` branch in the middle of the if/else and updates the stale comment.

### Step 2.5 — Register the new test file

Edit `src/ai_workflow/tui/test_runner.zig`. Find a sensible insertion point (alphabetical / topical grouping is loose; pick a spot near the other SSE tests like `http_handlers/sse_handshake_test.zig` at line 23 or `http_handlers/unified_events_sse_test.zig` at line 124). Add:

```zig
    _ = @import("http_handlers/session_event_type_test.zig"); // task_1786507100896 — pin session_updated wire-format mapping in BOTH emitters
```

### Step 2.6 — Re-run the test to confirm GREEN

```bash
cd /home/ginwa/ginwaaitoolbox && zig build test:ai_workflow:tui
```

Expected: both `session_event_type_test.zig` tests now PASS.

### Step 2.7 — Commit

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/ai_workflow/tui/agentic_loop/sse_on_event_send_session.zig \
        src/ai_workflow/tui/on_event_sent.zig \
        src/ai_workflow/tui/http_handlers/session_event_type_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "fix(backend): emit session_updated (not session_unknown) on session rename

Pre-fix, both SSE session emitters had the same if/else bug in
the wire-format event_type_name mapping: only 'created' and
'deleted' had explicit branches, and the fallthrough was the
generic 'session_unknown' (intended for FUTURE actions per the
inline comment).

In practice 'updated' is the most common action — the
auto-rename-on-first-message cascade (workflow.zig:1399 →
update_session_name.zig:24) and the unattended-mode toggle
(llm_history.zig:2896) both emit action='updated'. The
'updated' branch was missing, so every rename event reached
the wire as 'event: session_unknown', which the frontend's
createUnifiedSseConnection didn't pre-register in
additionalEventTypes. The browser's EventSource dropped the
event before the JS handler ever saw it.

Result: sidebar task rows never updated from 'New Chat' to
the LLM-generated name until a manual page refresh.

Fix:
  - Add `else if (action == \"updated\") → \"session_updated\"`
    to BOTH onEventSendSessions implementations:
      - sse_on_event_send_session.zig (workflow rename cascade)
      - on_event_sent.zig (llm_history session updates)
  - Update the stale 'Today only created is emitted' comments
    to document the three mapped actions.
  - Keep the 'session_unknown' fallthrough for genuinely new
    actions — it's the safe-by-default gate.

Paired with the frontend commit in task_1786507100896 that
adds 'session_updated' to additionalEventTypes + the
named-event dispatch check, the rename now reaches the
workspaces store's installSessionEventHandlers and ChatsList's
onSessionEvent immediately, no refresh required.

Regression test: new
src/ai_workflow/tui/http_handlers/session_event_type_test.zig
pins the wire-format contract in BOTH emitters via a static-
source substring assertion. Drops of the 'updated' branch (or
renames to 'session_unknown') fail the test with a diagnostic
that points at the offending file.

Refs task_1786507100896."
```

---

## Task 3: End-to-end smoke verification (manual)

After both commits land, verify the fix in a real desktop build:

1. Rebuild the Zig binary (the static-source tests pass, but the actual emitter change isn't applied to a running server until rebuild):
   ```bash
   cd /home/ginwa/ginwaaitoolbox && zig build
   ```
2. Start the server on a non-8081 port:
   ```bash
   ./zig-out/bin/nalar --port 8080 &
   ```
3. Run the desktop frontend against port 8080 (the build/dev config already supports the override; check `src/apps/desktop/.env` or the vite proxy config for how `VITE_API_PORT` is read).
4. Open the sidebar, click `+ Add Item → Standard Chat` on a workspace item.
5. Send a first message.
6. After the response starts streaming, watch the sidebar task row under the workspace item. It MUST update from "New Chat" to the LLM-generated name WITHOUT a page refresh.
7. (Bonus) Open the top "CHATS" section and confirm the same rename lands there too. The ChatsList re-fetches on session events via `workspacesStore.onSessionEvent(() => loadChats())` (ChatsList.vue:316-318).

If the row does NOT update: open devtools → network → `/api/events?channels=...` → look for an SSE frame with `event: session_updated`. If you see `event: session_unknown` instead, Task 2 didn't apply correctly (re-check the if/else ordering). If you see no frame at all, Task 1 didn't register the listener (re-check `additionalEventTypes`).

---

## Verification

- [ ] Frontend test `unifiedSseBuffer.spec.ts` runs GREEN, with both the updated `REQUIRED_EVENT_TYPES` test and the new behavioural `session_updated` routing test passing.
- [ ] Backend test `session_event_type_test.zig` runs GREEN, with both the agentic_loop emitter and the `on_event_sent` emitter contracts passing.
- [ ] Full frontend suite still passes: `cd src/apps/desktop && bunx vitest run` exits 0.
- [ ] Full backend test: `zig build test:ai_workflow:tui` exits 0.
- [ ] Manual smoke (Task 3): a new chat task shows the LLM-generated name in the sidebar within ~1 second of the first response, no refresh required.
- [ ] Both commits include the regression-test additions so the bug can't silently come back.

---

## Why this fix and not "just listen for session_unknown on the frontend"?

We considered the alternative of adding `'session_unknown'` to `additionalEventTypes` on the frontend side, which would be a 1-line change vs the 2-file backend fix. Rejected because:

1. `session_unknown` is the documented future-proofing default — the next time someone adds a new action (e.g. `"reordered"` for session-reorder broadcasts), the frontend would suddenly start receiving it in the `sessions` channel callback without anyone reviewing the contract. That's the exact failure mode the original code was trying to prevent (the inline comment on the else branch says so).
2. The wire-format name → routing key should be 1:1 with the action. The frontend already filters by `event.action` inside its listener (`workspaces.ts:3702`, `ChatsList.vue:316`). Adding `session_unknown` would force the frontend to discriminate by `action` at the dispatch layer too, which is redundant with the listener filter.
3. The fix is symmetric: both backend files gain ONE new branch; both frontend call sites (registration + dispatch) gain ONE new entry. The diff stays small and the contract is explicit.

The clean separation — wire-format name == action, no fallthrough leak — is the right long-term shape.