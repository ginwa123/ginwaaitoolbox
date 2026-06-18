# Stop-Notification Design

**Status:** Approved (backend scope; frontend toast UI is a follow-up plan)
**Date:** 2026-06-19
**Author:** Brainstorming session with user

## Goal

When an LLM response finishes with `finish_reason == .stop`, automatically
record a "Task completed" notification in the database and push it via SSE —
**only if the user is not currently viewing the session**. If the user IS
viewing, nothing happens (they're already looking at the live response).

This is the simplest possible design that solves the use case. There is no
agent tool, no LLM-driven trigger, and no prompt update. The notification is
a pure backend hook that fires on a single LLM state.

## Why this exists (and what it does NOT do)

| Question | Answer |
|---|---|
| Does the LLM need to call a tool? | No. |
| Does the LLM prompt need updating? | No. |
| Does the LLM supply a `message`? | No. It is always `"Task completed"`. |
| Does the `user_attention` type exist? | The column allows it; nothing produces it today. |
| Is the frontend toast UI in scope? | No. This plan only delivers the SSE event the toast will consume later. |
| Does the user need to opt in? | No. The hook fires automatically on every `.stop`. |

## Architecture

```
LLM response
    │
    ▼
handle_tool.zig  (after final tool result / final assistant message)
    │
    │  if finish_reason == .stop
    ▼
notifications.maybeInsertStopNotification(session_id, db, logger, io)
    │
    │  1. isViewing(session_id) ?       ── viewing_state.zig (in-mem map + TTL)
    │      yes → return
    │      no  → continue
    │
    │  2. INSERT INTO notifications   ── sqlite.SqliteBackend
    │
    │  3. onEventSendNotification(...)  ── on_event_sent.zig → event_bus.emit
    │
    ▼
return to caller (no changes to existing return value)
```

## 1. Database (Migration 047)

```sql
CREATE TABLE notifications (
  id TEXT PRIMARY KEY,                          -- "notif_<unix_ms>"
  session_id TEXT NOT NULL,
  type TEXT NOT NULL,                           -- "completed" (reserved: future "user_attention")
  message TEXT,                                 -- always "Task completed" for v1
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_notifications_session ON notifications(session_id, created_at DESC);
CREATE INDEX idx_notifications_created ON notifications(created_at DESC);
```

`type` is kept as a column even though only one value is ever written — it
costs nothing and makes adding `user_attention` (or `error`) a no-schema-change
follow-up.

`created_at` follows the project convention of `TEXT DEFAULT (datetime('now'))`
(ISO 8601 string, matches `sessions.created_at` and every other timestamped
table).

## 2. Viewing state (in-memory, TTL-based)

**`src/ai_workflow/tui/viewing_state.zig`** — small module owning:

```zig
const ViewingEntry = struct { last_seen_at_ms: i64 };
var map: std.StringHashMap(ViewingEntry) = .empty;
var mutex: std.Io.Mutex = .init;

pub fn touch(session_id: []const u8, now_ms: i64) void;
pub fn isViewing(session_id: []const u8, now_ms: i64) bool;
```

`touch()` updates `last_seen_at_ms` for the session (creating the entry if
missing). `isViewing()` returns `true` iff `now_ms - last_seen_at_ms < 30_000`
(30-second TTL). Unknown sessions → `false` (= "not viewing" → notify).

Lost on process restart. That's the desired behavior: a fresh process means the
user has nothing in flight; if they re-open a chat, the first heartbeat
re-populates the entry.

### Why heartbeat-with-TTL (not explicit POST/DELETE)

If the browser tab is closed without `pagehide` firing (force-kill, OS sleep,
network drop), an explicit DELETE never runs and the in-memory flag stays
`true` forever — that session never gets a notification again. A heartbeat
that the server TTLs out handles every case automatically:

| Scenario | Result |
|---|---|
| Browser closed (no `pagehide` fires) | No more heartbeats; after 30s, `isViewing` returns `false` |
| Network drop | Same |
| User on slow connection | 15s heartbeat + 30s TTL = 15s buffer |
| Server restart | Map is empty; first heartbeat re-populates; works |
| User has 3 tabs open, 3 different sessions | Each session gets its own heartbeat; works |
| User closes tab within 30s of LLM completion | At most one late notification (the in-flight completion fires after the TTL expires); acceptable |

The 30s max latency between "user closes tab" and "next notification fires"
is invisible for a "task done" toast.

## 3. LLM-finished hook

A new function in **`src/ai_workflow/tui/notifications.zig`** is called from
`handle_tool.zig` at the end of the dispatch loop, **after** the final tool
result's `saveAndSendToolResult(...)` and **after** the final assistant
message's `sendSSEForLatestMessage(...)`:

```zig
pub fn maybeInsertStopNotification(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    io: std.Io,
    session_id: []const u8,
    finish_reason: ?agent.FinishReason,
) !void {
    // 1. Only fire on terminal-completion
    const fr = finish_reason orelse return;
    if (fr != .stop) return;

    // 2. Skip if user is currently viewing the session
    const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
    if (viewing_state.isViewing(session_id, now_ms)) return;

    // 3. Insert the row
    const id = try std.fmt.allocPrint(allocator, "notif_{d}", .{now_ms});
    defer allocator.free(id);
    db.exec(allocator,
        "INSERT INTO notifications (id, session_id, type, message) VALUES (?, ?, ?, ?)",
        &.{ id, session_id, "completed", "Task completed" }
    ) catch |err| {
        logger.errFmt("notifications: insert failed: {s}", .{@errorName(err)});
        return;
    };

    // 4. Emit SSE event for live push (best-effort)
    on_event_sent.onEventSendNotification(allocator, .{
        .session_id = session_id,
        .notification_type = "completed",
        .message = "Task completed",
        .id = id,
    }) catch |err| {
        logger.errFmt("notifications: SSE emit failed: {s}", .{@errorName(err)});
    };
}
```

### Where it's wired in `handle_tool.zig`

Two call sites:

1. **At the end of the tool-dispatch loop** (after `saveAndSendToolResult` for
   the last tool call), for the case where the LLM ended with tool calls
   followed by a stop:

   ```zig
   // existing line 470:
   try saveAndSendToolResult(...);
   // new:
   try notifications.maybeInsertStopNotification(
       allocator, db, logger, io, session_id, res_dynamic_agent.finish_reason,
   );
   ```

2. **After the assistant message SSE emit** (line 385), for the case where
   the LLM produced only an assistant message (no tool calls) and ended with
   stop:

   ```zig
   // existing line 385:
   try sendSSEForLatestMessage(...);
   // new:
   try notifications.maybeInsertStopNotification(
       allocator, db, logger, io, session_id, res_dynamic_agent.finish_reason,
   );
   ```

The hook is **idempotent and side-effect-isolated** — it never alters the
return value of `handle_tool`, only emits an additional SSE event and writes
an additional DB row. The LLM sees no change.

## 4. SSE event

New struct + function in **`src/ai_workflow/tui/on_event_sent.zig`**,
mirroring `onEventSendWorkers`:

```zig
pub const OnEventInputNotification = struct {
    session_id: []const u8,
    notification_type: []const u8,  // "completed" (reserved: "user_attention")
    message: []const u8,
    id: []const u8,                  // "notif_<ms>"
};

pub const SseEventNotificationPayload = struct {
    type: []const u8 = "notification",
    session_id: []const u8,
    notification_type: []const u8,
    message: []const u8,
    id: []const u8,
    created_at: []const u8,           // ISO 8601
};

pub fn onEventSendNotification(allocator, input) !void {
    const di = tree1_mod.getSingleton() catch return;
    const event_bus = di.event_bus;

    const created_at = ... // ISO 8601 (datetime('now') from the just-inserted row,
                           // or re-format now_ms with std.fmt)

    const payload = SseEventNotificationPayload{ ... };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{ .whitespace = .indent_4 })});
    const data_copy = try allocator.dupe(u8, buf.items);

    event_bus.emit(SseEvent, input.session_id, .{
        .session_id = input.session_id,
        .data = data_copy,
    });
}
```

Emitted on the **session_id** SSE channel — the same channel the chat view
listens on. The frontend's existing SSE client (`sseClient.ts`) does not need
to add a new event-type registration; the new event has `type: "notification"`
in its JSON payload and is dispatched via the default `message` event, which
the chat view's `onEvent` already routes to its message handler.

(Future frontend plan can add a typed listener for `event: notification` if
needed; for v1 the JSON `type` field is enough.)

## 5. HTTP API

| Method | Path | Purpose | Handler file |
|---|---|---|---|
| `POST` | `/api/sessions/:id/viewing` | Heartbeat — `viewing_state.touch(id, now_ms)` | `http_handlers/viewing_set.zig` |
| `GET` | `/api/sessions/:id/notifications?limit=50&since=<iso>` | Per-session notification history (DESC by `created_at`) | `http_handlers/notifications_list.zig` |
| `GET` | `/api/notifications?limit=50&since=<iso>` | Global notification history (DESC by `created_at`) | `http_handlers/notifications_list_all.zig` |

All three follow the established thin-wrapper handler pattern
(`parseFromSliceLeaky`, `valueAlloc`, static source-check tests). The
heartbeat handler is special — no request body, no response body to validate
— it just calls `viewing_state.touch(...)` and returns `{ok: true}`.

### DB helpers in `src/ai_workflow/tui/notifications.zig`

```zig
pub const Notification = struct {
    id: []const u8,
    session_id: []const u8,
    notification_type: []const u8,   // renamed from `type` to avoid Zig keyword clash
    message: ?[]const u8,
    created_at: []const u8,

    pub fn deinit(self: *const Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.notification_type);
        if (self.message) |m| allocator.free(m);
        allocator.free(self.created_at);
    }
};

pub fn listForSession(allocator, db, session_id, limit, since_iso) ![]Notification;
pub fn listAll(allocator, db, limit, since_iso) ![]Notification;
```

Both helpers:
- Default `limit = 50`, cap at `200`
- Optional `since_iso` filter (SQLite: `WHERE created_at > ?`)
- Order by `created_at DESC`
- Return owned `[]Notification`; caller must iterate and `deinit` each + `free` the slice

## 6. Frontend trigger (minimal — 1 setInterval in ChatView.vue)

The heartbeat is a 3-line addition to the existing `ChatView.vue`:

```ts
// new ref + interval in <script setup>
let heartbeatTimer: number | null = null

async function sendHeartbeat() {
  try { await fetch(`/api/sessions/${chatId}/viewing`, { method: 'POST' }) } catch {}
}

onMounted(() => {
  heartbeatTimer = window.setInterval(sendHeartbeat, 15_000)
  sendHeartbeat()  // immediate first beat
})

onUnmounted(() => {
  if (heartbeatTimer !== null) { window.clearInterval(heartbeatTimer); heartbeatTimer = null }
})
```

This is the **only** frontend change in scope of this plan. The toast UI
that consumes the `notification` SSE event is a follow-up.

## 7. File Structure

| File | Action |
|---|---|
| `src/ai_workflow/tui/migration.zig` | Modify — add `Migration047AddNotifications` |
| `src/ai_workflow/tui/viewing_state.zig` | Create — in-memory map + TTL check |
| `src/ai_workflow/tui/viewing_state_test.zig` | Create — unit tests for `touch`/`isViewing` |
| `src/ai_workflow/tui/notifications.zig` | Create — DB helpers + `maybeInsertStopNotification` hook |
| `src/ai_workflow/tui/notifications_test.zig` | Create — DB CRUD + hook tests |
| `src/ai_workflow/tui/on_event_sent.zig` | Modify — add `OnEventInputNotification` + `onEventSendNotification` |
| `src/ai_workflow/tui/handle_tool.zig` | Modify — call `maybeInsertStopNotification(...)` after final tool result + after final assistant message |
| `src/ai_workflow/tui/http_handlers/viewing_set.zig` | Create — POST `/api/sessions/:id/viewing` |
| `src/ai_workflow/tui/http_handlers/viewing_set_test.zig` | Create — static source-check |
| `src/ai_workflow/tui/http_handlers/notifications_list.zig` | Create — GET per-session |
| `src/ai/workforce/tui/http_handlers/notifications_list_all.zig` | Create — GET global |
| `src/ai_workflow/tui/http_handlers/notifications_list_test.zig` | Create — static source-check (both handlers) |
| `src/ai_workflow/tui/http_server.zig` | Modify — register 3 new routes |
| `src/ai_workflow/tui/test_runner.zig` | Modify — register new test files |
| `src/apps/desktop/src/components/ChatView.vue` | Modify — add 15s heartbeat `setInterval` |

## 8. Error Handling

| Scenario | Behavior |
|---|---|
| DB INSERT fails | Log error, **skip SSE emit** (no point showing a toast for an event we can't durably record) |
| SSE emit fails | Log error, row stays in DB (frontend can still pick it up via GET) |
| `finish_reason` is not `.stop` (e.g., `.length`, `.content_filter`, `.tool_calls`) | Skip notification — only `.stop` is the terminal "model has nothing more to say" state |
| Multiple `.stop` responses in a single workflow run (loop iterations) | Insert one notification per `.stop` — each represents a discrete "the model is idle" moment |
| Viewing flag not set / session unknown | Treat as NOT viewing → insert notification |
| Heartbeat for unknown session | `touch` creates the entry on first call — no error |
| Concurrent heartbeat vs `isViewing` | Mutex around map operations; `isViewing` reads `last_seen_at_ms` atomically enough for the 30s TTL window |

## 9. Testing Strategy

- `viewing_state_test.zig` — `touch` updates entry; `isViewing` returns `true` within TTL, `false` after; unknown session is `false`; concurrent touches don't corrupt map
- `notifications_test.zig` — DB CRUD: `listForSession` DESC + limit + `since` filter; `listAll` DESC + limit; `maybeInsertStopNotification` happy path (insert + SSE), `.stop`-skip, `not_stop`-skip, viewing-skip, DB-fail-no-SSE
- `viewing_set_test.zig` — static source-check: calls `viewing_state.touch`, returns `{ok:true}` JSON
- `notifications_list_test.zig` — static source-check: `parseFromSliceLeaky` if any body, `valueAlloc` for response, correct path param name (`req.params.get("id")`), both endpoints registered
- Manual smoke test: open chat, observe heartbeats in DB request log; close tab, wait 30s, kill nalar mid-stream on a different session, verify notification fires only for the not-viewed session

## 10. Out of Scope (YAGNI)

- `user_attention` type — column exists; no producer in this plan
- Frontend toast UI for the SSE `notification` event — follow-up plan
- `read_at` / acknowledged state — frontend can manage dismissed state in local Pinia
- DB persistence of viewing flags — process restart = user has navigated away
- `notifications` cleanup / TTL — a few hundred rows/day is fine
- `user_id` column — single-user desktop app
- Sub-agent tools — N/A (no agent tool)
- Prompt updates — N/A (no agent tool)
- Multi-session "viewing" page in UI — out of scope

## 11. Decisions Locked

1. **No agent tool.** Notifications are auto-inserted by the backend hook, not LLM-driven.
2. **Single type:** `completed`. `user_attention` column is reserved but unused.
3. **Single message:** always `"Task completed"`. No LLM-supplied content.
4. **Heartbeat with TTL** (not explicit POST/DELETE) — survives browser close, network drop, OS sleep.
5. **Both DB row AND SSE event** — DB is the durable record, SSE is the live push.
6. **Hook fires once per `.stop` finish_reason** — multiple iterations in a workflow run each fire independently.
7. **Frontend trigger is in scope** (3-line `setInterval` in ChatView.vue). Frontend toast UI is **out of scope** (follow-up plan).
