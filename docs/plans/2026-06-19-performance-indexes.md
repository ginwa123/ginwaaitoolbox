# Plan: Performance indexes for chat-list and routine scheduler

> **Goal:** Add a single new SQLite index (and a defensive follow-up) that
> eliminates the full-table scan on the most-frequent user action (opening
> the chat list) and backfills two narrow insurance indexes on tables
> that may grow large. Ship a query rewrite that lets the planner use the
> new index, and add behavioral tests that prove the planner picks it.

**Why this is small but high-leverage:** the bottleneck is one
`GROUP BY` over the entire `llm_history` table on every chat-list
load. With 69 372 rows in the live DB at 232 MB, that scan dominates
page render time as the table grows. One covering index + one
rewritten query makes the page a forward index scan with a small
join — bounded by `LIMIT`, not by total row count.

---

## 1. Symptom (what the user sees today)

### 1.1 Chat list slow to render (HIGH)

`src/ai_workflow/tui/llm_history.zig:115` is `getSessionList` — called
on every chat-list page load (the most-frequent user action). The
SQL it runs:

```sql
SELECT h.session_id, COALESCE(s.cwd, ''), MAX(h.created_at) AS created_at,
       COALESCE(h.agent, 'Agent'), COALESCE(s.name, '')
FROM llm_history h
LEFT JOIN sessions s ON h.session_id = s.id
GROUP BY h.session_id
ORDER BY MAX(h.created_at) DESC
LIMIT ? OFFSET ?
```

- **No WHERE clause** — the planner must read every row of
  `llm_history` to compute the `GROUP BY` + `MAX`.
- **No usable index.** The existing
  `idx_llm_history_session_created(session_id, created_at DESC)`
  does not help: it indexes per-session, but this query groups ACROSS
  sessions by recency.
- **Cost grows linearly** with `llm_history` row count. At 1 000
  messages across 10 sessions, the scan is 1 000 rows. At 100 000
  messages across 100 sessions (a long-running developer who never
  prunes), it is 100 000 rows — and this runs **on every page load**.

### 1.2 `getSessionsForBroadcast` SSE replay (MEDIUM)

`llm_history.zig:2708` powers the `getSessions` SSE consumed by
`ChatsList.vue`. The query does a `LEFT JOIN llm_history` without a
`GROUP BY`, returning one row per `(session × history_row)` pair.
For a long-running session with 1 000 messages, the SSE payload
includes 1 000 duplicate rows for that session. The frontend must
deduplicate.

This is a query-rewrite issue, not an indexing issue — see §5 for
why we are **not** fixing it in this plan.

### 1.3 Defensive gaps (LOW)

Two queries have no current callers but the indexes needed to make
them fast when a future feature invokes them do not exist:

- `llm_history.zig:2287` `listAllWorkspaceItems` — dead code today.
  If a future "all items across all workspaces" view calls it, the
  query is `ORDER BY position DESC, id ASC` with no `WHERE` and no
  covering index.
- `routines/Scheduler.zig:55` `resetStuckRunning` — runs once at
  startup, but the WHERE on `last_status = 'running'` has no index.
  Acceptable today (5 rows); worth a defensive index for forward
  compatibility.

---

## 2. Current state (what is already indexed)

Inventory from a live `EXPLAIN QUERY PLAN` on `~/.config/nalar/agent.db`:

| Table | Rows | Hot-path indexes | Gaps |
|-------|------|------------------|------|
| `llm_history` | 69 372 | `idx_llm_history_session_created` (M041), `idx_llm_history_parent_session` (M012) | No `(created_at DESC, session_id)` covering index for the chat-list scan |
| `sessions` | 850 | `idx_sessions_cwd_created` (M041), `idx_sessions_updated_at` (M041), `idx_sessions_workspace` (M025), `idx_sessions_status` (M017) | None |
| `workspace_items` | 15 | `idx_workspace_items_workspace_position` (M045), `idx_workspace_items_workspace_created` (M041), `idx_workspace_items_created_at` (M041), `idx_workspace_items_workspace` (M028) | No `(position DESC, id ASC)` covering index for the no-`WHERE` global case |
| `routines` | 5 | `idx_routines_enabled_next_run` (M044), implicit UNIQUE on `task_id` | No `last_status` index for the startup reaper |
| `worker` | 3 | `idx_worker_session` (M019), `idx_worker_last_activity` (M041) | None |
| `session_queue_messages` | 0 | `idx_session_queue_messages_session` (M018), `idx_session_queue_messages_session_created` (M041) | None |
| `session_background_process` | 99 | `idx_bg_process_session` (M014) | No `status` index for the reaper at `background_process.zig:88` (acceptable, ~10s of rows) |
| `workspace_item_tasks` | 427 | `idx_workspace_item_tasks_item_created` (M041), `idx_workspace_item_tasks_item_updated` (M042), `idx_workspace_item_tasks_item` (M034) | None |
| `workspaces` | 5 | `idx_workspaces_position` (M043), `idx_workspaces_created_at` (M041) | None |

**Bottom line:** the index health of the codebase is very good for
~95% of hot paths thanks to M041–M045. The one genuine performance
bottleneck is the chat-list query. Everything else is either covered
or low-priority insurance.

---

## 3. Design (what we are building)

### 3.1 One new index that fixes the chat-list scan

```sql
CREATE INDEX IF NOT EXISTS idx_llm_history_created_session
  ON llm_history(created_at DESC, session_id);
```

**Why this works:** the new index is sorted by `created_at DESC` with
`session_id` as a secondary key. The inner subquery

```sql
SELECT session_id, MAX(created_at) AS created_at
  FROM llm_history
 GROUP BY session_id
 ORDER BY created_at DESC
 LIMIT ? OFFSET ?
```

becomes a **covering index scan**: SQLite walks the index in order
(`ORDER BY created_at DESC` is the index order), reads `session_id`
from the index leaf (no row fetches), and stops after `LIMIT` rows.
Total work is `O(LIMIT)` — independent of the total `llm_history`
row count.

**Why this is NOT a duplicate of `idx_llm_history_session_created`:**
that index is `(session_id, created_at DESC)` — it indexes PER session
for filters `WHERE session_id = ?`. The new index is the **reverse**
— it indexes BY recency for the no-`WHERE` chat-list scan. Both
indexes coexist; each serves a different query shape.

### 3.2 One defensive index for `listAllWorkspaceItems`

```sql
CREATE INDEX IF NOT EXISTS idx_workspace_items_position_id
  ON workspace_items(position DESC, id ASC);
```

Matches `ORDER BY position DESC, id ASC` exactly. Cost: ~4 KB on
disk (the `workspace_items` table has 15 rows today). The index
becomes load-bearing only when a future feature uses
`listAllWorkspaceItems`; until then it is dead weight measured in
kilobytes.

### 3.3 One defensive index for the routine reaper

```sql
CREATE INDEX IF NOT EXISTS idx_routines_last_status
  ON routines(last_status);
```

Used by `routines/Scheduler.zig:55` `resetStuckRunning`:

```sql
UPDATE routines
   SET last_status = 'failed', last_error = ?, updated_at = datetime('now')
 WHERE last_status = 'running'
```

Acceptable to skip until `routines` exceeds ~10 000 rows. We add it
as insurance for forward compatibility — the index is ~4 KB today
and grows linearly.

### 3.4 Query rewrite for `getSessionList`

The current query cannot use the new index (the planner cannot
rearrange a `GROUP BY ... ORDER BY MAX(col) DESC` into an index scan
on `(created_at, session_id)`). It needs to become:

```sql
SELECT sub.session_id,
       sub.created_at,
       COALESCE(s.cwd, '') AS cwd,
       COALESCE(s.name, '') AS session_name,
       COALESCE(
         (SELECT h2.agent
            FROM llm_history h2
           WHERE h2.session_id = sub.session_id
           ORDER BY h2.created_at DESC
           LIMIT 1),
         'Agent'
       ) AS agent
FROM (
  SELECT h.session_id, MAX(h.created_at) AS created_at
    FROM llm_history h
   GROUP BY h.session_id
   ORDER BY created_at DESC
   LIMIT ? OFFSET ?
) sub
LEFT JOIN sessions s ON s.id = sub.session_id
ORDER BY sub.created_at DESC
```

**Why the inner subquery works:** SQLite's `GROUP BY` is loose
("any-value" semantics), and the planner sees that the inner query
returns one row per session in `created_at DESC` order. With the new
`idx_llm_history_created_session` index, the inner query is a
covering index scan: walk the index in order, read `session_id` from
the leaf, group as we go, stop at `LIMIT`. No row fetches, no sort.

**Why the correlated subquery for `agent`:** the original
non-aggregated `h.agent` was relying on SQLite's loose `GROUP BY`
picking an arbitrary value (a known SQLite quirk that produces
implementation-defined results across versions). The correlated
subquery makes the contract explicit: `agent` is the agent of the
**latest** message in the session. Each subquery is a single index
seek via the existing `idx_llm_history_session_created`, bounded by
`LIMIT/OFFSET` so total work is `O(page_size)`, not `O(table)`.

**Why we add `ORDER BY sub.created_at DESC` on the outer query:**
defensive — the inner subquery already returns rows in that order,
but the outer `LEFT JOIN` to `sessions` does not preserve order. An
explicit `ORDER BY` on the outer query guarantees stable pagination.

### 3.5 What we are NOT changing (out of scope)

- **`getSessionsForBroadcast` (Bottleneck 2, MEDIUM):** the SSE
  broadcast query at `llm_history.zig:2708` returns
  `(session × history_row)` duplicates for sessions with long
  histories. The fix is a query rewrite similar to §3.4 — use a
  subquery to dedupe. Defer to a follow-up plan; the immediate UX
  cost is bounded (the frontend dedupes the SSE payload in memory)
  and a focused follow-up keeps this plan's risk surface small.
- **`idx_session_background_process_status`:** the bg-process reaper
  at `background_process.zig:88` runs once at startup on a table
  with ~10s of rows. Not worth a 4 KB index today. Re-evaluate if
  the table ever exceeds 1 000 rows.
- **Renumbering or re-shaping existing indexes** (e.g. dropping the
  redundant `idx_session_agents_session` which is identical to the
  PK). These are cosmetic; defer to a cleanup pass.

---

## 4. Plan (chunks, in dependency order)

### Chunk 1 — Add Migration 048 + behavioral test

**Files:**
- `src/ai_workflow/tui/migration.zig` — add `Migration048AddChatListIndex`
  struct after `Migration046AddGitWorktreeCwdToSessions` (around line 828,
  before the `MigrationManager` struct).
- `src/ai_workflow/tui/migration.zig` — append a new entry to
  `allMigrations` slice (after line 927).
- `src/ai_workflow/tui/migration_chat_list_index_test.zig` — new file
  with a behavioral test that asserts the index exists in
  `sqlite_master` after `up()` runs.

**Migration 048 stub:**

```zig
pub const Migration048AddChatListIndex = struct {
    pub const version: u32 = 48;
    pub const name = "add_chat_list_index";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Hot read path: getSessionList (llm_history.zig:115) does
        // GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT/OFFSET
        // with no WHERE. Today the planner does a full table scan +
        // sort. With this covering index, the inner subquery becomes
        // a forward index scan: walk the index in created_at DESC
        // order, read session_id from the leaf, group, stop at LIMIT.
        //
        // NOT a duplicate of idx_llm_history_session_created — that
        // one is (session_id, created_at DESC) for filtering BY
        // session; this one is the reverse for the no-WHERE scan.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_llm_history_created_session " ++
            "ON llm_history(created_at DESC, session_id)",
            &[_][]const u8{});

        // ANALYZE so the query planner sees the new index on
        // pre-existing databases.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
```

**Slice entry (line 928):**

```zig
.{ .version = Migration048AddChatListIndex.version, .name = Migration048AddChatListIndex.name, .up = Migration048AddChatListIndex.up },
```

**Test file:** `src/ai_workflow/tui/migration_chat_list_index_test.zig`
— mirror the `migration_routines_test.zig` pattern (helper
`setupDb()` builds a minimal `llm_history` table, runs the
migration, asserts index exists via `SELECT name FROM sqlite_master
WHERE type='index' AND name='idx_llm_history_created_session'`).

**Register the test** in `src/ai_workflow/tui/test_runner.zig` (add
`_ = @import("migration_chat_list_index_test.zig");` near the other
migration test imports).

**Verification:**
- `timeout 180 zig build test --summary all 2>&1 | tail -n 5` →
  expect `test success` and +1 test.
- `git grep -n "Migration048" src/ai_workflow/tui/migration.zig` →
  expect 2 matches (struct decl + slice entry).
- `git grep -n "migration_chat_list_index_test" src/ai_workflow/tui/test_runner.zig` →
  expect 1 match.

### Chunk 2 — Rewrite `getSessionList` to use the new index

**File:** `src/ai_workflow/tui/llm_history.zig` — replace the `sql`
constant at line 115 with the rewritten query from §3.4. The
function signature, return type, and row-decoding logic do NOT
change.

**Two behavior-preserving requirements:**

1. **Same number of rows** for any given `(limit, offset)`. The
   inner subquery's `GROUP BY` and `LIMIT/OFFSET` produce the same
   session_id set as the original's `GROUP BY ... ORDER BY ...
   LIMIT ? OFFSET ?`.
2. **Same `agent` value** for each session. The original used
   SQLite's loose `GROUP BY` to pick an arbitrary `h.agent`. The
   rewrite's correlated subquery picks the `agent` of the **latest**
   message in the session — different in the rare case where a
   session was started by one agent and continued by another. We
   argue this is a BUG FIX, not a regression, because the original
   was implementation-defined. Document the change in the commit
   message: "tighten the agent column from SQLite's loose-GROUP-BY
   arbitrary value to the latest-message agent".

**Test additions** (in `src/ai_workflow/tui/llm_history_test.zig` if
it exists, or in a new `src/ai_workflow/tui/get_session_list_test.zig`):

- `getSessionList returns sessions in created_at DESC order` —
  insert 3 sessions with distinct last-message timestamps, assert
  the result order.
- `getSessionList respects LIMIT and OFFSET` — insert 5 sessions,
  page through with `limit=2`, assert correct slicing.
- `getSessionList includes the agent of the latest message` —
  insert a session whose first message has agent `A` and whose
  second message has agent `B`; assert the result row's `agent`
  field is `B`.
- **NEW (signature-defining) `EXPLAIN QUERY PLAN` test:** run the
  rewritten query against a 1 000-row fixture and assert the
  query plan contains `USING INDEX idx_llm_history_created_session`.
  This is a new pattern in the project (no existing test uses
  `EXPLAIN QUERY PLAN`); document it in
  `src/ai_workflow/tui/migration_chat_list_index_test.zig` as a
  reusable helper.

**Verification:**
- `timeout 180 zig build test --summary all 2>&1 | tail -n 5` →
  expect `test success` and +3 to +4 tests.
- Manual smoke: start the backend on port 8080, open the chat list
  in the desktop app, confirm the list loads in <100 ms (visually
  compare to the pre-change load time on a 50 000+ row DB).
- `EXPLAIN QUERY PLAN` against the live DB on port 8081:
  ```bash
  sqlite3 ~/.config/nalar/agent.db 'EXPLAIN QUERY PLAN
    SELECT h.session_id, MAX(h.created_at)
      FROM llm_history h
     GROUP BY h.session_id
     ORDER BY MAX(h.created_at) DESC
     LIMIT 20'
  ```
  Expect: `SEARCH llm_history USING INDEX idx_llm_history_created_session`
  in the plan output.

### Chunk 3 — Migration 049 (defensive indexes)

**File:** `src/ai_workflow/tui/migration.zig` — add
`Migration049AddDefensiveIndexes` (single migration with both
defensive indexes + `ANALYZE`).

```zig
pub const Migration049AddDefensiveIndexes = struct {
    pub const version: u32 = 49;
    pub const name = "add_defensive_indexes";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Defensive: covers listAllWorkspaceItems (llm_history.zig:2287)
        // which today has no callers. If a future "all items across all
        // workspaces" feature invokes it, the query is
        // ORDER BY position DESC, id ASC with no WHERE. The compound
        // (position DESC, id ASC) makes it a single covering index scan.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspace_items_position_id " ++
            "ON workspace_items(position DESC, id ASC)",
            &[_][]const u8{});

        // Defensive: covers resetStuckRunning (routines/Scheduler.zig:55)
        // which runs once at startup. The WHERE on last_status='running'
        // has no index today. Acceptable while routines < 10 000 rows;
        // this index makes the future cost independent of table size.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_routines_last_status " ++
            "ON routines(last_status)",
            &[_][]const u8{});

        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
```

**Slice entry + test file + test_runner registration** — same
pattern as Chunk 1.

**Test file:** `src/ai_workflow/tui/migration_defensive_indexes_test.zig`
— mirror the `migration_routines_test.zig` pattern; one test per
index, each asserting the index name appears in `sqlite_master`.

**Verification:**
- `timeout 180 zig build test --summary all 2>&1 | tail -n 5` →
  expect `test success` and +2 tests.
- `git grep -n "Migration049" src/ai_workflow/tui/migration.zig` →
  expect 2 matches.
- `git grep -n "migration_defensive_indexes_test" src/ai_workflow/tui/test_runner.zig` →
  expect 1 match.

---

## 5. Risk and rollback

### 5.1 Risk: migration is slow on a large existing DB

`CREATE INDEX` on a 232 MB table takes O(N) time. For the user's
live DB (69 372 rows) it will be sub-second. For a hypothetical
10 000 000-row DB it could take 30 s of exclusive write lock. The
`runMigrations` step is called at server start with no other
connections active, so a 30 s startup cost is acceptable but not
invisible.

**Mitigation:** for production deploys with very large `llm_history`
tables, run `CREATE INDEX` ahead of the deploy via
`sqlite3 ~/.config/nalar/agent.db 'CREATE INDEX ...'` (no
`IF NOT EXISTS` — the migration adds it later as a no-op). Document
this in the migration's `//` comment if the live row count ever
exceeds 1 000 000.

### 5.2 Risk: query rewrite breaks an existing caller

`getSessionList` is called by `chats_list.zig` (frontend HTTP
handler) and has 0 other production callers (verified by
`rg getSessionList src/`). The function signature and return type
do not change. The risk surface is the `agent` column semantics
change — see Chunk 2 step 2.

**Mitigation:** add a behavioral test that pins the `agent`
semantics to "latest message in the session". The test name
documents the contract.

### 5.3 Risk: planner ignores the new index

SQLite's planner may reject the index for the rewritten query if
it estimates a full scan to be cheaper (e.g. on a tiny table with
1 row). The query-plan test in Chunk 2 catches this for the
1 000-row fixture. For the live DB (69 372 rows), the planner
should pick the index; if it does not, the migration is a no-op
and the user sees no regression.

**Mitigation:** the `EXPLAIN QUERY PLAN` test is the regression
guard. If a future SQLite version changes planner behavior, the
test catches it before the rewrite ships.

### 5.4 Rollback

Migrations have no `down()` function in this codebase. To roll
back: `DROP INDEX idx_llm_history_created_session;` and revert
the getSessionList SQL constant. No data loss; the index is
recoverable from `llm_history` at any time.

---

## 6. Verification (overall)

After all three chunks land:

1. **Build:** `timeout 180 zig build install:linux:system 2>&1 | tail -n 15` →
   expect 4/6 steps succeed; the cp at step 5 is permission-denied
   (harmless); step 6 may also fail (also harmless).
2. **Unit tests:** `timeout 180 zig build test --summary all 2>&1 | tail -n 5` →
   expect `test success` and the new test count
   (current baseline + 1 from Chunk 1 + 3-4 from Chunk 2 +
   2 from Chunk 3 = +6 to +7).
3. **Frontend type-check:** `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` →
   expect clean build (no new TypeScript errors; this plan
   does not touch frontend code but a green build is the gate).
4. **Live EXPLAIN:** run the EXPLAIN QUERY PLAN command from Chunk 2
   step 4 against `~/.config/nalar/agent.db` (the user's live DB
   on port 8081). Expect the new index name in the plan.
5. **Manual smoke test:**
   - Start backend on port 8080:
     `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && ./zig-out/bin/nalar --port 8080 &`
   - Open `http://127.0.0.1:8080` in a browser, log in, open
     the chat list. Confirm:
     - Page loads (not stuck).
     - Sessions are listed in correct order (newest first).
     - The `agent` field for each session matches the agent of
       the most recent message (not some arbitrary value).
   - Kill the smoke-test process (`kill <pid>`). **DO NOT kill
     the nalar on 8081** (project's mandatory rule).
6. **Live DB size check:** `ls -lh ~/.config/nalar/agent.db` →
   expect the file size to grow by ~1 MB (the new index is
   `created_at × session_id` for 69 372 rows; ~14 bytes per row).

---

## 7. Out-of-scope follow-ups (future plans)

- **Fix `getSessionsForBroadcast` SSE payload bloat** (Bottleneck 2,
  MEDIUM). Rewrite to use a subquery so the SSE payload size is
  bounded by the session count, not by total `llm_history` rows.
- **Audit `routines` index health** once the routine count exceeds
  1 000. At that scale, re-evaluate `idx_routines_last_status`
  selectivity and consider a composite `(enabled, last_status,
  next_run_at)` index for the per-tick poll.
- **Drop redundant PK-covering indexes** as a cleanup pass
  (e.g. `idx_session_agents_session` which is identical to the PK).
  Cosmetic; ~12 KB of disk savings.
- **Re-evaluate `session_background_process.status` index** if the
  bg-process table ever exceeds 1 000 rows.
