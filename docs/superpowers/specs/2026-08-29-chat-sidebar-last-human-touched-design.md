# Chat sidebar — "last human touched" timestamp (design)

**Status:** design (pre-implementation)
**Branch:** `worktree/chat-sidebar-last-human-touched`
**Author:** agent (ginwaaitoolbox)
**Task:** task_1788004921757_1 ("add feature last human touched / also when error too")

## 1. Motivation

The sidebar's per-chat time pill (`ChatsList.vue:162`) reads
`formatRelativeTime(session.updated_at)`. `sessions.updated_at` is bumped by
*everything* — the agent's `update_worker` per-loop tick (`update_worker.zig:107`),
profile change, `insert_llm_histories` cwd patch, `insertWorker` at create, etc.

Concrete failure mode: open the kanban, kick off an agent, leave for 2 hours.
The chat you created now shows "now" / "0s" in the sidebar — it *looks* like
you just touched it, even though you stopped engaging 2 hours ago and the
timestamp is just tracking the agent's last SSE tick.

We already solved this for the **kanban card** — `workspace_item_tasks.last_human_touched_at_nano`
(Migration 065 + 075) is a separate column that only stamps on human action,
and the kanban card uses it to render an orange ⚠ dot for "awaiting your
review". The kanban story is solid; this design ports the same idea to the
**chat sidebar** (which is the explicit ask from this kanban card).

The user explicitly asked for the "also when error too" semantic — when the
agent emits a retry/bail, the user *must* intervene, and bumping
`last_human_touched_at` on error makes that signal visible without needing a
different indicator (the existing red ⚠ from `AgentErrorCard` already covers
the in-chat rendering; the sidebar gets the timestamp bump so it's surfaced
in the glance view too).

## 2. Scope

### 2.1 In scope (this PR)

- Backend
  - Migration 082: add `sessions.last_human_touched_at_nano INTEGER NULL`
  - Pure helper `llm_history.updateSessionLastHumanTouchedAt(alloc, db, session_id, now_unix_ms)`
    (sibling of the existing `updateTaskLastHumanTouchedAt`)
  - HTTP handler stamps (in scope):
    - `session_create.zig::useCase` — POST `/api/llm/session` (human creates)
    - `session_update.zig::useCase` — PUT `/api/llm/session/:session_id` with
      a non-empty `name` / `selected_profile_model` /
      `is_auto_retry_until_stop` (human edits)
    - The user-message funnel `root.zig::emit_run_agent` — single source
      of truth for every "send a message to the agent" code path
      (kanban "create & run agent", kanban "Start agent", `+ Chat`,
      ChatView send button, etc.)
    - Workflow error path: `workflow.zig::saveRetryAttemptMessage` (the 3
      diagnostic sites for retry-catch / unexpected finish_reason / bail)
      bumps `sessions.last_human_touched_at_nano` IN ADDITION to its
      existing `llm_history` insert
  - Wire field `last_human_touched_at` on the `GET /api/sessions` JSON response
    (mirrors the existing `updated_at` field; nullable)
- Frontend
  - `api.getChats` request stays unchanged; the response gains
    `last_human_touched_at: string | null` per session
  - `ChatsList.vue`:
    - Replace `formatRelativeTime(session.updated_at)` with
      `formatRelativeTime(session.last_human_touched_at ?? session.updated_at)`
      — shows the human time when present, falls back to `updated_at`
      for legacy/never-touched rows
    - Add a small **stale dot** (`•`) when `sessions.updated_at >
      sessions.last_human_touched_at` (i.e. the AI has touched the chat
      since the user's last touch) — the "AI is ahead of you" signal
    - Hover tooltip on the time pill: "Last human activity" / "Last activity"
      depending on which one is being shown

### 2.2 Out of scope (follow-ups)

- **Kanban card** — already covered by the existing
  `workspace_item_tasks.last_human_touched_at_nano` + the orange ⚠ indicator
  (`WorkspaceItemTaskCard.vue:487`). No change.
- Visible "since X" date when the human time is older than a week
  (`formatRelativeTime` already returns `6mo`/`2y` strings; not adding
  an absolute date for now).
- Per-row click-to-open "mark as reviewed" gesture (the kanban already
  does this implicitly via `PUT .../touched`; not adding it for the
  sidebar — clicking a sidebar row navigates to the chat, which is the
  natural "I read this" affordance).
- A `since_human_touched` filter / sort order on the chat list API.

## 3. Architecture

### 3.1 Migration shape

```zig
pub const Migration082AddSessionHumanTouchedAt = struct {
    pub const version: u32 = 82;
    pub const name = "add_session_human_touched_at";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            db, allocator,
            "sessions",
            "last_human_touched_at",
            // Same shape as Migration 065 / 075 (the `_nano` suffix is a
            // project-uniform convention that means "integer since Unix
            // epoch", not a precision assertion — the actual stored unit
            // is unix-ms; see Migration 075 docstring).
            "last_human_touched_at_nano INTEGER NULL",
        );
    }
};
```

- Nullable `INTEGER` — NULL is the canonical "never touched by a human"
  state. Legacy pre-migration rows stay NULL; the frontend
  transparently falls back to `updated_at`.
- No index on this column — the existing `idx_sessions_updated_at` covers
  the sort-by-latest path. Adding an index on `last_human_touched_at_nano`
  is YAGNI until the chat list gains a sort-by-human-time filter
  (out of scope §2.2).
- The wire / struct field stays `last_human_touched_at` (no `_nano`
  suffix) — the project convention from Migration 075 is "column =
  `_nano`, wire = bare name". The `SessionInfo` Zig struct has no
  field today; we add `last_human_touched_at: ?[]u8` (unix-ms INTEGER
  stored as text via the project's `SqliteBackend.exec` rule that
  always binds TEXT — same convention as `updateTaskLastHumanTouchedAt`).

### 3.2 Stamp helper

```zig
// Lives in src/ai_workflow/tui/agentic_loop/llm_history.zig
// Sibling of updateTaskLastHumanTouchedAt (line 3355).
pub fn updateSessionLastHumanTouchedAt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    now_unix_ms: ?i64,
) !void {
    const now_ms = now_unix_ms orelse unixMillisNow();
    const touched_at_str = try std.fmt.allocPrint(
        allocator, "{d}", .{now_ms},
    );
    defer allocator.free(touched_at_str);

    const sql =
        "UPDATE sessions SET last_human_touched_at_nano = ? WHERE id = ?";
    try db.exec(allocator, sql, &.{ touched_at_str, session_id });
}
```

`null` `now_unix_ms` ⇒ read the real current time via libc `gettimeofday`
(matches the existing `updateTaskLastHumanTouchedAt` pattern; Zig 0.16
removed `std.time.timestamp`). Idempotent — re-stamping is harmless.

### 3.3 Stamp sites

The 3 stamp sites — every human-actionable chat mutation funnels through
exactly one of these. No double-stamping (verified by reading each
plumbing path).

| Site | Why it counts | Notes |
|---|---|---|
| `root.zig::emit_run_agent` | **The single funnel for every "user sends a message" code path** — kanban "create task & run agent", kanban "Start agent", `+ Chat` button, ChatView send button, etc. (every chat-send UI binds to it via `ctx.emit_run_agent(input)`). Also covers `session_create.zig::useCase` which delegates to it (line 229), so the create-chat case is handled for free. | Stamp **before** the workflow kicks off (so even an immediate agent bail still leaves the stamp in place). Best-effort — log + continue on error so a transient DB blip doesn't block message delivery. |
| `session_update.zig::useCase` (PUT `/api/llm/session/:session_id`) | User edits name / profile / unattended toggle | Stamp once per PUT *that actually changes a field*. The handler skips the no-op case (where `name === ''`, `selected_profile_model === ''`, `is_auto_retry_until_stop === ''`), so the stamp only fires on a real edit — no need for a separate guard. |
| `workflow.zig::saveRetryAttemptMessage` | "Also when error too" — every retry/bail diagnostic already funnels through this helper (3 sites: retry-catch line 1056, finish_reason line 1258, soft/hard bail). The existing INSERT adds an `llm_history` row with `is_error=true`; one extra UPDATE bumps the session. | Defensively correct: when an error happens the user must intervene, and the timestamp should reflect that. Wrapped in `defer`-safe `catch |err| log.warn(...)` so a stamp failure doesn't shadow the error emit. |

No explicit "user opened the chat" stamp endpoint (the kanban already
has `PUT .../tasks/:task_id/touched`; we don't add a sibling for the
sidebar — clicking is a navigation, not a touch).

### 3.4 Why one funnel covers both create + send

`session_create.zig::useCase` (line 229) calls `di.emit_run_agent(...)`.
By placing the session stamp at the top of `emit_run_agent` we
single-source the rule:

```
ChatView send   ─┐
kanban Start    ─┤
+ Chat button   ─┼── root.zig::emit_run_agent ── stamps session ──► workflow.zig
create & run    ─┤                                          
session_create  ─┘
```

A test in `migration_082_test.zig` + a static contract grep in
`session_create_test.zig` lock in the "one funnel, no double-stamp"
invariant.

### 3.5 GET /api/sessions wire change

```jsonc
GET /api/sessions?limit=30&sort_by=updated_at&direction=desc
{
  "sessions": [
    {
      "id": "session_1785055733544_...",
      "name": "adjust husky,",
      "status": "active",
      "updated_at": "1787998836735",
      "last_human_touched_at": "1787998000000",  // NEW — unix-ms as string, may be null
      "selected_profile_model": "",
      ...
    }
  ],
  "total": 17,
  "has_more": false,
  "next_cursor": "..."
}
```

The field is `null` for legacy rows. The frontend treats `null` as
"never touched by human" → fallback to `updated_at` + no stale dot.

## 4. Frontend display

`ChatsList.vue` row (around line 484):

```vue
<span class="text-xs opacity-60 shrink-0 ml-2 flex items-center gap-1">
  <!-- Stale dot: AI has touched since the user's last touch -->
  <span
    v-if="isStale(item.last_human_touched_at, item.updated_at)"
    class="w-1 h-1 rounded-full bg-amber-400"
    title="AI is still working — your last touch was earlier"
  />
  <span
    :title="item.last_human_touched_at
      ? 'Last human activity'
      : 'Last activity (never touched by you yet)'"
  >{{ item.relativeTime || 'now' }}</span>
</span>
```

`isStale(human, updated)`:
- `false` when `human === null` (no human time yet, nothing to be stale against)
- `false` when `updated <= human` (in sync)
- `true` when `updated > human` by ≥ 1 second

Functional test coverage: `tests/functional/session_human_touched_at_test.py`
boots a real `pabrik`, sends messages, simulates an error, asserts the
column updates on the wire.

Unit test coverage (frontend): `ChatsList.relativeTime.spec.ts` with
6 cases:
1. `last_human_touched_at` populated → renders that time
2. `last_human_touched_at` null → renders `updated_at`
3. `last_human_touched_at < updated_at` → renders human time + stale dot
4. `last_human_touched_at == updated_at` (no AI touch since) → no stale dot
5. `last_human_touched_at > updated_at` (clock skew — shouldn't happen in
   practice but defensive) → no stale dot, renders the more-recent one
6. Both null (legacy) → renders "now" with no stale dot

## 5. Decisions

### 5.1 Stamp-on-error semantics

**Decision:** Bumping `last_human_touched_at` on agent errors is
implemented in `workflow.zig::saveRetryAttemptMessage` (every retry/bail
diagnostic site already funnels through this helper), so we get the
bump for free on every error emit. We do NOT add a separate stamp in
the success path.

**Why:** the user's request was "last human touched — also when error
too". The literal interpretation is "show me the timestamp; when there's
an error, the timestamp should reflect that I'm implicated now". Adding
a stamp at the existing error funnel is the minimal change that
delivers exactly that semantic.

**Trade-off accepted:** the timestamp may briefly bump to the error
emit time before the user actually opens the chat. Acceptable — the
error is *more* actionable than a stale human-time, and the user can
still see the kanban ⚠ indicator for the canonical "needs review" state.

### 5.2 No PUT /api/.../sessions/:id/touched endpoint

**Decision:** No `/touched` endpoint for sessions. The kanban already has
one for tasks because tasks have an "open card to read" affordance
that's a state change for the kanban board; chats have no analogous
"open to read" state change — clicking a sidebar row just navigates.

**Why:** YAGNI. The 4 stamp sites (create / update / emit_run_agent /
error) cover every human-actionable chat mutation. Adding a click-only
stamp would be noisy (browsing shouldn't reset the timestamp) and
would require a new endpoint + frontend integration with no observable
benefit.

### 5.3 Column name = `_nano`, wire name = bare

**Decision:** SQL column is `last_human_touched_at_nano`. JSON wire
field is `last_human_touched_at`. Same as Migration 075.

**Why:** Project-uniform convention (the rename plan §"Naming choice"
explicitly says "integer stored since Unix epoch" — actual stored unit
is unix-ms for this column, same as the sibling task column). Breaking
the convention here for one column would create ambiguity in future
migrations.

### 5.4 Stale-dot color = amber-400

**Decision:** The stale dot uses `bg-amber-400` (same palette family as
the kanban's orange ⚠).

**Why:** Visual consistency with the established "human attention
required" affordance. A neutral grey would lose the "AI is ahead of
you" semantic; red would conflate with the actual error indicator (a
different thing — the error path bumps the timestamp, the dot is a
*general* stale signal).

## 6. Out of scope (cross-cutting)

- No changes to the kanban card (`WorkspaceItemTaskCard.vue`,
  `WorkspaceItemTaskRow.vue`) — already covered.
- No changes to `WorkspaceItemTaskResponse` (`Task` type) — the field
  is already on the task wire.
- No new SSE event type — the existing
  `onEventSendSessions(action="updated")` is sufficient.
  `last_human_touched_at` is just another column the existing
  serializer already emits on every session event (the field is on
  `SessionInfo`, line ~118 of `on_event_sent.zig`).
- No new db connection / new tooling — pure additive migration +
  UPDATE-in-existing-handler call sites.

## 7. Open questions

None. All design decisions resolved with user during brainstorming
(2026-08-29 morning chat, options A/B/C presented → C picked, kanban
scope excluded per existing ⚠ indicator).
