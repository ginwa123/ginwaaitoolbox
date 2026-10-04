# Chat Sidebar — `last_human_touched_at` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `sessions.last_human_touched_at_nano` column (Migration 082) that only stamps on human action + agent errors, surface it on the `GET /api/sessions` wire, and replace the sidebar time pill with `formatRelativeTime(last_human_touched_at ?? updated_at)` plus an amber stale-dot when AI has touched the chat since the user's last touch.

**Architecture:** 3-tier pattern matching the project's existing layers:

1. **Storage primitive** — `llm_history.updateSessionLastHumanTouchedAt(alloc, db, session_id, now_unix_ms)` (pure DB write, no DI plumbing). Sibling of the existing `updateTaskLastHumanTouchedAt` at `src/ai_workflow/tui/agentic_loop/llm_history.zig:3355`. Inline tests + 1 migration (082).

2. **Stamp sites** — 3 places:
   - `root.zig::emit_run_agent` — **the single funnel** for every "user sends a message" path (chat send button, kanban "create & run", kanban "Start agent", `+ Chat`). Replaces the existing `updateTaskLastHumanTouchedAt` call in `session_create.zig:241` (the create path delegates to `emit_run_agent`, so we get both create + send for free).
   - `session_update.zig::useCase` — only when a real field is set.
   - `workflow.zig::saveRetryAttemptMessage` — "also when error too".

3. **Wire field** — `SessionInfo.last_human_touched_at: ?[]u8` + `buildSessionListJson` serializes it. Frontend type `Session` gains `last_human_touched_at: string | null`. `ChatsList.vue` swaps the timestamp source + adds a 1-line stale-dot.

**Scope:** Sidebar ONLY. The kanban card already has the same idea via `workspace_item_tasks.last_human_touched_at_nano` + the orange ⚠ indicator at `WorkspaceItemTaskCard.vue:487`. No frontend work on the kanban components in this PR.

**Tech Stack:**
- **Backend:** Zig 0.16, SQLite (via `src/databases` + `SqliteBackend`), `addColumnIfMissing` migration helper
- **Frontend:** Vue 3 + TypeScript, Pinia (`stores/workspaces.ts`), vitest, pnpm
- **Functional tests:** `tests/functional/harness.py` + pytest, isolated tmpdir HOME per test
- **Build:** `zig build test --summary all`, `zig build pabrik-desktop --summary all`, `pnpm test:unit`, `pytest tests/functional/<name>_test.py -v`

## What exists today (read this before changing anything)

- **Storage helper sibling** — `updateTaskLastHumanTouchedAt(allocator, db, task_id, now_unix_ms)` at `src/ai_workflow/tui/agentic_loop/llm_history.zig:3355`. The `now_unix_ms: ?i64` arg pattern (null ⇒ read real clock via libc `gettimeofday` per the project's Zig 0.16 shim); `db.exec` binds the unix-ms INTEGER as TEXT (per `sqlite-backend-exec-binds-text-only`).
- **Single send-message funnel** — `root.zig:111::emit_run_agent(obj: EmitRunAgentInput)`. Every UI that sends a message calls `ctx.emit_run_agent(input)` → ends up here. `session_create.zig::useCase` also delegates here (line 229), so a stamp at the top of `emit_run_agent` covers the create path without doubling.
- **Existing task stamp** — `session_create.zig:241` calls `ai_workflow.llm_history.updateTaskLastHumanTouchedAt(alloc, di.db, session_id, null)` with `catch |err| std.log.warn(...)`. **This task-side call stays** (it stamps the kanban task row, different table).
- **Error emit point** — `workflow.zig::saveRetryAttemptMessage` (line 1416), called from 3 sites: retry-catch (line 1056), unexpected finish_reason (line 1258), soft/hard bail. Already inserts an `llm_history` row with `is_error=true`. We add ONE sibling UPDATE to bump `sessions.last_human_touched_at_nano`.
- **SessionInfo + serializer** — `src/ai_workflow/tui/agentic_loop/on_event_sent.zig:118` (`SessionInfo` struct) + `llm_history::buildSessionListJson`. Adding a field requires touching both.
- **Sidebar time pill** — `src/apps/desktop/src/components/views/ChatsList.vue:162` (`relativeTime: formatRelativeTime(session.updated_at)`) + line 484 (`<span class="text-xs opacity-60 shrink-0 ml-2">{{ item.relativeTime || 'now' }}</span>`).
- **Format helper** — `src/apps/desktop/src/helpers/relativeTime.ts` (takes a SQLite UTC string, returns "now"/"2h"/etc.). Same helper works for both fields — no frontend helper changes.

---

## File Structure

### New files

```
src/migrations/migration_082_test.zig              # Static-contract + behavioural tests for Migration 082
src/ai_workflow/tui/agentic_loop/session_human_touched_at_test.zig  # Tests for the helper + serializer field
src/apps/desktop/src/__tests__/ChatsList.relativeTime.spec.ts   # 6-case frontend display tests
tests/functional/session_human_touched_at_test.py   # Boot pabrik + wire roundtrip
```

### Edited files

```
src/migrations/migration.zig                                              # Register Migration082AddSessionHumanTouchedAt
src/ai_workflow/tui/agentic_loop/llm_history.zig                          # `updateSessionLastHumanTouchedAt` + `SessionInfo.last_human_touched_at`
src/ai_workflow/tui/agentic_loop/workflow.zig                             # Stamp on error in `saveRetryAttemptMessage`
src/ai_workflow/tui/agentic_loop/on_event_sent.zig                        # SessionInfo gains `last_human_touched_at` field
src/root.zig                                                              # Stamp in `emit_run_agent` (the single funnel)
src/ai_workflow/tui/http_handlers/session_update.zig                      # Stamp on real-field PUT
src/ai_workflow/tui/http_handlers/session_create.zig                      # DELETE the now-redundant task-side stamp call (replaced by emit_run_agent)
src/ai_workflow/tui/http_handlers/session_create_test.zig                 # Static-contract: stamp is in emit_run_agent, NOT in session_create.useCase
src/ai_workflow/tui/agentic_loop/test_runner.zig                          # Register new test file
src/migrations/test_runner.zig                                            # Register migration_082_test.zig
src/apps/desktop/src/api/index.ts                                         # Session type gains `last_human_touched_at: string | null`
src/apps/desktop/src/components/views/ChatsList.vue                      # Swap timestamp + add stale-dot
src/apps/desktop/src/stores/workspaces.ts                                 # WorkspaceState Session type mirror (if separate)
PABRIK.md                                                                  # Recent changes entry
```

### NOT changed

- `WorkspaceItemTaskCard.vue`, `WorkspaceItemTaskRow.vue` — already covered by `last_human_touched_at` + the ⚠ indicator.
- `Task` type — task column already on the wire.
- `mcp_*` tools, MCP transports, `add_mcp_server` — unrelated.
- `update_worker.zig:107` (the AI loop tick) — must NOT stamp, that's the whole point.

---

## Design Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Stamp in `emit_run_agent` (single funnel), not duplicated in `session_create.useCase` | Every user-message path (chat send, kanban create & run, kanban Start, `+ Chat`) already delegates to `emit_run_agent`. Putting the stamp here covers all of them with one call site. `session_create.useCase:241`'s existing `updateTaskLastHumanTouchedAt` stays for the *task* side; we just don't add a sibling *session* stamp there. |
| D2 | Stamp in `saveRetryAttemptMessage`, NOT in `workflow.zig` main loop | The 3 error sites (retry-catch, unexpected finish_reason, TooManyRetries bail) all funnel through `saveRetryAttemptMessage`. One call site covers all errors. Wrapped in `catch \|err\| std.log.warn(...)` so a stamp failure doesn't shadow the actual error emit. |
| D3 | SQL column = `_nano` suffix, JSON wire field = bare `last_human_touched_at` | Matches Migration 075 project convention ("integer since Unix epoch", actual stored unit = unix-ms). |
| D4 | Stale-dot = `bg-amber-400`, NOT red | Matches the kanban ⚠ palette; red would conflate with the in-chat error indicator (a different concept). |
| D5 | Legacy NULL rows fall back to `updated_at` in the frontend | No backfill needed; pre-migration sessions keep showing their existing AI-tainted time, which is no worse than today. New rows get the proper human time from `emit_run_agent`. |
| D6 | No new SSE event type | The existing `onEventSendSessions(action="updated")` already re-emits the full session payload on any UPDATE; the new column rides for free. |

---

## Global Constraints

- **Per-request Arena Cleanup** — handlers allocate from `ctx.allocator` (arena) → NO `defer allocator.free` inside HTTP handlers or tool exec for slices owned by the allocator. The `now_unix_ms` formatters in `updateSessionLastHumanTouchedAt` use `try ... defer allocator.free(...)` because the SQL parameter is arena-bound and the helper runs in a per-call arena (not the handler arena) — same as the sibling task helper.
- **Tests live INLINE at the bottom of impl files** (`test "..." { }` blocks). New HTTP-handler test files use `_ = @import(...)` in `src/ai_workflow/tui/test_runner.zig`.
- **No new CHANGELOG file** — update `PABRIK.md` (§"Recent changes") with one entry that lands on the same commit as the wire-up task.
- **Empty-slice-as-NULL rule** — `SqliteBackend.exec` binds `""` as SQL NULL. The helper only stamps when the SQL UPDATE receives a non-empty `touched_at_str`; for empty we treat as a no-op (early return) to avoid the trap.
- **SSE wire-format contract** — we add NO new SSE event names. The column rides on the existing `session.updated` event.
- **DONT KILL THE PORT 8081 SERVER** — functional harness uses ports 8080..8199.
- **No port-8081 live-server + curl verification** — use the python functional harness + Zig unit tests.
- **`_nano` suffix convention** — column is `last_human_touched_at_nano` (SQL), wire field is `last_human_touched_at` (JSON), struct field is `last_human_touched_at` (Zig).

---

## Step-by-Step Plan

### Step 1: Migration 082 — add `sessions.last_human_touched_at_nano`

**File:** `src/migrations/migration.zig` (add a new pub const + register) + `src/migrations/migration_082_test.zig` (new file, inline tests).

**Sub-steps:**
- [ ] Add `pub const Migration082AddSessionHumanTouchedAt` struct (sibling of `Migration065AddTaskHumanTouchedAt` at line 2414). Use `addColumnIfMissing(db, allocator, "sessions", "last_human_touched_at", "last_human_touched_at_nano INTEGER NULL")` — same call shape as Migration 065.
- [ ] Register in the `allMigrations` array (around line 1959, after `Migration081CreateAgentKanbans`).
- [ ] Create `src/migrations/migration_082_test.zig` with these inline tests:
  1. Column `last_human_touched_at_nano` exists in `pragma_table_info(sessions)` after `Migration082.up`.
  2. Column is nullable (no NOT NULL constraint).
  3. Fresh-DB path: Migration082 on an empty DB succeeds and the column is present.
  4. Upgrade path: a DB created up through Migration081 (no column) gets the column added by Migration082.
  5. Idempotency: re-running `Migration082.up` is a no-op (uses `addColumnIfMissing`).
- [ ] Add `_ = @import("migration_082_test.zig");` to `src/migrations/test_runner.zig`.
- [ ] Run `zig build test --summary all` — must pass with no regressions + 5 new tests.
- [ ] Commit: `feat(migration 082): add sessions.last_human_touched_at_nano`

### Step 2: Pure helper — `updateSessionLastHumanTouchedAt`

**File:** `src/ai_workflow/tui/agentic_loop/llm_history.zig` (append after the existing `updateTaskLastHumanTouchedAt` at line 3372). New test file `src/ai_workflow/tui/agentic_loop/session_human_touched_at_test.zig`.

**Sub-steps:**
- [ ] Write the failing test first: `updateSessionLastHumanTouchedAt stamps unix-ms into sessions.last_human_touched_at_nano` (in-memory DB, INSERT a session row, call helper with `now_unix_ms = 1234567890`, SELECT the column back, assert equal).
- [ ] Run it → fails (no function yet).
- [ ] Implement `updateSessionLastHumanTouchedAt(allocator, db, session_id, now_unix_ms) !void`. Mirror `updateTaskLastHumanTouchedAt` exactly, just with the SQL `UPDATE sessions SET last_human_touched_at_nano = ? WHERE id = ?`. Reuse the `unixMillisNow()` helper from line 3386+ (same module, no new extern).
- [ ] Run the test → passes.
- [ ] Add 4 more inline tests in the same file:
  6. `now_unix_ms = null` reads real clock (just assert non-null + recent, not exact value).
  7. Unknown session_id is a no-op (no error, 0 rows affected — defensive).
  8. Idempotent: calling twice with same arg leaves the same value.
  9. Empty session_id (`""`) is silently skipped — guard with `if (session_id.len == 0) return;` (matches the empty-slice-as-NULL rule).
- [ ] Register the test file in `src/ai_workflow/tui/agentic_loop/test_runner.zig` via `_ = @import("session_human_touched_at_test.zig");`.
- [ ] Run `zig build test --summary all` → 5 new tests pass.
- [ ] Commit: `feat(llm_history): updateSessionLastHumanTouchedAt helper`

### Step 3: Stamp in `emit_run_agent` (the single funnel)

**File:** `src/root.zig` (inside the `emit_run_agent` function at line 111).

**Sub-steps:**
- [ ] Write a static-contract test in `src/ai_workflow/tui/http_handlers/session_create_test.zig` (it already exists — append a new test). Asserts: `session_create.zig`'s source body does NOT contain `updateSessionLastHumanTouchedAt` (because the session stamp lives in `emit_run_agent`, not session_create — D1). Fails closed with `error.SessionHumanTouchedStampDuplicateSite`.
- [ ] Run the test → fails (the static check is new; everything else passes).
- [ ] Open `src/root.zig`. Just after the `try self.sessions_map.put(...)` / equivalent setup at the top of `emit_run_agent`, add:
  ```zig
  ai_mod.llm_history.updateSessionLastHumanTouchedAt(
      self.allocator,
      self.db,
      obj.session_id,
      null,
  ) catch |stamp_err| {
      std.log.warn(
          "emit_run_agent: stamp session last_human_touched_at failed (non-fatal): {s}",
          .{@errorName(stamp_err)},
      );
  };
  ```
  (Place it after the queue_message validation / BEFORE the worker row insert so the stamp lands even if the worker spawn fails — matches the "user just touched it" semantic.)
- [ ] Run the static-contract test → passes.
- [ ] Run `zig build test --summary all` → no regressions.
- [ ] Commit: `feat(emit_run_agent): stamp sessions.last_human_touched_at`

### Step 4: Stamp in `session_update.zig::useCase`

**File:** `src/ai_workflow/tui/http_handlers/session_update.zig` (inside `useCase` around line 95, before the final JSON response).

**Sub-steps:**
- [ ] Write a static-contract test that asserts: `session_update.zig`'s source contains `updateSessionLastHumanTouchedAt`. (Use the same `contains(...)` helper pattern as `session_create_test.zig:432`.) Fails closed with `error.SessionUpdateHumanTouchedStampMissing`.
- [ ] Run the test → fails.
- [ ] In `session_update.zig::useCase`, after the existing field-update calls (`updateSessionSelectedProfileModel`, `updateSessionName`, `updateSessionAutoRetryUntilStop`), add:
  ```zig
  // Stamp sessions.last_human_touched_at — the handler only gets
  // here when at least one real field was changed (the early-return
  // on empty body guards the rest).
  llm_history.updateSessionLastHumanTouchedAt(
      allocator, sqlite_db, session_id, null,
  ) catch |stamp_err| {
      std.log.warn(
          "session_update: stamp last_human_touched_at failed (non-fatal): {s}",
          .{@errorName(stamp_err)},
      );
  };
  ```
- [ ] Run the static-contract test → passes.
- [ ] Run `zig build test --summary all` → no regressions.
- [ ] Commit: `feat(session_update): stamp sessions.last_human_touched_at on real edit`

### Step 5: Stamp in `workflow.zig::saveRetryAttemptMessage`

**File:** `src/ai_workflow/tui/agentic_loop/workflow.zig` (append a stamp inside `saveRetryAttemptMessage` around line 1416, right after the existing `llm_history` INSERT).

**Sub-steps:**
- [ ] Write the failing test first (inline in `workflow.zig` or a sibling test file — prefer sibling for cleanliness):
  - Test name: `saveRetryAttemptMessage stamps sessions.last_human_touched_at on retry`
  - Set up: in-memory DB with a sessions row, `last_human_touched_at_nano` is NULL initially
  - Action: call `saveRetryAttemptMessage` with a forced error
  - Assert: `SELECT last_human_touched_at_nano FROM sessions WHERE id = ?` returns a recent unix-ms value
- [ ] Run the test → fails.
- [ ] In `saveRetryAttemptMessage`, just after the existing `try llm_history.saveMessage(...)` call (or wherever the function currently commits the error record), add:
  ```zig
  llm_history.updateSessionLastHumanTouchedAt(
      allocator, db, copy_session_id, null,
  ) catch |stamp_err| {
      std.log.warn(
          "saveRetryAttemptMessage: stamp session last_human_touched_at failed (non-fatal): {s}",
          .{@errorName(stamp_err)},
      );
  };
  ```
  (The `defer |err|`-free `copy_session_id` is in scope — same lifetime as the existing saveMessage call.)
- [ ] Run the test → passes.
- [ ] Run `zig build test --summary all` → no regressions.
- [ ] Commit: `feat(workflow): stamp sessions.last_human_touched_at on agent error`

### Step 6: Wire field on `SessionInfo` + `buildSessionListJson`

**Files:** `src/ai_workflow/tui/agentic_loop/on_event_sent.zig` (add field to `SessionInfo` around line 118) + `src/ai_workflow/tui/agentic_loop/llm_history.zig` (extend `buildSessionListJson` to emit the new field).

**Sub-steps:**
- [ ] In `on_event_sent.zig`, add `last_human_touched_at: ?[]u8` to `SessionInfo`. Update `deinit` to free it. Update the doc-comment that lists the table columns (around line 118).
- [ ] In `llm_history.zig::buildSessionListJson`, find the SELECT statement that powers the session list response. Extend it with `SELECT last_human_touched_at_nano AS last_human_touched_at FROM sessions ...` (alias to keep the wire field name unchanged per D3). Map the column into the `SessionInfo` struct.
- [ ] Write a test in `session_human_touched_at_test.zig` (the file from Step 2):
  - Insert a session with a known `last_human_touched_at_nano` value
  - Call `buildSessionListJson`
  - Assert the JSON envelope contains `"last_human_touched_at":"<unix_ms>"`
  - Assert legacy NULL row emits `"last_human_touched_at":null`
- [ ] Run the test → passes.
- [ ] Run `zig build test --summary all` → no regressions.
- [ ] Commit: `feat(session_list): surface last_human_touched_at on the wire`

### Step 7: Frontend type + mapper

**Files:** `src/apps/desktop/src/api/index.ts` (the `Session` type used by `getChats`).

**Sub-steps:**
- [ ] Find the `Session` type (or wherever `getChats`'s response is typed — likely `interface Session { id, name, updated_at, ... }`).
- [ ] Add `last_human_touched_at: string | null` to the type.
- [ ] No mapper change needed — the field passes through as-is. The existing `api.getChats` already returns the raw response.
- [ ] Write a TypeScript test (`src/apps/desktop/src/__tests__/api.getChats.spec.ts` — new file):
  - Mock the fetch / response with a session that has `last_human_touched_at: '1234'`
  - Assert the parsed Session object has the field
  - Mock another response with `last_human_touched_at: null`
  - Assert `null` survives parsing (the wire is `null`, not the string `'null'`)
- [ ] Run `pnpm test:unit --run api.getChats.spec.ts` → passes.
- [ ] Run `pnpm test:unit` (full suite) → no regressions.
- [ ] Commit: `feat(api): type Session.last_human_touched_at`

### Step 8: `ChatsList.vue` — replace timestamp + add stale dot

**File:** `src/apps/desktop/src/components/views/ChatsList.vue`.

**Sub-steps:**
- [ ] In the `loadChats` mapping (around line 153-168), add `last_human_touched_at: session.last_human_touched_at || null` to each navItem.
- [ ] Same for `loadMoreChats` (around line 205-211).
- [ ] In the template, replace the existing `<span class="text-xs opacity-60 shrink-0 ml-2">{{ item.relativeTime || 'now' }}</span>` (around line 484) with the option-C markup from the spec §4:
  ```vue
  <span class="text-xs opacity-60 shrink-0 ml-2 flex items-center gap-1">
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
- [ ] Add the `isStale(human, updated)` helper in `<script setup>`:
  ```ts
  const isStale = (human: string | null, updated: string): boolean => {
    if (!human) return false
    // Both come from the backend as unix-ms strings (Migration 075
    // convention). Compare as numbers.
    return Number(updated) > Number(human)
  }
  ```
- [ ] Update `loadChats` / `loadMoreChats` to source `relativeTime` from the human-touched column when present (fallback to `updated_at`):
  ```ts
  const tsForRelative = item.last_human_touched_at || session.updated_at
  relativeTime: formatRelativeTime(tsForRelative),
  ```
- [ ] Write the 6 frontend tests in `ChatsList.relativeTime.spec.ts` (the spec §4 cases):
  1. populated → renders that time
  2. null → renders `updated_at`
  3. populated < updated → renders human + stale dot
  4. populated == updated → no stale dot
  5. populated > updated (defensive) → no stale dot
  6. both null → renders "now" + no stale dot
- [ ] Run `pnpm test:unit --run ChatsList.relativeTime.spec.ts` → 6 pass.
- [ ] Run `pnpm test:unit` (full suite) → no regressions.
- [ ] Commit: `feat(chats list): replace time pill with last_human_touched + stale dot`

### Step 9: Functional test

**File:** `tests/functional/session_human_touched_at_test.py` (new).

**Sub-steps:**
- [ ] Boot a fresh `pabrik` against an isolated tmpdir HOME per the harness.
- [ ] **Test 1 — happy path**: POST `/api/llm/session` to create a chat with a `queue_message` → assert the GET `/api/sessions` response includes `last_human_touched_at: <recent unix-ms>`.
- [ ] **Test 2 — PUT stamps**: PUT `/api/llm/session/:id` with `{name: "renamed"}` → assert `last_human_touched_at` was updated to a newer value than the create time.
- [ ] **Test 3 — error stamps**: trigger an error path (e.g. POST a session with an invalid queue_message that forces a retry/bail, OR call `dev_sse_emit.zig`'s `is_error=true` endpoint) → assert `last_human_touched_at` was updated.
- [ ] **Test 4 — legacy NULL row**: insert a session row directly via SQL with `last_human_touched_at_nano = NULL` (bypassing `emit_run_agent`) → GET → assert the JSON has `"last_human_touched_at": null` and the sidebar would render the fallback.
- [ ] **Test 5 — wire format**: confirm the JSON field name is exactly `last_human_touched_at` (no `_nano` suffix on the wire, per D3).
- [ ] Run `pytest tests/functional/session_human_touched_at_test.py -v` → 5 pass.
- [ ] Run `pytest tests/functional/` (full suite) → no regressions.
- [ ] Commit: `test(functional): sessions.last_human_touched_at end-to-end`

### Step 10: Final verification + changelog

**Files:** `PABRIK.md` (§"Recent changes" entry).

**Sub-steps:**
- [ ] Add a Recent changes entry to `PABRIK.md` summarizing:
  - Migration 082 + new column
  - `updateSessionLastHumanTouchedAt` helper (sibling of task version)
  - 3 stamp sites (emit_run_agent, session_update, saveRetryAttemptMessage)
  - Frontend `last_human_touched_at` field + stale dot
  - Test totals: expected `zig build test --summary all` +5 new tests for migration + 5 new tests for helper + 1 static-contract test + new test files (front + back); `pnpm test:unit` +6 new tests for ChatsList relativeTime + new test for api.getChats.
- [ ] Run `zig build test --summary all` — confirm 0 regressions.
- [ ] Run `pnpm test:unit` — confirm 0 regressions.
- [ ] Run `pytest tests/functional/session_human_touched_at_test.py -v` — confirm 5 pass.
- [ ] Run `zig build pabrik-desktop --summary all` — confirm desktop binary builds.
- [ ] Commit: `docs: PABRIK.md recent changes for sessions.last_human_touched_at`
- [ ] Push branch + open PR for human review (move kanban card to `in_review_task`).

---

## Out of scope (explicit)

- Kanban card display (`WorkspaceItemTaskCard.vue`, `WorkspaceItemTaskRow.vue`) — already covered by `last_human_touched_at` + ⚠ indicator.
- Adding an index on `sessions.last_human_touched_at_nano` — YAGNI until we add a sort-by-human-time filter.
- New SSE event type — the column rides on the existing `session.updated` event.
- Per-row click-to-stamp endpoint (the kanban's `PUT /touched`) — sidebar navigation is not a touch.
- Backfilling legacy NULL rows — frontend fallback to `updated_at` makes this unnecessary.