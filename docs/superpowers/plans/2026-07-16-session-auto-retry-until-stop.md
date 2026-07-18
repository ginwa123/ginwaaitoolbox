# Session Auto-Retry-Until-Stop (long-running unattended sessions)

## Goal

Let the user opt a session into an **unattended, overnight-OK mode** that keeps retrying the LLM call indefinitely (past the current 10-attempt `TooManyRetries` bail) when transient upstream failures occur. Persist the setting per session so the mode survives server restarts and survives across the LLM's mid-response failures.

Two new columns on `sessions`:
- `is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0` — the opt-in flag (boolean).
- `last_finish_reason TEXT` — the most recent `finish_reason` the workflow observed for the session (denormalized cache of `MAX(llm_history.finish_reason)` for fast checks).

The user-facing semantic: a session with `is_auto_retry_until_stop = 1` will keep retrying `callDynamicAgentNew` through `NetworkError` / `RateLimit` / `StreamTimeout` / `ECONNRESET`-class errors forever (as long as the `nalar` process is up), respecting the existing `config.retry_delay_ms` between attempts and logging each retry to chat history. Only **`session_stop`** (manual stop) or hard process exit stops such a session.

## Architecture

**Backend (Zig)**:
1. **Migration 063** adds the two columns to `sessions`. `is_auto_retry_until_stop` defaults to 0 (= existing behavior). `last_finish_reason` defaults to NULL.
2. **`workflow.zig` retry-budget gate** reads `is_auto_retry_until_stop` for the session at the top of `runAgenticMultiStepnew`. When 0 → existing behavior (`retry_count > 10` → bail with `error.TooManyRetries`). When 1 → never bail; keep going with `retry_delay_ms` between every retry attempt.
3. **Per-iteration `last_finish_reason` write-back**: after every `callDynamicAgentNew` returns, `workflow.zig` issues a single `UPDATE sessions SET last_finish_reason = ?` so that on a future restart the workflow starts with the correct "last completed turn" state.
4. **`llm_history.zig` CRUD helpers**: `create_session` accepts the new flag and persists it on INSERT; `update_session_*` helpers expose a setter; `getSession` / `getSessionListWithCursor` SELECT and return both new columns; `SessionTableInfo` and `SessionInfo` grow two new fields.
5. **HTTP handlers** (`session_create.zig`, `session_update.zig`, `session_list.zig`) accept the new field in the request body (parseJSON) and include it in the response (addColumn to existing builders / update SELECT).
6. **SSE session broadcast** (`on_event_sent.zig::onEventSendSessions`) carries the two new fields so the frontend can react to live state changes without a refetch.

**Frontend (Vue)**:
- New checkbox in the **chat settings menu** (or the new-chat dialog) labeled "Keep retrying on errors (unattended mode)". Wire it to `PUT /api/session/:id` for existing sessions; include in `POST /api/session` for new ones.
- New badge in `ChatsList.vue` (matching the existing `🤖 profile` / `🌳 worktree` pill style) showing `🔁 unattended` when the flag is set.

**Out of scope (intentionally deferred)**:
- Distinguishing "transient" vs "permanent" errors (e.g., `InvalidApiKey` should still bail even in unattended mode). v1 keeps the simple "never bail if flag is on" rule. Adding a permanent-error exclusion list is a follow-up.
- Per-session retry-delay override (currently uses the global `config.retry_delay_ms`). v1 reuses the global config.
- Frontend LiveTail of `last_finish_reason` (we expose it via the API + SSE broadcast, but the chat-list badge only reflects `is_auto_retry_until_stop` in v1; showing the latest reason is a small follow-up).
- Stopping the worker when the LLM returns `finish_reason == .stop` AND there's no queued message AND `is_auto_retry_until_stop == 1`. **v1 keeps the existing break; unattended mode only affects how retries are handled, not how successful completions end the loop.** Documented in the README / plan FAQ section.

## Tech Stack

- Zig 0.16 + SQLite (existing `SqliteBackend`)
- Vue 3 + TypeScript (existing frontend pattern; checkbox + small badge)
- SSE event bus (existing `onEventSendSessions`)

## File Map

| Area | Files | Responsibility |
|---|---|---|
| Migration | `src/migrations/migration.zig` (new `Migration063AddSessionAutoRetry`) | Add columns; register in `allMigrations` |
| Migration test | `src/migrations/migration_063_test.zig` (new) | Idempotency, fresh-DB cascade, defaults |
| Model + SQL | `src/ai_workflow/tui/llm_history.zig` (extend `SessionTableInfo`, `SessionInfo`, `SessionInfoJson`, `SessionBroadcastInfo`, `getSession`, `getSessionListWithCursor`, `create_session`, new `updateSessionAutoRetryUntilStop`, new `updateSessionLastFinishReason`, `buildSessionListJson`) | Per-column CRUD + SELECT plumbing |
| Workflow gate | `src/ai_workflow/tui/workflow.zig` (read flag in `runAgenticMultiStepnew`; write `last_finish_reason` after each turn; replace the `retry_count > 10` bail with `is_auto_retry_until_stop ? continue : error.TooManyRetries`) | Per-session retry policy |
| SSE | `src/ai_workflow/tui/on_event_sent.zig` (`SseEventSessions`) | Broadcast new fields on session updates |
| HTTP request body | `src/ai_workflow/tui/http_handlers/session_create.zig` (`RequestSession` + `ResponseSession` + `insertWorker`) | Read + persist on create |
| HTTP request body | `src/ai_workflow/tui/http_handlers/session_update.zig` (`RequestSessionUpdate` + `ResponseSessionUpdate`) | Toggle + persist on update |
| HTTP list response | `src/ai_workflow/tui/http_handlers/session_list.zig` + `http_response.zig` (`makeSessionUpdateResponse`, `makeSessionCreateResponse`) | Return new fields to clients |
| Frontend `Chat` interface | `src/apps/desktop/src/api/index.ts` (`Chat` interface + `getChats` response mapping) | Add optional `is_auto_retry_until_stop` field |
| Frontend `ChatsList.vue` | `src/apps/desktop/src/components/ChatsList.vue` (`navItems` shape + `loadChats` mapping + badge template) | Show `🔁 unattended` badge |
| Frontend chat settings | `src/apps/desktop/src/components/ChatView.vue` (or wherever chat settings menu lives) | Toggle control bound to `PUT /api/session/:id` |
| Test registration | `src/migrations/test_runner.zig`, `src/ai_workflow/tui/test_runner.zig` | Register new test files |

---

## Chunk 1 — Migration 063 + DB model plumbing

> **Scope:** Get the schema in place + all the read/write SQL correct. Workflow integration + frontend land in Chunks 2/4. The migration test asserts the static contracts; behavior is exercised by Chunk 2's workflow test.

### Task 1.1: Add Migration063 + register it

**Files:**
- Modify: `src/migrations/migration.zig`
- Modify: `src/migrations/test_runner.zig`

Add `Migration063` between `Migration062AddTaskDescription` and the `allMigrations` slice in `migration.zig`. Register it in `allMigrations` immediately after `Migration062`.

Schema design choices:
- `is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0` — explicit boolean (0/1), NOT NULL so the column never carries NULL. Mirrors the convention `worker.last_activity` uses.
- `last_finish_reason TEXT` — nullable so the application code can distinguish "never had a successful turn yet" from "had a turn that returned 'stop'". Maps SQL NULL → `""` (via COALESCE) at the API edge, matching `cwd` / `selected_profile_model`.

Use `addColumnIfMissing` for `is_auto_retry_until_stop` (per the migration_062 precedent for default-bearing additions); use a plain `ALTER TABLE ... ADD COLUMN` for `last_finish_reason` (NULL allowed, fresh-DB cascade test won't be required because the canonical session schema doesn't list this column).

- [ ] **Step 1: Write the failing test file**

Create `src/migrations/migration_063_test.zig` with 4 tests:
1. `adds both columns to sessions` — apply migration on a fresh DB that has only `sessions(id, name, status)`; assert `pragma_table_info('sessions')` includes both new column names.
2. `is idempotent on re-run` — apply migration twice on a fresh DB; assert no "duplicate column" error and the column count is unchanged.
3. `is_auto_retry_until_stop defaults to 0 on existing rows` — insert a session, run migration, verify the existing row has `is_auto_retry_until_stop = '0'` (SQLite stores INTEGER as text in `pragma_table_info` for default values; `SELECT` returns `0`).
4. `last_finish_reason is NULL on existing rows` — insert a session, run migration, `SELECT last_finish_reason FROM sessions` should return NULL (treated as empty `[]u8` per the `SqliteBackend.query` convention).

Mirror the setupDb pattern from `migration_062_test.zig:32-59` (minimal `sessions` table). Reuse the `setupDb` helper to keep the migration test self-contained.

- [ ] **Step 2: Run tests to verify they fail**

Run: `timeout 180 zig build test --summary all 2>&1 | rg migration_063`
Expected: 4 tests appear but the first one fails (the migration struct doesn't exist yet, compile error: `Migration063AddSessionAutoRetry missing`).

- [ ] **Step 3: Add the migration struct in `migration.zig`**

Place it right before `Migration062AddTaskDescription` (so the file ends with the highest-version migration the same way it has for migrations 059-061), or immediately after — pick immediately after for chronological readability. Add:

```zig
pub const Migration063AddSessionAutoRetry = struct {
    pub const version: u32 = 63;
    pub const name = "add_session_auto_retry_until_stop";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // boolean opt-in flag, default off. addColumnIfMissing handles both
        // upgrade-from-v1 (no column yet) and fresh-DB-canonical-schema paths.
        try addColumnIfMissing(
            db,
            allocator,
            "sessions",
            "is_auto_retry_until_stop",
            "is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0",
        );
        // last_finish_reason stays NULL until the workflow writes the
        // first value. Plain ALTER — the canonical CREATE TABLE for
        // sessions doesn't declare this column, so no idempotency check
        // is needed.
        try addColumnIfMissing(
            db,
            allocator,
            "sessions",
            "last_finish_reason",
            "last_finish_reason TEXT",
        );
    }
};
```

NOTE: `addColumnIfMissing` is the established helper — see `migration.zig:2089-2100` for the canonical `Migration062AddTaskDescription` reference. Crucially, the `definition` arg must be the FULL `column_name TYPE` form (the project memory `nalar-add-column-if-missing-requires-column-prefix` documents this footgun — the helper appends `definition` verbatim after `ADD COLUMN`, so a bare type literal would create a column named "TEXT").

Register in `allMigrations` immediately after `Migration062AddTaskDescription` (line 1780 in the current file).

- [ ] **Step 4: Run migration tests to verify they pass**

Run: `timeout 180 zig build test --summary all 2>&1 | rg migration_063`
Expected: 4 tests pass. Confirm the test count goes up by 4 (no regressions in adjacent migrations).

- [ ] **Step 5: Register the test file**

Modify `src/migrations/test_runner.zig:27-29` (the migration_06* block) by adding one line:

```zig
_ = @import("migration_063_test.zig");  // sessions.is_auto_retry_until_stop + last_finish_reason (unattended long-running sessions)
```

- [ ] **Step 6: Run tests + install target to verify lazy analysis didn't hide bugs**

Run all three (per project memory `zig-build-catches-lazy-analysis-errors-test-misses`):
1. `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
2. `timeout 180 zig build install:linux:system 2>&1 | tail -n 5`
3. `rm -rf zig-out/bin && timeout 300 zig build 2>&1 | tail -n 10`

Expected: all three pass cleanly. The install target recompiles `nalarcore` so it also type-checks the migration registration.

- [ ] **Step 7: Commit**

```bash
git add src/migrations/migration.zig src/migrations/migration_063_test.zig src/migrations/test_runner.zig
git commit -m "feat(db): add Migration063 — sessions.is_auto_retry_until_stop + last_finish_reason"
```

---

### Task 1.2: Extend `SessionTableInfo` + `SessionInfo` + `SessionInfoJson` + `SessionBroadcastInfo`

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:14-93` (4 struct definitions + 4 `deinit`/`deinit`-style cleanup functions)

Add `is_auto_retry_until_stop: []u8` and `last_finish_reason: []u8` to all four structs in lockstep:
- `SessionTableInfo` (line 14) — used by `create_session`, `getSession`, `update_session_status`. `deinit` at line 2140.
- `SessionInfo` (line 19-22 area) — used by `getSessionListWithCursor` / `getSessionList`. `deinit` at line 24-33.
- `SessionInfoJson` (line 308-315) — used by `buildSessionListJson` to serialize list responses. (No `deinit` — it's a value-only type.)
- `SessionBroadcastInfo` (line 83-92) — used by `onEventSendSessions` SSE events. (No `deinit` — passed to the SSE layer.)

For struct consistency, follow the convention: `[]u8` (allocated, owned via `dupe`) for `SessionTableInfo` and `SessionInfo`; `[]const u8` for `SessionInfoJson` and `SessionBroadcastInfo` (those types are read-only slices passed to the SSE/JSON serializer).

- [ ] **Step 1: Find the existing compile errors**

Run: `timeout 180 zig build test --summary all 2>&1 | rg "SessionTableInfo|SessionInfo|SessionBroadcastInfo" | head -n 20`

Expected: nothing changes yet (we haven't added fields). Just confirm the existing 4 struct names appear in the error grep so we know our edit target is right.

- [ ] **Step 2: Add the two fields to each struct + `deinit`**

In `src/ai_workflow/tui/llm_history.zig`:

a. `SessionTableInfo` (after line 2138, before `deinit`):
```zig
/// Per-session opt-in flag: 1 keeps the workflow retrying past the
/// 10-attempt `TooManyRetries` bail; 0 preserves today's behavior.
/// Stored as text ["0" / "1"] to match `is_auto_retry_until_stop`'s
/// INTEGER column convention used by the rest of the codebase.
is_auto_retry_until_stop: []u8,
/// Most recent `finish_reason` the workflow observed for this session.
/// NULL/empty before the first successful turn.
last_finish_reason: []u8,
```

In its `deinit` (around line 2140), add:
```zig
allocator.free(self.is_auto_retry_until_stop);
allocator.free(self.last_finish_reason);
```

b. `SessionInfo` (right after the existing fields, around line 22):
```zig
selected_profile_model: []const u8,
is_auto_retry_until_stop: []const u8,
last_finish_reason: []const u8,
```

In its `deinit` (lines 24-33), add the matching frees for the two new fields.

c. `SessionInfoJson` (after the existing 7 fields, around line 315):
```zig
selected_profile_model: []const u8,
is_auto_retry_until_stop: []const u8 = "",
last_finish_reason: []const u8 = "",
```

d. `SessionBroadcastInfo` (after the existing 9 fields, around line 92):
```zig
selected_profile_model: []const u8,
is_auto_retry_until_stop: []const u8,
last_finish_reason: []const u8,
```

Both `SessionInfoJson` and `SessionBroadcastInfo` need `is_auto_retry_until_stop` and `last_finish_reason` added as the LAST two fields. The order matters because each field's JSON key position in the serialized output is determined by source order; by adding to the end of both, the existing JSON shape (e.g., the order ChatsList relies on) stays backward compatible.

- [ ] **Step 3: Run zig build test to enumerate all the empty-field-literal call sites**

Run: `timeout 180 zig build test --summary all 2>&1 | rg "missing field" | head -n 30`

Expected: a flood of compile errors at every `SessionTableInfo{ ... }` / `SessionInfo{ ... }` / `SessionInfoJson{ ... }` / `SessionBroadcastInfo{ ... }` literal in the codebase. **This is expected.** We fix each in the next steps.

- [ ] **Step 4: Update every callsite with the new fields**

The known callsites:

| File:line | Struct literal |
|---|---|
| `src/ai_workflow/tui/llm_history.zig:2175-2183` | `create_session` returns `SessionTableInfo{ ... }` — initialize to empty strings |
| `src/ai_workflow/tui/llm_history.zig:2198-2207` | `getSession` returns `SessionTableInfo{ ... }` — populate from `row.values[8]` and `[9]` (after we add those columns to the SELECT) |
| `src/ai_workflow/tui/llm_history.zig:264-272` | `getSessionListWithCursor` builds `SessionInfo` for each row — same SELECT expansion |
| `src/ai_workflow/tui/llm_history.zig:156-162` | `getSessionList` builds `SessionInfo` (legacy function) — same SELECT expansion |
| `src/ai_workflow/tui/llm_history.zig:300-350` | `buildSessionListJson` populates `SessionInfoJson` from each `SessionInfo` — pass through |
| `src/ai_workflow/tui/on_event_sent.zig` | every `onEventSendSessions(...)` callsite (search for it) builds `SseEventSessions` — that struct embeds `SessionBroadcastInfo`-like fields; extend them |
| `src/apps/desktop/src/api/index.ts:899-933` | TypeScript `getChats(...)` response mapping already accepts arbitrary `any`; just add the two fields to the `session` object after the existing copies |

For the **CREATE-row pass-through** in `create_session`, initialize both fields to `""` (empty string is the API convention for "no value yet"). For the SELECT paths, add the two columns to the SELECT lists. The canonical COALESCE pattern (matches `cwd`, `selected_profile_model`):

```zig
COALESCE(s.is_auto_retry_until_stop, '0'),
COALESCE(s.last_finish_reason, '')
```

For `onEventSendSessions`, use the same empty-string default at the producer side so the JSON payload always carries the fields (predictable shape for the frontend SSE parser).

- [ ] **Step 5: Run all three builds to verify**

Per the lazy-analysis trap from project memory `zig-build-catches-lazy-analysis-errors-test-misses`:

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin && timeout 300 zig build 2>&1 | tail -n 10
```

Expected: all three green.

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/on_event_sent.zig src/apps/desktop/src/api/index.ts
git commit -m "refactor(api): extend SessionTableInfo/SessionInfo/SessionInfoJson/SessionBroadcastInfo with auto_retry + finish_reason fields"
```

---

### Task 1.3: Persist on `create_session` + new `updateSessionAutoRetryUntilStop` / `updateSessionLastFinishReason` helpers

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:2153-2241` (`create_session` + a new pair of update helpers)

Add a third parameter to `create_session` for `is_auto_retry_until_stop`, defaulting to `""` (= "0" via SQL) for backward compatibility. Add two new `pub fn updateSession*` helpers.

- [ ] **Step 1: Write the static-contract test**

Create `src/ai_workflow/tui/migration_063_runtime_test.zig` (the runtime CRUD check for the new columns — separate file from the migration test to keep concerns split). Tests:
1. `create_session persists is_auto_retry_until_stop = '1'` — call `create_session(db, alloc, "s1", "test", "1")`, then `SELECT is_auto_retry_until_stop FROM sessions WHERE id='s1'` returns `'1'`.
2. `create_session defaults is_auto_retry_until_stop = ''` (= 0 in SQL) — pass `""` (the default), `SELECT` returns `'0'`.
3. `getSession reads back the new columns` — write `'1'` for the flag and `"stop"` for the reason, then `getSession` returns both with no COALESCE flakiness.
4. `updateSessionAutoRetryUntilStop toggles the flag` — write `'0'`, run the helper with `'1'`, re-SELECT returns `'1'`.
5. `updateSessionLastFinishReason persists the latest value` — write `""`, run the helper with `"tool_calls"`, re-SELECT returns `"tool_calls"`.
6. `updateSession* emit SSE broadcasts with the new fields populated` — Static source check that `updateSessionAutoRetryUntilStop` calls `onEventSendSessions` with `is_auto_retry_until_stop = <new_value>` and `last_finish_reason = <existing_value>` (read it from `getSession` before the broadcast).

Use the same `setupDb` pattern as `migration_062_test.zig` (minimal `sessions` table that already includes the new columns via `CREATE TABLE IF NOT EXISTS sessions (... is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0, last_finish_reason TEXT)` — exercises the fresh-DB-canonical-schema path required by `addColumnIfMissing`).

Register in `src/ai_workflow/tui/test_runner.zig` near the other migration_xxx tests, e.g., right after `migration_057_test.zig` (line 45):

```zig
_ = @import("migration_063_runtime_test.zig");  // Chunk 1 — sessions auto_retry + finish_reason runtime CRUD
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `timeout 180 zig build test --summary all 2>&1 | rg migration_063_runtime | head -n 10`

Expected: 6 compile errors (the new helper functions don't exist yet).

- [ ] **Step 3: Update `create_session` signature**

```zig
pub fn create_session(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: []const u8,
    is_auto_retry_until_stop: []const u8,  // NEW — "" or "0" = off; "1" = on
) !SessionTableInfo {
    const sql =
        "INSERT INTO sessions (id, name, status, created_at, updated_at, is_auto_retry_until_stop) " ++
        "VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?)";
    const flag = if (is_auto_retry_until_stop.len > 0) is_auto_retry_until_stop else "0";
    try db.exec(allocator, sql, &.{ id, name, flag });

    // Broadcast (unchanged shape, but include the new fields in the SSE payload).
    ai_mod.on_event_sent.onEventSendSessions(allocator, .{
        .action = "created",
        .id = id,
        .name = name,
        .status = "active",
        .cwd = "",
        .created_at = "",
        .updated_at = "",
        .selected_profile_model = "",
        .git_worktree_cwd = "",
        .is_auto_retry_until_stop = flag,
        .last_finish_reason = "",
    }) catch {};

    return SessionTableInfo{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .status = try allocator.dupe(u8, "active"),
        .cwd = try allocator.dupe(u8, ""),
        .created_at = try allocator.dupe(u8, ""),
        .updated_at = try allocator.dupe(u8, ""),
        .selected_profile_model = try allocator.dupe(u8, ""),
        .git_worktree_cwd = try allocator.dupe(u8, ""),
        .is_auto_retry_until_stop = try allocator.dupe(u8, flag),
        .last_finish_reason = try allocator.dupe(u8, ""),
    };
}
```

NOTE — empty-slice-to-NULL trap (project memory `sqlite-backend-empty-slice-binds-as-null`): passing `""` to `db.exec` for an `INTEGER NOT NULL` column is **OK** in this case because `SqliteBackend.exec` binds empty `[]const u8` as SQL NULL, and `0` IS the NULL→COALESCE default. We could also pass `"0"` directly. Going with `""`→`"0"` coercion is friendlier for handlers that omit the flag (default to "off").

- [ ] **Step 4: Update `getSession` SELECT**

Change the SQL to:
```zig
\\SELECT s.id, s.name, s.status, COALESCE(s.cwd, ''),
\\       COALESCE(s.created_at, ''), COALESCE(s.updated_at, ''),
\\       COALESCE(s.selected_profile_model, ''), COALESCE(s.git_worktree_cwd, ''),
\\       COALESCE(s.is_auto_retry_until_stop, '0'), COALESCE(s.last_finish_reason, '')
\\FROM sessions s WHERE s.id = ?
```

And populate the two new fields in the returned `SessionTableInfo` from `row.values[8]` (was 8 → now 8/9 because the SELECT grew by 2 — careful with the indexing!).

- [ ] **Step 5: Add the two new helpers**

Place them right after `update_session_status` (around line 2241):

```zig
/// Update the unattended-mode flag for an existing session.
/// Pass "1" to enable, "0" to disable. No-op validation — the
/// handler layer is responsible for input shape (boolean string).
pub fn updateSessionAutoRetryUntilStop(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    value: []const u8,
) !void {
    const sql = "UPDATE sessions SET is_auto_retry_until_stop = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ value, id });

    // Broadcast so the SSE-driven ChatsList badge updates without a refetch.
    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        ai_mod.on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
            .is_auto_retry_until_stop = s.is_auto_retry_until_stop,
            .last_finish_reason = s.last_finish_reason,
        }) catch {};
    }
}

/// Update the most-recent `finish_reason` cache for an existing session.
/// Called by `workflow.zig` after each `callDynamicAgentNew` returns so
/// the next workflow invocation (e.g., after a server restart) can
/// pick up where the last call left off without re-querying
/// `llm_history.finish_reason`.
pub fn updateSessionLastFinishReason(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    finish_reason: []const u8,
) !void {
    const sql = "UPDATE sessions SET last_finish_reason = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ finish_reason, id });
    // No SSE broadcast — last_finish_reason is internal cache, not UI state.
}
```

- [ ] **Step 6: Run all the tests + builds**

```bash
timeout 180 zig build test --summary all 2>&1 | rg migration_063_runtime | head -n 10
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin && timeout 300 zig build 2>&1 | tail -n 10
```

Expected: 6 tests pass; the 2 build targets clean.

- [ ] **Step 7: Commit**

```bash
git add src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/migration_063_runtime_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(db): persist sessions.is_auto_retry_until_stop + update last_finish_reason"
```

---

### Task 1.4: SELECT plumbing — `getSession` / `getSessionList*` / `buildSessionListJson` include the new columns

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:96-181` (`getSessionList`)
- Modify: `src/ai_workflow/tui/llm_history.zig:186-297` (`getSessionListWithCursor`)
- Modify: `src/ai_workflow/tui/llm_history.zig:319-350` (`buildSessionListJson`)

The SELECTs need to read the new columns and the `SessionInfo` constructor at each row needs the two new fields populated.

- [ ] **Step 1: Extend the legacy `getSessionList` SELECT**

Currently the SELECT projects 5 columns (`session_id, created_at, cwd, agent, session_name`). Add the two new ones at the end (the index shifts map to `row.values[5]` and `row.values[6]`):

```zig
const sql =
    \\SELECT sub.session_id,
    \\       sub.created_at,
    \\       COALESCE(s.cwd, '') AS cwd,
    \\       COALESCE(s.name, '') AS session_name,
    \\       COALESCE(
    \\         (SELECT h2.agent
    \\            FROM llm_history h2
    \\           WHERE h2.session_id = sub.session_id
    \\           ORDER BY h2.created_at DESC
    \\           LIMIT 1),
    \\         'Agent'
    \\       ) AS agent,
    \\       COALESCE(s.is_auto_retry_until_stop, '0') AS is_auto_retry_until_stop,
    \\       COALESCE(s.last_finish_reason, '') AS last_finish_reason
    \\FROM ...
;
```

Update the `SessionInfo` constructor in the loop to read `row.values[5]` and `row.values[6]`. Confirm by checking the `agent` mapping already uses `row.values[3]` so we know the indexing is `.values[5]` and `.values[6]` after the additions.

- [ ] **Step 2: Extend `getSessionListWithCursor` SELECT the same way**

Current SQL (lines 241-250) projects 8 columns. Add `COALESCE(s.is_auto_retry_until_stop, '0')` and `COALESCE(s.last_finish_reason, '')` as the 9th and 10th columns. Update the `SessionInfo` constructor (lines 263-272) to read those two new indices.

- [ ] **Step 3: Update `buildSessionListJson` to pass through the new fields**

In the loop at lines 330-340:
```zig
try json_sessions.append(allocator, .{
    .session_id = sess.session_id,
    .cwd = sess.cwd,
    .created_at = sess.created_at,
    .updated_at = sess.updated_at,
    .agent = sess.agent,
    .session_name = sess.session_name,
    .selected_profile_model = sess.selected_profile_model,
    .is_auto_retry_until_stop = sess.is_auto_retry_until_stop,
    .last_finish_reason = sess.last_finish_reason,
});
```

- [ ] **Step 4: Verify SSE broadcast struct (`SseEventSessions`) has the fields too**

Search `src/ai_workflow/tui/on_event_sent.zig` for `SseEventSessions`. If its struct has explicit fields (not embedded `SessionBroadcastInfo`), add `is_auto_retry_until_stop: []const u8 = ""` and `last_finish_reason: []const u8 = ""` at the end. Update the per-event constructor calls to include them (the updateSession* helpers in Task 1.3 already pass them; verify the `onEventSendSessions` constructor reads them from the input struct).

- [ ] **Step 5: Run tests + builds (all three)**

```bash
timeout 180 zig build test --summary all 2>&1 | rg "getSession|buildSessionListJson|migration_063" | head -n 20
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin && timeout 300 zig build 2>&1 | tail -n 10
```

Expected: green. Test count at least `baseline + 6 + 4 = baseline + 10` new tests.

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/on_event_sent.zig
git commit -m "feat(api): return is_auto_retry_until_stop + last_finish_reason on GET /api/sessions"
```

---

## Chunk 2 — Workflow retry-budget gate (the actual feature)

> **Scope:** Make `runAgenticMultiStepnew` honor `is_auto_retry_until_stop`. After every successful LLM call, write `last_finish_reason` to the session so a future restart picks up where the last call left off. The retry budget (`retry_count > 10`) currently bails with `TooManyRetries`; when the flag is on, we `continue` past it instead of returning the error. The Tailwind Tailwind React Vue Tailwind Vue2 Vue3 ReactJS semantic is that the bail is a HARD STOP for human-driven chats and a SOFT HINT for unattended chats — the runtime just keeps retrying, respecting `config.retry_delay_ms`, with no upper bound.

### Task 2.1: Read the flag at workflow entry + change the bail

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig:118-465` (`runAgenticMultiStepnew` body)

The work has 4 distinct edit sites in one function:
1. **After the existing top-level setup** (around line 470, just before the `while` loop), read the flag with a single `SELECT is_auto_retry_until_stop FROM sessions WHERE id = ?` — pass `null` if the session row is missing (worker may be created before session row in sub-agent edge cases).
2. **Replace the `if (retry_count > 10) { ... return error.TooManyRetries; }` block** (lines 425-465) with a `if (retry_count > 10) { if (is_auto_retry_until_stop) { /* soft-bail: log + continue */ } else { return error.TooManyRetries; } }` branch.
3. **After `callDynamicAgentNew` returns** (line 540-541 area), write `last_finish_reason = @as([]const u8, fr.to_str())` via `updateSessionLastFinishReason(allocator, db, copy_session_id, finish_reason)`.
4. **At every `break` site** (line 594 in the `.stop` branch + the 610 area), do the same write — so the cache stays fresh even on successful completion.

- [ ] **Step 1: Write the static-contract tests**

Add to `src/ai_workflow/tui/workflow_retry_delay_test.zig` (it already exists for retry-budget-related static checks). Three new tests:

1. `workflow.zig reads is_auto_retry_until_stop at runAgenticMultiStepnew entry` — grep for `is_auto_retry_until_stop` in the function body (between the `pub fn runAgenticMultiStepnew(` line and the next `pub fn` at column 0).
2. `workflow.zig retries past retry_count > 10 when is_auto_retry_until_stop = 1` — grep for the pattern `retry_count > 10` AND follow it by an `if (is_auto_retry_until_stop)` branch that does NOT `return error.TooManyRetries`. Verify the existing `return error.TooManyRetries` is now INSIDE an `else` clause.
3. `workflow.zig writes last_finish_reason to sessions after each LLM call` — grep for the `updateSessionLastFinishReason` call site in the function body.

Per `src/ai_workflow/tui/workflow_retry_delay_test.zig:18-39` precedent (existing `retryDelayMs` static check pattern), mirror that exact shape.

- [ ] **Step 2: Run tests to verify they fail**

Run: `timeout 180 zig build test --summary all 2>&1 | rg "workflow_retry_delay" | head -n 10`

Expected: 3 new tests compile and run but assert with the custom errors (`AutoRetryFlagReadMissing`, `AutoRetrySoftBailMissing`, `LastFinishReasonWriteMissing`).

- [ ] **Step 3: Read the flag at workflow entry**

Immediately after the existing `copy_session_id = ... .session_id` setup (around line 200, where the per-session constants are read), add:

```zig
// Read the unattended-mode flag for this session. Controls whether
// the workflow bails after 10 consecutive retries or keeps going.
const is_auto_retry_until_stop: bool = blk: {
    var q = db.query(allocator,
        "SELECT COALESCE(is_auto_retry_until_stop, '0') FROM sessions WHERE id = ?",
        &.{copy_session_id}) catch break :blk false;
    defer q.deinit();
    const row = (try q.next()) orelse break :blk false;
    defer row.deinit(allocator);
    const v = row.values[0];
    break :blk std.mem.eql(u8, v, "1");
};
```

Place this ABOVE the `while (...)` retry loop so the flag is read once per workflow invocation (not per iteration). The `blk:` + `break :blk` form matches the `zig-orelse-type-unification-mismatch` memory's preferred idiom for "compute a default value with multiple fall-through branches".

- [ ] **Step 4: Soft-bail the retry budget**

Replace the existing block at lines 425-465 with:

```zig
if (retry_count > 10) {
    const reason_error = @errorName(last_retry_error);
    const reason_source = last_retry_source;

    if (is_auto_retry_until_stop) {
        // Unattended mode: soft-bail. Don't return — keep the session
        // running overnight even through network blips and rate limits.
        // The cost: each `retry_count > 10` snapshot logs to chat
        // history (visible to the user on return) AND emits a logger.err
        // line (visible in `nalar` logs). Reset `retry_count` to 0 so
        // the next burst of 10+ retries gets its own snapshot.
        logger.warnFmt(
            "UNATTENDED SOFT-BAIL: retry_count={} exceeded 10 (last error={s} source={s}) — continuing per is_auto_retry_until_stop=1",
            .{ retry_count, reason_error, reason_source },
        );
        try saveRetryAttemptMessage(
            allocator, db, event_bus, logger, io, copy_cwd, copy_session_id,
            copy_parent_session_id, effective_model, effective_agent_name,
            agent_temperature, isThinking, loop_counter, retry_count,
            @as(u32, 10), "auto-retry-until-stop soft-bail",
            reason_error, config.retry_delay_ms,
        );
        if (!retryDelayMs(allocator, config.retry_delay_ms, db, copy_session_id, io, logger)) {
            logger.infoFmt("WORKFLOW CANCELLED during unattended soft-bail: session_id={s}", .{copy_session_id});
            break;
        }
        retry_count = 0;
        continue;
    }

    // Existing hard-bail behavior — unchanged.
    const diagnostic = std.fmt.allocPrint(parent_allocator,
        \\[Agent Nalar System error] workflow halted after {} consecutive retries.
        \\Reason for last retry: {s} (source: {s}).
    , .{ retry_count, reason_error, reason_source }) catch "workflow halted after too many retries";

    logger.errFmt("TooManyRetries exhausted: {} consecutive failures for session_id={s} — last_error={s} source={s}", .{ retry_count, copy_session_id, reason_error, reason_source });

    try agentic_loop_mod.insertLLMHistories(.{
        // ... existing 22 fields copied verbatim ...
        .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
    });

    return error.TooManyRetries;
}
```

The hard-bail block is preserved EXACTLY so unattended-mode OFF sessions behave identically to today (no behavior change for existing users).

- [ ] **Step 5: Write `last_finish_reason` after every successful return**

Add a single write site right after `retry_count = 0;` at line 540 (the post-success branch where we already verified a real `finish_reason` was returned):

```zig
if (res_dynamic_agent.finish_reason) |fr| {
    const fr_str = fr.to_str();
    try llm_history.updateSessionLastFinishReason(allocator, db, copy_session_id, fr_str);
    // ... existing if/else chain ...
}
```

This guarantees `last_finish_reason` is fresh after every assistant turn.

- [ ] **Step 6: Run the new tests to verify they pass**

Run: `timeout 180 zig build test --summary all 2>&1 | rg "workflow_retry_delay" | head -n 10`

Expected: 3 tests pass.

- [ ] **Step 7: Run all 3 builds for the lazy-analysis trap**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin && timeout 300 zig build 2>&1 | tail -n 10
```

Expected: green. The workflow is the heart of `nalarcore`, so `install:linux:system` is the critical check — any `ret_diag` codegen issue from the new `blk:` would surface here.

- [ ] **Step 8: Commit**

```bash
git add src/ai_workflow/tui/workflow.zig src/ai_workflow/tui/workflow_retry_delay_test.zig
git commit -m "feat(workflow): honor sessions.is_auto_retry_until_stop — soft-bail past retry_count > 10"
```

---

### Task 2.2: Behavioral regression for the unattended soft-bail path

**Files:**
- Create: `src/ai_workflow/tui/workflow_auto_retry_test.zig`

The static contracts in Task 2.1 only prove the SOURCE has the right structure. A live end-to-end test is needed to prove that the SQLite → workflow loop actually behaves the way we want.

- [ ] **Step 1: Decide whether the behavioral test is feasible**

`runAgenticMultiStepnew` takes `RunParamsNew` + a live singleton (`nalarcore.ContextIPCTui`). Standing up that full fixture just to drive one workflow turn is overkill (see `workflow_retry_delay_test.zig:5-9` rationale for choosing static over behavioral). Stick with the static-contract pattern from Task 2.1. **Skip this task as out of scope** — the install target's compile is the strongest behavioral check we can practically run. Document in NALAR.md the limitation: "unattended soft-bail is verified via static contract + manual overnight test."

- [ ] **Step 2: Commit the documentation update (NOT a code change)**

```bash
git commit --allow-empty -m "docs: document unattended soft-bail verification limitation (static-contract only)"
```

Or, if there is no NALAR.md auto-update mechanism, add a TODO comment near the new `updateSessionLastFinishReason` helper noting "behavioral coverage is via install-target compile + manual overnight test; regression-suite behavioral coverage is a follow-up."

---

## Chunk 3 — HTTP handlers + API contract

> **Scope:** Make the new fields reachable from the frontend: `POST /api/session` accepts `is_auto_retry_until_stop` in the body; `PUT /api/session/:id` accepts it for toggling; `GET /api/sessions` returns it in the list response. The `PUT /api/llm/session/:id` alias is already handled by the same handler (`src/ai_workflow/tui/mod.zig` routes both to `sessionUpdateHandler`).

### Task 3.1: `POST /api/session` — accept and persist the flag

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/session_create.zig:38-95` (`RequestSession` + `ResponseSession` + `useCase` + `insertWorker`)

Add `is_auto_retry_until_stop: []const u8 = ""` to `RequestSession`. Thread it through to the `insertWorker` SQL + `di.group_emit_session_create.concurrent` (no new `RunParamsNew` field — the workflow re-reads the column directly in Task 2.1).

- [ ] **Step 1: Write the static-contract test**

Add a 7th test to `src/ai_workflow/tui/http_handlers/session_create_test.zig` (the file already exercises the standard create flow):

```zig
test "session_create: is_auto_retry_until_stop = '1' is persisted to sessions row" {
    // Mock `nalarcore.getSingleton()` (or use the test-only path).
    // Send `POST /api/session` with body `{is_auto_retry_until_stop: "1"}`.
    // Assert: response is 201; SELECT from sessions row returns `1`.
}
```

If the test infrastructure for session_create_test.zig is missing the singleton shim, defer the behavioral test and instead write a static contract in the same file:

```zig
test "session_create_request_includes_is_auto_retry_until_stop_field" {
    const source = try std.Io.Dir.cwd().readFileAlloc(...,SESSION_CREATE_PATH,...);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "is_auto_retry_until_stop: []const u8 = \"\"") == null) {
        std.debug.print("!! session_create.zig does not declare the new RequestSession field !!\n", .{});
        return error.SessionCreateRequestFieldMissing;
    }
}
```

Same for `insertWorker` (it must write the column in the INSERT).

- [ ] **Step 2: Run tests to verify they fail**

Run: `timeout 180 zig build test --summary all 2>&1 | rg "session_create" | head -n 10`

Expected: static tests fail with the missing-field error (or compile errors if behavioral).

- [ ] **Step 3: Update `session_create.zig`**

a. Add the field to the request body (around line 46):
```zig
/// "1" to enable unattended mode (long-running sessions keep retrying past
/// the 10-attempt TooManyRetries bail); "" or "0" to use today's behavior.
is_auto_retry_until_stop: []const u8 = "",
```

b. In `useCase`, propagate the field alongside the other `var ... = ""` declarations:
```zig
var is_auto_retry_until_stop: []const u8 = "";
if (parsed.is_auto_retry_until_stop.len > 0) is_auto_retry_until_stop = parsed.is_auto_retry_until_stop;
```

c. In `insertWorker`, update the SQL + bind args. The INSERT must include the column:
```zig
const session_sql =
    "INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model, is_auto_retry_until_stop) " ++
    "VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?)";
// ...
const copy_auto_retry = if (parsed.is_auto_retry_until_stop.len > 0) try allocator.dupe(u8, parsed.is_auto_retry_until_stop) else "";
defer if (copy_auto_retry.len > 0) allocator.free(copy_auto_retry);
try sqlite_db.exec(allocator, session_sql, &.{ session_id, copy_session_name, copy_cwd, copy_profile, copy_auto_retry });
```

d. Update the SSE broadcast call (insertWorker) to include `is_auto_retry_until_stop = copy_auto_retry` and `last_finish_reason = ""`.

e. Thread the field through `concurrent(...)` similarly to the other args. Add a new `thread_is_auto_retry_until_stop = try di.allocator.dupe(...)` + an `errdefer` cleanup line + a matching `defer` in the `.run` closure.

- [ ] **Step 4: Run all 3 builds**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin && timeout 300 zig build 2>&1 | tail -n 10
```

Expected: green. The new `concurrent` arg list adds 2 new pointer slots — the `install` compile step catches any errdefer asymmetry.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/session_create.zig src/ai_workflow/tui/http_handlers/session_create_test.zig
git commit -m "feat(api): POST /api/session accepts is_auto_retry_until_stop"
```

---

### Task 3.2: `PUT /api/session/:id` — toggle the flag

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/session_update.zig`

Add `is_auto_retry_until_stop: []const u8 = ""` to `RequestSessionUpdate`. Call `updateSessionAutoRetryUntilStop` if non-empty. Update `ResponseSessionUpdate` to include the new field.

- [ ] **Step 1: Write the static-contract tests**

Add tests to `src/ai_workflow/tui/http_handlers/session_create_test.zig` (or a dedicated `session_update_test.zig` if one exists; check the file list). The existing `session_update_test.zig` does NOT exist as a separate file — place the new test in `session_create_test.zig` (the file already exercises both create + update flows; verify by `rg session_update session_create_test.zig`):

```zig
test "session_update_request_includes_is_auto_retry_until_stop" { ... }
test "session_update_calls_updateSessionAutoRetryUntilStop_when_field_present" { ... }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `timeout 180 zig build test --summary all 2>&1 | rg "session_update" | head -n 10`

- [ ] **Step 3: Update `session_update.zig`**

```zig
pub const RequestSessionUpdate = struct {
    /// ... existing 2 fields ...
    /// "1" / "0" — toggles unattended mode for the session.
    /// Empty string OR missing key = unchanged.
    is_auto_retry_until_stop: []const u8 = "",
};

pub const ResponseSessionUpdate = struct {
    /// ... existing 4 fields ...
    is_auto_retry_until_stop: []const u8,
    last_finish_reason: []const u8,
};
```

In the handler, between the existing `updateSessionSelectedProfileModel` + `updateSessionName` calls, add:

```zig
if (parsed.is_auto_retry_until_stop.len > 0) {
    try llm_history.updateSessionAutoRetryUntilStop(allocator, sqlite_db, session_id, parsed.is_auto_retry_until_stop);
}
```

Update the `makeSessionUpdateResponse` call to pass the two new fields.

- [ ] **Step 4: Run all 3 builds**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin && timeout 300 zig build 2>&1 | tail -n 10
```

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/session_update.zig src/ai_workflow/tui/http_handlers/session_create_test.zig
git commit -m "feat(api): PUT /api/session/:id toggles is_auto_retry_until_stop"
```

---

### Task 3.3: `GET /api/sessions` — return the new fields

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig` (`makeSessionCreateResponse` + `makeSessionUpdateResponse`)
- Verify: `src/ai_workflow/tui/llm_history.zig:319-350` (`buildSessionListJson` — already updated in Task 1.4)

The list endpoint already returns `is_auto_retry_until_stop` and `last_finish_reason` via Task 1.4's `buildSessionListJson` pass-through. But `makeSessionCreateResponse` (Task 3.1) and `makeSessionUpdateResponse` (Task 3.2) need the response struct extended to include the two new fields.

- [ ] **Step 1: Extend the response structs in `http_response.zig`**

Find `SessionCreateResponse` and `SessionUpdateResponse` (lines 219-230). Add `is_auto_retry_until_stop: []const u8` and `last_finish_reason: []const u8` to both.

- [ ] **Step 2: Pass the new fields through**

In `session_create.zig::useCase`, update the `makeSessionCreateResponse(allocator, .{ .id, .name, .status = "send", ... })` call to include `.is_auto_retry_until_stop = flag, .last_finish_reason = ""` (the response status is `"send"` regardless — these two are persisted fields, not response fields).

In `session_update.zig`, update the `makeSessionUpdateResponse` call to pass `session.is_auto_retry_until_stop` and `session.last_finish_reason`.

- [ ] **Step 3: Write the static-contract tests**

Add to `session_create_test.zig`:

```zig
test "session_create_response includes the new fields" {
    const source = try std.Io.Dir.cwd().readFileAlloc(...,SESSION_CREATE_PATH,...);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, ".is_auto_retry_until_stop = ") == null) {
        return error.SessionCreateResponseFieldMissing;
    }
}
```

- [ ] **Step 4: Run all 3 builds**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin && timeout 300 zig build 2>&1 | tail -n 10
```

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/http_response.zig src/ai_workflow/tui/http_handlers/session_create.zig src/ai_workflow/tui/http_handlers/session_update.zig src/ai_workflow/tui/http_handlers/session_create_test.zig
git commit -m "feat(api): response shapes for /api/session include auto_retry + last_finish_reason"
```

---

## Chunk 4 — Frontend: badge in ChatsList, toggle in chat settings

> **Scope:** Surface the new fields in the UI. Two cosmetic changes only (no behavior change). Tests live in `bun run build` (vue-tsc type-check) + `bunx vitest` (component tests).

### Task 4.1: `Chat` interface + `getChats` response mapping + chat-list badge

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:661-666` (`Chat` interface)
- Modify: `src/apps/desktop/src/api/index.ts:907-933` (`getChats` response mapping)
- Modify: `src/apps/desktop/src/components/ChatsList.vue:33` (navItems shape)
- Modify: `src/apps/desktop/src/components/ChatsList.vue:136-144` (navItems mapping in loadChats)
- Modify: `src/apps/desktop/src/components/ChatsList.vue:441-453` (badge template — add the new pill after the existing `🌳 worktree` one)

- [ ] **Step 1: Extend the `Chat` interface**

```ts
export interface Chat {
  session_id: string
  session_name?: string
  status?: string
  selected_profile_model?: string
  is_auto_retry_until_stop?: string  // "0" or "1"
  last_finish_reason?: string
}
```

- [ ] **Step 2: Extend the `getChats` response mapping (lines 926-933)**

```ts
return {
  session_id: sessionId,
  session_name: session.session_name || session.name || 'New Session',
  status: session.status || 'active',
  created_at: session.created_at || null,
  updated_at: session.updated_at || null,
  cwd: session.cwd || '',
  is_auto_retry_until_stop: session.is_auto_retry_until_stop || '0',
  last_finish_reason: session.last_finish_reason || '',
}
```

The fallback to `'0'` matches the SQL COALESCE default and ensures the type stays `string` (not `null`), so `ChatsList.vue` doesn't need a `null` guard.

- [ ] **Step 3: Update the `navItems` shape (line 33)**

```ts
const navItems = ref<{
  id: string; name: string; active?: boolean; processing?: boolean;
  relativeTime?: string; selected_profile_model?: string; git_worktree_cwd?: string;
  is_auto_retry_until_stop?: string; last_finish_reason?: string;
}[]>([])
```

- [ ] **Step 4: Update the `loadChats` mapping (lines 136-144)**

```ts
navItems.value = sessions.map((session: any) => ({
  id: session.session_id,
  name: session.session_name || 'New Chat',
  active: savedSessionId === session.session_id,
  processing: !!processingState.value[session.session_id],
  relativeTime: formatRelativeTime(session.updated_at),
  selected_profile_model: session.selected_profile_model || '',
  git_worktree_cwd: session.git_worktree_cwd || '',
  is_auto_retry_until_stop: session.is_auto_retry_until_stop || '0',
  last_finish_reason: session.last_finish_reason || '',
}))
```

- [ ] **Step 5: Add the badge to the template (after the existing `🌳 worktree` pill at line 452)**

```vue
<span
  v-if="item.is_auto_retry_until_stop === '1'"
  class="ml-1 text-[10px] font-mono"
  style="color: var(--color-amber);"
  title="This session keeps retrying on transient errors without human intervention"
  data-testid="auto-retry-badge"
>🔁 unattended</span>
```

The pill order: existing profile badge (🤖) → worktree badge (🌳) → auto-retry badge (🔁). Visual style mirrors the existing pills (small, mono, color-coded).

- [ ] **Step 6: Run the TypeScript type-check + frontend tests**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20     # vue-tsc type-check + bundle
timeout 120 bunx vitest run 2>&1 | tail -n 20   # unit tests
```

Per project memory `desktop-typescript-bun-build-as-typecheck`, `bun run build` is the authoritative type check; `bunx vitest run` alone is not sufficient.

Expected: both green. The new fields are optional on `Chat` so they don't break the 8+ existing test files that construct `Chat` literals without these fields (per project memory `nalar-frontend-task-literal-typing-rule`).

- [ ] **Step 7: Commit**

```bash
git add src/apps/desktop/src/api/index.ts src/apps/desktop/src/components/ChatsList.vue
git commit -m "feat(ui): ChatsList shows 🔁 unattended badge + Chat interface extended"
```

---

### Task 4.2: Toggle control in the chat settings / new-chat dialog

**Files:**
- TBD: which file owns the "chat settings" menu in the current UI — likely `src/apps/desktop/src/components/ChatView.vue` (per the project memory `nalar-vue-async-onmount-vs-click-race` that already touches ChatView).

The toggle should appear in whichever dialog already lets the user set `selected_profile_model` (the existing per-session setting panel). Discover that location by grepping for `selected_profile_model` in `*.vue` files — wherever the existing 🤖 toggle lives, that's where the new toggle goes.

- [ ] **Step 1: Discover the location of the existing per-session settings UI**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
rg -nl 'selected_profile_model' src/apps/desktop/src/components/ | head -n 10
```

Expected output likely includes `ChatView.vue`, `RenameTaskModal.vue`, or similar. Pick the file(s) where the user can both CREATE a new chat AND edit an existing chat's settings.

- [ ] **Step 2: Write the type-check / mount-test before changes**

Add a Vue component test (in `src/apps/desktop/src/__tests__/`) that mounts the dialog with `is_auto_retry_until_stop = '1'` set and asserts the toggle is in the "checked" state. Mirror the existing dialog-test pattern in `src/apps/desktop/src/__tests__/` for whichever dialog you found.

If the dialog already has a unit test, add a single test to that file. Otherwise create `src/apps/desktop/src/__tests__/<dialog-name>.spec.ts` (convention check: confirm via `ls src/apps/desktop/src/__tests__/`).

- [ ] **Step 3: Add the toggle to the dialog template**

Mirror the existing `selected_profile_model` toggle's shape (probably an `<input type="checkbox" v-model="...">` or `<Switch>` component — match the existing style):

```vue
<div class="...">
  <label>
    <input
      type="checkbox"
      :checked="form.is_auto_retry_until_stop === '1'"
      @change="form.is_auto_retry_until_stop = ($event.target as HTMLInputElement).checked ? '1' : '0'"
      data-testid="auto-retry-toggle"
    />
    Keep retrying on errors (unattended mode)
    <span class="text-xs opacity-70 ml-1">— session will keep retrying transient LLM errors overnight</span>
  </label>
</div>
```

Add `is_auto_retry_until_stop: '0'` to the form's initial state and to the API call payload.

- [ ] **Step 4: Wire the dialog's save handler**

The existing handler probably does:
- For create: `api.createSession({ ...form })` → add `is_auto_retry_until_stop: form.is_auto_retry_until_stop`
- For update: `api.updateSession(id, { ...form })` → add `is_auto_retry_until_stop: form.is_auto_retry_until_stop`

Add the corresponding TypeScript signatures in `src/apps/desktop/src/api/index.ts` (`createSession`, `updateSession`) — both already accept an `any` payload today, but for type safety (and to match the convention used by the per-session setting equivalents), declare the field as optional in the request interface.

- [ ] **Step 5: Run `bun run build` + vitest**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
timeout 120 bunx vitest run 2>&1 | tail -n 20
```

Expected: green. The new test from Step 2 passes (toggle is in the expected state when mounted with `is_auto_retry_until_stop = '1'`).

- [ ] **Step 6: Commit**

```bash
git add <dialog>.vue src/apps/desktop/src/__tests__/<dialog-test>.spec.ts src/apps/desktop/src/api/index.ts
git commit -m "feat(ui): chat settings dialog — 'unattended mode' toggle"
```

---

## Open Questions / Follow-Ups (Documented)

1. **Permanent errors should still bail in unattended mode.** v1 bails only on `TooManyRetries`. Permanent errors (e.g., `InvalidApiKey`, `ModelNotFound`) currently also route through the `retry_count > 10` bail (they keep retrying for 10 bursts, then bail). Adding a per-error allowlist (e.g., "if error is in {InvalidApiKey, BadRequest, ...}, return immediately") would make unattended mode smarter. **Follow-up.**

2. **Per-session retry-delay override.** v1 reuses `config.retry_delay_ms` (global). A per-session `retry_delay_ms` column would let users say "this overnight session: 5s between retries, 10s backoff multiplier, max 1 hour total elapsed". **Follow-up.**

3. **Stop trigger for successful completion in unattended mode.** v1 keeps the existing break on `finish_reason == .stop` (the LLM signaling "I'm done"). Some users may want a different stop policy for unattended sessions (e.g., "keep queueing more sub-tasks even after `stop` as long as the budget allows"). **Follow-up — explicitly out of scope for this plan; the user's brief was "continue without human in the loop" only in the failure case.**

4. **`last_finish_reason` UI surfacing.** v1 returns it in the API + SSE but does not show it in any UI. A small chip in the chat-list pill ("🔁 unattended · last: stop") would make overnight debugging easier. **Follow-up.**

5. **Behavioral test for the unattended soft-bail.** Task 2.2 decided this was out of scope (the workflow runtime requires a live singleton). If the team wants stronger evidence than static contracts, consider standing up a minimal `runAgenticMultiStepnew` test harness (likely 2-3 days of effort). **Follow-up.**

6. **Per-iteration worker status visibility.** When an unattended session is in `retry_count > 10` loops, the user should see "session is retrying, last error: ECONNRESET" without waiting for the soft-bail cycle to complete. The current logger.err output is in the nalar logs but not surfaced. Could add an SSE event with the last error per iteration. **Follow-up.**

---

## Execution Order

1. **Chunk 1** (schema + model) — Tasks 1.1 → 1.2 → 1.3 → 1.4. 4 commits, ~15 new tests.
2. **Chunk 2** (workflow gate) — Tasks 2.1 → 2.2. 2 commits, 3 new tests.
3. **Chunk 3** (HTTP + API contract) — Tasks 3.1 → 3.2 → 3.3. 3 commits, ~3 new tests.
4. **Chunk 4** (frontend) — Tasks 4.1 → 4.2. 2 commits, ~2 new tests.

Total: 11 commits, ~23 new tests, 8 modified or new files. No behavior change for sessions with `is_auto_retry_until_stop = 0` (the default).

## Verification

Final check before reporting completion:

1. `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — all tests pass (`baseline + ~23`).
2. `timeout 180 zig build install:linux:system 2>&1 | tail -n 5` — install target clean (the workflow changes are visible only here, not in the test target's lazy module graph).
3. `rm -rf zig-out/bin && timeout 300 zig build 2>&1 | tail -n 10` — full build clean.
4. `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` — TypeScript type-check passes.
5. `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20` — Vue unit tests pass.
6. **Manual smoke test** (against `./zig-out/bin/nalar --port 8080` per the project MANDATORY rule about port 8081):
   ```bash
   curl -X POST http://127.0.0.1:8080/api/session -d '{"is_auto_retry_until_stop":"1"}' -H "Content-Type: application/json"
   # → 201 Created, response includes "is_auto_retry_until_stop":"1"
   curl http://127.0.0.1:8080/api/sessions | jq '.sessions[0]'
   # → shows the session with "is_auto_retry_until_stop":"1"
   curl -X PUT http://127.0.0.1:8080/api/session/<id> -d '{"is_auto_retry_until_stop":"0"}' -H "Content-Type: application/json"
   # → 200 OK, response shows "is_auto_retry_until_stop":"0"
   # (confirms the toggling path works)
   ```
7. **End-to-end:** create a session with `is_auto_retry_until_stop="1"`, send a message, watch the workflow run; confirm that a transient upstream error (e.g., flip a switch in your test backend) does NOT cause the session to bail after 10 retries; the session keeps running and the toggle survives a `kill <pid>`/`./zig-out/bin/nalar --port 8080` restart.

Items 1-5 are mechanical. Item 6 is a CRUD-correctness check. Item 7 is the "did the actual feature work?" check — expect this to take 30-60 minutes of monitoring time depending on how you simulate the upstream failure.

If any of items 1-5 fail, do NOT proceed to 6-7 — fix the regression first (this is the project's `verification-before-completion` rule and the `zig-build-catches-lazy-analysis-errors-test-misses` pattern).
