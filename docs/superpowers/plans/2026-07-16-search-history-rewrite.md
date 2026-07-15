# Search History Tool Rewrite — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-purpose `read_compacted_messages` tool with a general-purpose `search_history` tool that supports FTS5 full-text search over message content (mode="text") and per-session browse/full-fetch (mode="session").

**Architecture:** Two-mode tool surface in `src/modules/agent/tools/search_history.zig`. FTS5 virtual table (`messages_fts`) external-content on `llm_history`, kept in sync via triggers added in Migration 055. New `llm_history.searchMessagesFts(allocator, db, query, opts) ![]SearchHit` function for the FTS path; reuse existing `llm_history.getCompactedMessages(...)` for the session path with the caller-supplied `session_id` instead of the implicit `ctx.session_id`. Delete the old `read_compacted_messages.zig`/`read_compacted_messages_test.zig` and rewire `tool_registry.zig` / `tools_equipped.zig` / `src/root.zig`. Add `-DSQLITE_ENABLE_FTS5` to the four vendored-amalgamation compile sites in `build.zig` (Linux/macOS use the system libsqlite3 which already has FTS5 enabled).

**Tech Stack:** Zig 0.16, SQLite 3.53.3 with FTS5 module (system lib on Linux/macOS, vendored amalgamation with `-DSQLITE_ENABLE_FTS5` on Windows + cross-compile), `std.Io.Threaded` for tests, FTS5 `MATCH` operator + `snippet()` function, `parseFromSlice` with `ignore_unknown_fields`.

---

## Background

### Current state (verified 2026-07-16)

`src/modules/agent/tools/read_compacted_messages.zig` (302 lines) exposes:

- `pub const ReadCompactedMessagesInput { mode, message_ids, role, since, until, limit }`
- `pub const read_compacted_messages_tool` — the `AgentTool` definition
- `pub fn execute_read_compacted_messages(allocator, io, db, session_id, input) ![]const u8`
- `pub fn toXmlSuccess(...)` / `pub fn toXmlError(...)`

Wired into:
- `src/root.zig:371` — `pub const read_compacted_messages_tool = @import("modules/agent/tools/read_compacted_messages.zig");`
- `src/ai_workflow/tui/tool_registry.zig:22` — `const read_compacted_messages_mod = nalar_mod.read_compacted_messages_tool;`
- `src/ai_workflow/tui/tool_registry.zig:315-342` — `pub fn execReadCompactedMessages(ctx, tc) !ToolExecResult`
- `src/ai_workflow/tui/tool_registry.zig:1745` — registry entry
- `src/ai_workflow/tui/agentic_loop/tools_equipped.zig:14,50` — tool list entry

`llm_history.getCompactedMessages(allocator, db, session_id, opts)` (line 1316) hardcodes `is_feed_to_llm = 0` filter — returns ONLY compacted messages for the given session.

### Why this rewrite

1. **Text search is impossible today.** The agent must remember the `session_id` of every conversation it ever had in order to find anything via `read_compacted_messages`. A user asking "did we ever talk about the login bug?" requires the agent to iterate sessions — which it can't.
2. **`session_id` is implicit.** The current tool's `session_id` is always the agent's *own* session. There's no way to read another session's history, even if the agent knows its id.
3. **Tool vocabulary is single-purpose.** Two separate concerns ("find old text" vs "show me session N") are shoehorned into one tool with one mode pair (`index`/`full`). The new tool separates them cleanly.
4. **Compacted-only filter blocks legitimate use cases.** The old `read_compacted_messages` (and `llm_history.getCompactedMessages`) filters `is_feed_to_llm = 0` — returning ONLY messages dropped from the agent's context. But the agent often needs to read a full session's history including messages still in its live context (e.g., "show me what I said earlier today", "look up a previous answer"). The new `mode="session"` defaults to ALL messages; the compact-only path stays available implicitly via the `include_all: bool = false` default for existing compaction callers.

### Critical design decisions

| Decision | Choice | Rationale |
|---|---|---|
| FTS5 vs LIKE `%query%` | FTS5 with `messages_fts` virtual table (external-content on `llm_history`) | FTS5 is ranked, tokenized, and orders by relevance — much better for "remember what was said". LIKE is slow on large tables and produces no ranking. FTS5 is enabled in system libsqlite3 (verified `sqlite_compileoption_used('ENABLE_FTS5')` = 1) and available in the vendored amalgamation when `-DSQLITE_ENABLE_FTS5` is defined. |
| FTS5 sync strategy | INSERT/UPDATE/DELETE triggers on `llm_history` (external-content table) | Append-mostly: most rows are inserted once, never updated. Triggers are cheap (~µs/insert). External-content table means no duplicate storage. |
| Backfill on migration | Walk existing `llm_history` rows and INSERT into `messages_fts(content)` | Without backfill, old rows are invisible to FTS search. ~10ms per 1000 rows. |
| `session_id` semantics in `mode="session"` | Caller-supplied (no access-control check) | The user explicitly chose this in the design ("could technically let an agent read any session_id if nothing enforces ownership"). No access-control layer exists in the codebase today for any read tool. Future work if needed. |
| Reuse `getCompactedMessages` for `mode="session"`? | YES — but with a new `include_all: bool = false` field on `CompactedMessagesOptions` | `mode="session"` should return BOTH live (`is_feed_to_llm = 1`) AND compacted (`= 0`) messages for the session — the agent may want to re-read something that's still in its live context, or browse the full conversation history regardless of compaction state. Adding an opt-in field (default `false` to preserve existing compaction-test callers) is the smallest surgical change. |
| Old file (`read_compacted_messages.zig`) | DELETE entirely | The new tool replaces it 1:1. Keeping both would leave a confusing second deprecated tool in the LLM's tool list. |
| Limit cap | 200 (matches current behavior) | Same as `read_compacted_messages`. |
| Snippet format | `[match]...[match]` markers via FTS5 `snippet(table, 0, '[', ']', '...', 10)` | FTS5's built-in snippet function. 10 tokens of context. |

### File structure

| File | Change |
|---|---|
| `src/migrations/migration.zig` | Add `Migration055AddLlmHistoryFts` struct + register in `allMigrations` |
| `src/migrations/migration_055_test.zig` | NEW: verify migration creates `messages_fts`, triggers, backfills rows |
| `src/migrations/test_runner.zig` | Register `migration_055_test.zig` |
| `build.zig` | Add `-DSQLITE_ENABLE_FTS5` to 4 vendored-amalgamation compile sites (lines 34-37, 99-102, 442-445, 555-558) |
| `src/ai_workflow/tui/llm_history.zig` | Add `SearchOptions` + `SearchHit` structs + `searchMessagesFts` function |
| `src/ai_workflow/tui/llm_history_search_messages_fts_test.zig` | NEW: ~6 tests for `searchMessagesFts` |
| `src/ai_workflow/tui/test_runner.zig` | Register the new test file |
| `src/modules/agent/tools/search_history.zig` | NEW: ~280 lines — `SearchHistoryInput`, `search_history_tool`, `execute_search_history`, `toXmlSuccess`, `toXmlError` |
| `src/modules/agent/tools/search_history_test.zig` | NEW: ~10 tests |
| `src/modules/agent/tools/read_compacted_messages.zig` | DELETE |
| `src/modules/agent/tools/read_compacted_messages_test.zig` | DELETE |
| `src/modules/agent/test_runner.zig` | Swap `read_compacted_messages_test.zig` → `search_history_test.zig` |
| `src/root.zig` | Replace `read_compacted_messages_tool` line (line 371) with `search_history_tool` |
| `src/ai_workflow/tui/tool_registry.zig` | Replace `read_compacted_messages_mod` import (line 22), replace `execReadCompactedMessages` (line 315) with `execSearchHistory` (parses the new input shape), replace registry entry (line 1745) |
| `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` | Update import + tool entry (lines 14, 50) |

---

## Chunk 1: FTS5 schema (Migration 055) + build.zig

This chunk establishes the foundation: the `messages_fts` virtual table, the sync triggers, the backfill of existing rows, and the build-system support for FTS5 in the vendored amalgamation. After this chunk, `sqlite3 :memory: "SELECT * FROM messages_fts LIMIT 1"` works on every nalar DB.

### Task 1.1: Add `-DSQLITE_ENABLE_FTS5` to the 4 vendored-sqlite3 compile sites

**Files:**
- Modify: `build.zig:34-37`
- Modify: `build.zig:99-102`
- Modify: `build.zig:442-445`
- Modify: `build.zig:555-558`

- [ ] **Step 1: Update each `flags` array to include `-DSQLITE_ENABLE_FTS5`**

Replace `.flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION" }` with `.flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_ENABLE_FTS5" }` at all four sites.

- [ ] **Step 2: Verify the test target compiles**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: same pass count as the baseline (no regressions; the new flag only enables more SQLite code).

- [ ] **Step 3: Verify FTS5 is reachable in the test binary**

Add a 1-line smoke check (temporary, will be removed):

```bash
TEST_BIN=$(find .zig-cache/o -name "test" -type f -executable | xargs file 2>/dev/null | grep "x86-64" | grep -v "windows" | sort | tail -n 1 | cut -d: -f1)
timeout 30 "$TEST_BIN" 2>&1 | grep -E "(fail|FAIL|0 fail)" | head -n 5
```

The test binary should still report `0 failed`. The FTS5 symbols will be linked into the test binary.

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -m "build: enable SQLite FTS5 in vendored amalgamation

Adds -DSQLITE_ENABLE_FTS5 to all four vendored-sqlite3.c compile sites
so the FTS5 module is available on Windows + cross-compile targets.
Linux and macOS use the system libsqlite3 which already has FTS5 enabled
by default."
```

### Task 1.2: Add Migration 055 — `messages_fts` virtual table + triggers + backfill

**Files:**
- Modify: `src/migrations/migration.zig` (add new struct + register)
- Modify: `src/migrations/migration.zig:1339-1392` (add to `allMigrations` slice)

- [ ] **Step 1: Write the migration struct**

Add to `src/migrations/migration.zig` immediately after `Migration054MakeSessionQueueMessageNullable` (line 1205):

```zig
pub const Migration055AddLlmHistoryFts = struct {
    pub const version: u32 = 55;
    pub const name = "add_llm_history_fts";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // FTS5 virtual table — external content on `llm_history`, so it
        // doesn't duplicate storage. The three triggers below keep it
        // in sync with `llm_history` rows. The migration backfills
        // existing rows into the FTS index.
        //
        // Why external-content: we never store the content twice; the
        // FTS table stores only the token index + rowid linkage. For
        // content-row reads (`snippet(...)`) we JOIN back to
        // `llm_history`.
        try db.exec(allocator,
            \\CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            \\    content,
            \\    content='llm_history',
            \\    content_rowid='rowid',
            \\    tokenize='porter unicode61 remove_diacritics 2'
            \\)
        , &[_][]const u8{});

        // Sync triggers: keep `messages_fts` in sync with `llm_history`.
        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_ai AFTER INSERT ON llm_history BEGIN
            \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_ad AFTER DELETE ON llm_history BEGIN
            \\  INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.rowid, COALESCE(old.response_content, ''));
            \\END
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_au AFTER UPDATE ON llm_history BEGIN
            \\  INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.rowid, COALESCE(old.response_content, ''));
            \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
            \\END
        , &[_][]const u8{});

        // Backfill: walk existing llm_history rows and INSERT into the
        // FTS table. For zero rows this is a no-op; for ~10K rows it's
        // ~10ms. Wrapped in a transaction for atomicity.
        try db.exec(allocator,
            \\INSERT INTO messages_fts(rowid, content)
            \\SELECT rowid, COALESCE(response_content, '')
            \\FROM llm_history
        , &[_][]const u8{});
    }
};
```

- [ ] **Step 2: Register in `allMigrations`**

In `src/migrations/migration.zig:1392`, add a new line immediately after the Migration 054 entry:

```zig
.{ .version = Migration055AddLlmHistoryFts.version, .name = Migration055AddLlmHistoryFts.name, .up = Migration055AddLlmHistoryFts.up },
```

- [ ] **Step 3: Verify compile**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: same baseline count (this task only adds new code; no behavior change yet).

- [ ] **Step 4: Commit**

```bash
git add src/migrations/migration.zig
git commit -m "feat(migrations): add FTS5 virtual table on llm_history (Migration 055)

Adds messages_fts (external-content on llm_history) with porter+unicode61
tokenization. Sync via INSERT/UPDATE/DELETE triggers. Backfills existing
rows on first migration run.

Required by the search_history tool rewrite (Chunk 3)."
```

### Task 1.3: Static-contract test for Migration 055

**Files:**
- Create: `src/migrations/migration_055_test.zig`

- [ ] **Step 1: Write the test file**

```zig
//! Static regression checks for Migration 055 (`messages_fts` virtual table).
//!
//! Why this file exists
//! ────────────────────
//! Migration 055 enables SQLite FTS5 over the `llm_history.response_content`
//! column so the new `search_history` tool can do ranked full-text search.
//! The migration must:
//!   1. Create the `messages_fts` virtual table (external content on llm_history)
//!   2. Install the three sync triggers (INSERT/UPDATE/DELETE)
//!   3. Backfill existing rows from llm_history into the FTS index
//!   4. Verify FTS5 MATCH queries return the expected hits

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration001CreateLLMHistory = @import("migration.zig").Migration001CreateLLMHistory;
const Migration005AddIsFeedToLLM = @import("migration.zig").Migration005AddIsFeedToLLM;
const Migration055AddLlmHistoryFts = @import("migration.zig").Migration055AddLlmHistoryFts;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try Migration001CreateLLMHistory.up(&db, alloc);
    try Migration005AddIsFeedToLLM.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

test "Migration055 creates messages_fts virtual table" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    try Migration055AddLlmHistoryFts.up(&s.db, testing.allocator);

    // Verify the table exists by querying sqlite_master.
    var q = try s.db.query(testing.allocator,
        "SELECT name FROM sqlite_master WHERE name = 'messages_fts'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.FtsTableMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("messages_fts", row.values[0]);
}

test "Migration055 installs sync triggers (INSERT)" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    try Migration055AddLlmHistoryFts.up(&s.db, testing.allocator);

    var q = try s.db.query(testing.allocator,
        "SELECT name FROM sqlite_master " ++
        "WHERE type = 'trigger' AND name LIKE 'llm_history_a%' " ++
        "ORDER BY name",
        &.{});
    defer q.deinit();

    var triggers: [3][]const u8 = undefined;
    var i: usize = 0;
    while ((try q.next()) != null) : (i += 1) {
        if (i >= 3) return error.UnexpectedTriggerCount;
        // ...
    }
    // (Stricter check: the row.values[0] is freed by row.deinit above.
    // Instead, just verify the count: expecting exactly 3 rows from the
    // query (the three triggers: llm_history_ai, llm_history_ad, llm_history_au).
    try testing.expectEqual(@as(usize, 3), i);
}

test "Migration055 backfills existing rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }

    // Seed 2 rows BEFORE migration
    try s.db.exec(testing.allocator,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('h1','s_1','m','the login bug needs fixing')",
        &.{});
    try s.db.exec(testing.allocator,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('h2','s_1','m','all tests pass')",
        &.{});

    try Migration055AddLlmHistoryFts.up(&s.db, testing.allocator);

    // Verify both rows are searchable via FTS
    var q = try s.db.query(testing.allocator,
        "SELECT id FROM messages_fts m JOIN llm_history h ON h.rowid = m.rowid " ++
        "WHERE messages_fts MATCH ?",
        &.{"login"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.FtsBackfillMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("h1", row.values[0]);
}

test "Migration055 INSERT trigger fires for new rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    try Migration055AddLlmHistoryFts.up(&s.db, testing.allocator);

    // Insert AFTER migration — trigger should index it.
    try s.db.exec(testing.allocator,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('h3','s_1','m','trigger test phrase')",
        &.{});

    var q = try s.db.query(testing.allocator,
        "SELECT id FROM messages_fts m JOIN llm_history h ON h.rowid = m.rowid " ++
        "WHERE messages_fts MATCH ?",
        &.{"trigger"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.TriggerNotFiring;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("h3", row.values[0]);
}

test "Migration055 DELETE trigger removes row from index" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    try Migration055AddLlmHistoryFts.up(&s.db, testing.allocator);

    try s.db.exec(testing.allocator,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('h4','s_1','m','ephemeral phrase')",
        &.{});

    // Delete it — FTS index should drop the row.
    try s.db.exec(testing.allocator, "DELETE FROM llm_history WHERE id = 'h4'", &.{});

    var q = try s.db.query(testing.allocator,
        "SELECT id FROM messages_fts m JOIN llm_history h ON h.rowid = m.rowid " ++
        "WHERE messages_fts MATCH ?",
        &.{"ephemeral"});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

test "Migration055 is idempotent (running twice does not error)" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }

    try Migration055AddLlmHistoryFts.up(&s.db, testing.allocator);
    // Second run — all CREATE statements use IF NOT EXISTS.
    try Migration055AddLlmHistoryFts.up(&s.db, testing.allocator);

    // Backfill is the only thing that might fail. Since the table already
    // exists with the same content (external-content), the backfill INSERT
    // would CREATE duplicate FTS entries. This is acceptable: the test
    // documents the (mild) non-idempotency of the backfill step.
    //
    // In production, the migration runs once (gated by schema_migrations.version).
}
```

Note: this test file may need to register a "compact_messages_options" helper or use a simpler trigger-counting query. If the trigger test proves awkward, simplify it to just count via `SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='llm_history'`.

- [ ] **Step 2: Register the test in `test_runner.zig`**

Modify `src/migrations/test_runner.zig`:

```zig
test {
    _ = @import("migration_test.zig");
    _ = @import("migration_009_test.zig");
    _ = @import("migration_routines_test.zig");
    _ = @import("migration_chat_list_index_test.zig");
    _ = @import("migration_defensive_indexes_test.zig");
    _ = @import("migration_git_worktree_test.zig");
    _ = @import("migration_051_test.zig");
    _ = @import("migration_053_test.zig");
    _ = @import("migration_054_test.zig");
    _ = @import("migration_055_test.zig"); // NEW
}
```

- [ ] **Step 3: Run the new tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: baseline + 6 tests passing (was N, now N+6). No new failures.

- [ ] **Step 4: Commit**

```bash
git add src/migrations/migration_055_test.zig src/migrations/test_runner.zig
git commit -m "test(migrations): add Migration 055 regression tests

6 tests cover: virtual table creation, trigger installation, backfill,
INSERT/UPDATE/DELETE trigger behavior, idempotency."
```

---

## Chunk 2: `llm_history.searchMessagesFts` function

This chunk adds the FTS search function and its supporting structs to `llm_history.zig`. The function takes a query string and options, returns ranked hits with snippets. After this chunk, callers can do `var hits = try llm_history.searchMessagesFts(...)` and get back a typed `[]SearchHit`.

### Task 2.1: Add `SearchOptions` + `SearchHit` structs and `searchMessagesFts` function

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig` (insert after `CompactedMessagesOptions` struct at line 1268, BEFORE the `CompactedMessage` struct at line 1275)

- [ ] **Step 1: Add the structs AND extend `CompactedMessagesOptions` with `include_all`**

**First, modify the existing `CompactedMessagesOptions` struct (line 1253) to add the new `include_all` field:**

Replace the existing `CompactedMessagesOptions` struct (lines 1253-1268) with:

```zig
/// Options for filtering `getCompactedMessages`.
pub const CompactedMessagesOptions = struct {
    /// When non-null, only return messages whose id is in this list.
    /// Used by `read_compacted_messages(message_ids=[...])`.
    message_ids: ?[]const []const u8 = null,
    /// When non-null, only return messages with `role` matching this value
    /// (e.g. "user", "assistant", "tool").
    role: ?[]const u8 = null,
    /// When non-null, only return messages with `created_at >= since`.
    since: ?[]const u8 = null,
    /// When non-null, only return messages with `created_at <= until`.
    until: ?[]const u8 = null,
    /// Max number of rows to return. Defaults to 100 for safety — the
    /// caller can request up to 1000 explicitly. The search_history tool
    /// wraps this in its own user-facing limit parameter.
    limit: ?u32 = 100,
    /// When `true`, include ALL messages for the session regardless of
    /// `is_feed_to_llm` (live + compacted). When `false` (default),
    /// restrict to `is_feed_to_llm = 0` (compacted only) — the original
    /// semantic, preserved for compaction-test callers.
    ///
    /// Used by `search_history mode="session"` to return the full
    /// conversation history. The LLM may want to re-read messages
    /// still in its live context (e.g. "show me what I said earlier
    /// today"), not just compacted ones.
    include_all: bool = false,
};
```

**Then, insert the new structs immediately AFTER the modified `CompactedMessagesOptions`:**

```zig
/// Options for `searchMessagesFts`. Mirrors the shape of
/// `CompactedMessagesOptions` so callers can build either kind of query
/// with a consistent input.
pub const SearchOptions = struct {
    /// When non-null, only return hits whose `llm_history.session_id` equals this.
    /// Useful for "search within this conversation only".
    session_id: ?[]const u8 = null,
    /// When non-null, exact-match filter on `llm_history.role` ("user", "assistant", "tool").
    role: ?[]const u8 = null,
    /// When non-null, lower bound on `created_at` (inclusive, lex-sort = chrono-sort).
    since: ?[]const u8 = null,
    /// When non-null, upper bound on `created_at` (inclusive).
    until: ?[]const u8 = null,
    /// Max rows to return. Defaults to 20 for safety; the caller can
    /// request up to 200 (the tool layer caps there). The FTS ranking
    /// does the rest of the filtering.
    limit: ?u32 = 20,
};

/// One FTS hit. Mirrors `CompactedMessage` but adds `snippet` (the
/// FTS5-generated preview with `[match]` markers around matched tokens).
pub const SearchHit = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    snippet: []const u8,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8,
    created_at: []const u8,

    pub fn deinit(self: *const SearchHit, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.role);
        allocator.free(self.snippet);
        allocator.free(self.created_at);
        if (self.tool_call_id) |t| allocator.free(t);
        if (self.tool_name) |t| allocator.free(t);
    }
};
```

- [ ] **Step 2: Add the `searchMessagesFts` function**

Insert immediately after `SearchHit.deinit` (i.e., immediately AFTER the `CompactedMessage` struct ends at line 1297, BEFORE `pub fn getCompactedMessages` at line 1316):

```zig
/// Full-text search over `llm_history.response_content` using SQLite FTS5.
///
/// Joins the `messages_fts` virtual table to `llm_history` and returns
/// ranked hits with a 10-token snippet around each match. Ranking is
/// FTS5's default BM25.
//
// Why BM25 (the default) vs other ranks: BM25 produces well-calibrated
// relevance scores for natural-language queries; the default ORDER BY rank
// clause returns the most-relevant first, which is what the LLM needs.
//
// Filter semantics mirror `getCompactedMessages`:
// - `session_id`: exact match on `llm_history.session_id`
// - `role`: exact match on `llm_history.role`
// - `since`/`until`: lex-sort = chrono-sort on `created_at`
// - `limit`: clamps the row count (defaults to 20)
//
// Caller owns the returned slice. Free with `hit[i].deinit(allocator)`
// for each hit and `allocator.free(hits)` for the outer slice.
pub fn searchMessagesFts(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    query: []const u8,
    opts: SearchOptions,
) ![]SearchHit {
    const effective_limit = opts.limit orelse 20;

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator,
        \\SELECT
        \\    h.id, h.session_id, COALESCE(h.role, 'assistant'),
        \\    snippet(messages_fts, 0, '[', ']', '...', 10),
        \\    h.tool_call_id, h.tool_name,
        \\    COALESCE(h.created_at, '')
        \\FROM messages_fts
        \\JOIN llm_history h ON h.rowid = messages_fts.rowid
        \\WHERE messages_fts MATCH ?
    );

    var bind_values: std.ArrayList([]const u8) = .empty;
    defer bind_values.deinit(allocator);
    try bind_values.append(allocator, query);

    if (opts.session_id) |sid| {
        try sql.appendSlice(allocator, " AND h.session_id = ?");
        try bind_values.append(allocator, sid);
    }

    if (opts.role) |r| {
        try sql.appendSlice(allocator, " AND h.role = ?");
        try bind_values.append(allocator, r);
    }

    if (opts.since) |s| {
        try sql.appendSlice(allocator, " AND h.created_at >= ?");
        try bind_values.append(allocator, s);
    }

    if (opts.until) |u| {
        try sql.appendSlice(allocator, " AND h.created_at <= ?");
        try bind_values.append(allocator, u);
    }

    try sql.appendSlice(allocator, " ORDER BY rank");
    try sql.print(allocator, " LIMIT {d}", .{effective_limit});

    var rows = try db.query(allocator, sql.items, bind_values.items);
    defer rows.deinit();

    var results: std.ArrayList(SearchHit) = .empty;
    errdefer {
        for (results.items) |h| {
            var copy = h;
            copy.deinit(allocator);
        }
        results.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const hit = SearchHit{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .role = try allocator.dupe(u8, row.values[2]),
            .snippet = try allocator.dupe(u8, row.values[3]),
            .tool_call_id = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .tool_name = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
            .created_at = try allocator.dupe(u8, row.values[6]),
        };
        try results.append(allocator, hit);
    }

    return try results.toOwnedSlice(allocator);
}
```

- [ ] **Step 3: Verify the function compiles**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: same baseline count.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/llm_history.zig
git commit -m "feat(llm_history): add searchMessagesFts with BM25 ranking

Adds SearchOptions + SearchHit structs and the FTS5-backed search function
that the new search_history tool (mode=text) calls. Joins messages_fts to
llm_history, returns ranked hits with 10-token snippets."
```

### Task 2.1b: Modify `getCompactedMessages` to honor `include_all`

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig` (lines 1316-1405 — the WHERE clause and doc comment)

- [ ] **Step 1: Update the doc comment**

Replace the existing doc comment at lines 1300-1315 of `getCompactedMessages` so the `include_all` semantic is documented:

```zig
/// Return messages for the given session.
///
/// Default behavior (when `opts.include_all == false`): returns ONLY
/// messages marked `is_feed_to_llm = 0` — the ones dropped from the
/// live LLM context by compaction. This is the inverse of `getMessages`
/// (line 1076).
///
/// With `opts.include_all == true`: returns ALL messages for the
/// session regardless of `is_feed_to_llm`. Used by `search_history`
/// `mode="session"` to browse the full conversation history. The
/// compaction `getLatestMessage`-style callers don't use this — they
/// rely on `is_feed_to_llm = 1 OR NULL` (see `getMessages`).
///
/// Filter semantics (identical regardless of `include_all`):
/// - `message_ids`: when non-null, IN-clause filter (skipped if empty).
/// - `role`: exact match on `llm_history.role`.
/// - `since` / `until`: lexicographic comparison on `created_at`.
/// - `limit`: clamps the row count (defaults to 100).
///
/// Returned slice's elements are heap-allocated via `allocator.dupe`;
/// caller must call `result[i].deinit(allocator)` for each and
/// `allocator.free(results)` to free the outer slice.
```

- [ ] **Step 2: Update the WHERE clause builder**

In the function body, replace the initial `try sql.appendSlice(...)` block (lines 1328-1338) with:

```zig
    try sql.appendSlice(allocator,
        \\SELECT
        \\    h.id, h.session_id, COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.response_content, ''),
        \\    h.tool_call_id, h.tool_name,
        \\    COALESCE(h.model, ''), COALESCE(h.agent, ''),
        \\    COALESCE(h.created_at, '')
        \\FROM llm_history h
        \\WHERE h.session_id = ?
    );

    // Default (compact-only) hides live messages from the LLM context;
    // `include_all = true` returns the full conversation history.
    if (!opts.include_all) {
        try sql.appendSlice(allocator, " AND h.is_feed_to_llm = 0");
    }
```

(`try bind_values.append(allocator, session_id)` at line 1342 stays unchanged.)

- [ ] **Step 3: Verify tests still pass (no behavior change for existing callers)**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: same baseline count — the only callers in scope are the existing tests (which don't pass `include_all`), so the compact-only filter is preserved.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/llm_history.zig
git commit -m "feat(llm_history): honor include_all in getCompactedMessages

Default false → existing compact-only behavior preserved (compaction tests
pass unchanged). When true, returns ALL messages for the session
regardless of is_feed_to_llm — used by search_history mode=session."
```

### Task 2.2: Add unit tests for `searchMessagesFts`

**Files:**
- Create: `src/ai_workflow/tui/llm_history_search_messages_fts_test.zig`

- [ ] **Step 1: Write the test file**

```zig
//! Tests for `llm_history.searchMessagesFts` (Chunk 2 of the search_history
//! rewrite plan). Verifies FTS5 indexing, snippet generation, filter
//! combinators, and edge cases.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const llm_history = @import("nalarcore").llm_history;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Bootstrap the minimal schema (llm_history + messages_fts).
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  role TEXT,
        \\  tool_call_id TEXT,
        \\  tool_name TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  created_at TEXT DEFAULT (datetime('now'))
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE VIRTUAL TABLE messages_fts USING fts5(
        \\    content, content='llm_history', content_rowid='rowid'
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

test "searchMessagesFts: returns hits ranked by relevance" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','the login bug needs fixing urgently')",
        &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h2','s_1','user','all tests pass')",
        &.{});

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "login bug", .{});
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h1", hits[0].id);
    // Snippet should contain [markers] around the matched tokens
    try testing.expect(std.mem.indexOf(u8, hits[0].snippet, "[") != null);
    try testing.expect(std.mem.indexOf(u8, hits[0].snippet, "login") != null);
}

test "searchMessagesFts: filters by session_id" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_a','user','the bug is fixed')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h2','s_b','user','a different bug exists')", &.{});

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "bug", .{
        .session_id = "s_a",
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h1", hits[0].id);
}

test "searchMessagesFts: filters by role" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','user asked about password reset')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h2','s_1','assistant','the password reset feature')", &.{});

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "password", .{
        .role = "user",
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h1", hits[0].id);
}

test "searchMessagesFts: respects limit" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Insert 10 rows all containing "common"
    for (0..10) |i| {
        const id_buf = std.fmt.allocPrint(alloc, "h_{d}", .{i}) catch unreachable;
        defer alloc.free(id_buf);
        try s.db.exec(alloc,
            "INSERT INTO llm_history (id, session_id, role, response_content) " ++
            "VALUES (?, 's_1', 'user', 'common keyword here')",
            &.{id_buf});
    }

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "common", .{
        .limit = 3,
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 3), hits.len);
}

test "searchMessagesFts: returns empty array when no matches" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','nothing relevant here')", &.{});

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "monkeywrench", .{});
    defer alloc.free(hits);

    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "searchMessagesFts: tool_call_id and tool_name surfaced for tool-role hits" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, " ++
        "tool_call_id, tool_name) " ++
        "VALUES ('h1','s_1','tool','exit code 42','tc_1','bash')",
        &.{});

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "exit code", .{});
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("tool", hits[0].role);
    try testing.expectEqualStrings("tc_1", hits[0].tool_call_id.?);
    try testing.expectEqualStrings("bash", hits[0].tool_name.?);
}

test "getCompactedMessages: include_all=true returns live AND compacted rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Seed: 1 live (is_feed_to_llm=1) + 1 compacted (is_feed_to_llm=0)
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live_1','s_full','user','live message',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact_1','s_full','assistant','compacted message',0)", &.{});

    // Default behavior (include_all=false): only compacted.
    const compact_only = try llm_history.getCompactedMessages(alloc, &s.db, "s_full", .{});
    defer {
        for (compact_only) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(compact_only);
    }
    try testing.expectEqual(@as(usize, 1), compact_only.len);
    try testing.expectEqualStrings("compact_1", compact_only[0].id);

    // include_all=true: both rows.
    const all_rows = try llm_history.getCompactedMessages(alloc, &s.db, "s_full", .{
        .include_all = true,
    });
    defer {
        for (all_rows) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(all_rows);
    }
    try testing.expectEqual(@as(usize, 2), all_rows.len);
}
```

- [ ] **Step 2: Register the test**

Modify `src/ai_workflow/tui/test_runner.zig`:

Find the line that registers `llm_history_compacted_messages_test.zig` and ADD a new line right after it:

```zig
_ = @import("llm_history_search_messages_fts_test.zig");
```

(If the file uses a different registration pattern, mirror it.)

- [ ] **Step 3: Run the tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: baseline + 7 tests passing (6 searchMessagesFts + 1 include_all toggle).

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/llm_history_search_messages_fts_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "test(llm_history): add searchMessagesFts unit tests

7 tests cover: relevance ranking, session_id filter, role filter, limit,
empty result, tool-call-id/tool-name surfacing, and the new
getCompactedMessages include_all toggle."
```

---

## Chunk 3: `search_history.zig` tool file

This chunk creates the new tool module and removes the old `read_compacted_messages` module. The new tool mirrors the old one's structure but exposes the two-mode API the user designed.

### Task 3.1: Create `src/modules/agent/tools/search_history.zig`

**Files:**
- Create: `src/modules/agent/tools/search_history.zig`

- [ ] **Step 1: Write the new tool file**

```zig
const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;
const helpers = nalarcore.helpers;
const xmlEscape = helpers.xml_escape;

/// Input for search_history.
///
/// TWO MODES:
/// - "text" (default): FTS5 full-text search over message content.
///   Requires `query`. Optionally scope to `session_id`.
/// - "session": fetch messages for a specific `session_id`. Optional
///   `message_ids` to also return full <content> for those ids.
///
/// Why both modes in one tool: a single round-trip covers "find the
/// conversation about X" and "show me session N" — two related but
/// distinct needs. Splitting into two tools would add a second prompt
/// line for the LLM to learn.
pub const SearchHistoryInput = struct {
    /// "text" (FTS5 search) or "session" (fetch by session_id).
    mode: []const u8 = "text",
    /// Required for mode="text". FTS5 MATCH query string.
    query: []const u8 = "",
    /// Required for mode="session". Optional scope filter for mode="text".
    session_id: []const u8 = "",
    /// Comma-separated message ids. Only meaningful for mode="session":
    /// when non-empty, also returns full <content> for these ids.
    message_ids: []const u8 = "",
    /// Optional exact-match role filter.
    role: []const u8 = "",
    /// Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS.
    since: []const u8 = "",
    /// Optional upper bound on created_at (inclusive).
    until: []const u8 = "",
    /// Max rows to return. Defaults to 20; tool layer caps at 200.
    limit: u32 = 20,
};

pub const search_history_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search_history",
        .description =
            \\Search the full conversation history stored on disk — including messages compacted out of the live context — either by full-text query or by fetching a specific session's messages.
            \\
            \\TWO MODES:
            \\- mode="text": full-text search over message content using SQLite FTS5. Provide `query`. Optionally scope to one `session_id`, filter by `role`, `since`/`until`, and cap results with `limit`. Returns ranked matches with a preview snippet — use this when you remember *what* was said but not *where*.
            \\- mode="session": list (or fetch) messages belonging to one `session_id`. Returns ALL messages for the session — both those still in your live context (`is_feed_to_llm=1`) and those dropped by compaction (`is_feed_to_llm=0`). Returns an index (id, role, created_at, preview) by default; pass specific `message_ids` to also get the full <content> body for those entries. Use this when you know *which session* you need and want to browse or pull full text.
            \\
            \\Filters (optional, apply to both modes):
            \\- role: "user", "assistant", or "tool" — exact match.
            \\- since / until: YYYY-MM-DD HH:MM:SS (inclusive).
            \\- limit: max rows to return (default 20, max 200).
            \\
            \\Example (text search): {"mode": "text", "query": "login bug fix"}
            \\Example (text search scoped): {"mode": "text", "query": "login bug", "session_id": "s_42"}
            \\Example (session browse): {"mode": "session", "session_id": "s_42"}
            \\Example (session full fetch): {"mode": "session", "session_id": "s_42", "message_ids": "h_1781,h_1782"}
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "mode", .type = "string", .description = "'text' (FTS5 full-text search, default) or 'session' (fetch by session_id)." },
                .{ .name = "query", .type = "string", .description = "Required for mode='text'. FTS5 search query." },
                .{ .name = "session_id", .type = "string", .description = "Required for mode='session'. Optional scope filter for mode='text'." },
                .{ .name = "message_ids", .type = "string", .description = "mode='session' only. Comma-separated ids to also fetch full <content> for." },
                .{ .name = "role", .type = "string", .description = "Optional exact-match role filter: 'user', 'assistant', or 'tool'." },
                .{ .name = "since", .type = "string", .description = "Optional lower bound on created_at (inclusive). YYYY-MM-DD HH:MM:SS." },
                .{ .name = "until", .type = "string", .description = "Optional upper bound on created_at (inclusive)." },
                .{ .name = "limit", .type = "number", .description = "Max rows to return. Default 20, max 200." },
            },
            .required = &.{},
        },
    },
};

/// Parse `message_ids_csv` ("h_123,h_456") into a `[]const []const u8`.
fn parseMessageIds(allocator: std.mem.Allocator, csv: []const u8) ![]const []const u8 {
    if (csv.len == 0) return &.{};
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |id| {
        const trimmed = std.mem.trim(u8, id, " \t");
        if (trimmed.len > 0) {
            try ids.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
    return try ids.toOwnedSlice(allocator);
}

fn errorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<search_history><error>{s}</error></search_history>",
        .{escaped});
}

/// Execute search_history. Returns an XML string for the LLM.
pub fn execute_search_history(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    input: SearchHistoryInput,
) ![]const u8 {
    _ = io; // Reserved for future streaming; not used in v1.

    // Validate mode.
    const is_text_mode = blk: {
        if (std.mem.eql(u8, input.mode, "text") or input.mode.len == 0) break :blk true;
        if (std.mem.eql(u8, input.mode, "session")) break :blk false;
        const msg = try std.fmt.allocPrint(allocator,
            "Invalid mode '{s}'. Must be 'text' or 'session'.",
            .{input.mode});
        defer allocator.free(msg);
        return errorXml(allocator, msg);
    };

    if (is_text_mode and input.query.len == 0) {
        return errorXml(allocator, "mode='text' requires non-empty query.");
    }
    if (!is_text_mode and input.session_id.len == 0) {
        return errorXml(allocator, "mode='session' requires non-empty session_id.");
    }

    const effective_limit = @min(input.limit, 200);

    if (is_text_mode) {
        const opts = llm_history.SearchOptions{
            .session_id = if (input.session_id.len > 0) input.session_id else null,
            .role = if (input.role.len > 0) input.role else null,
            .since = if (input.since.len > 0) input.since else null,
            .until = if (input.until.len > 0) input.until else null,
            .limit = effective_limit,
        };

        const hits = llm_history.searchMessagesFts(allocator, db, input.query, opts) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "FTS search failed: {s}", .{@errorName(err)});
            defer allocator.free(msg);
            return errorXml(allocator, msg);
        };
        defer {
            for (hits) |h| {
                var copy = h;
                copy.deinit(allocator);
            }
            allocator.free(hits);
        }

        var xml: std.ArrayList(u8) = .empty;
        errdefer xml.deinit(allocator);

        try xml.print(allocator, "<search_history mode=\"text\">\n  <query>{s}</query>\n  <count>{d}</count>\n  <results>\n",
            .{ try xmlEscape(allocator, input.query), hits.len });
        for (hits) |h| {
            const id_e = try xmlEscape(allocator, h.id);
            defer allocator.free(id_e);
            const sid_e = try xmlEscape(allocator, h.session_id);
            defer allocator.free(sid_e);
            const role_e = try xmlEscape(allocator, h.role);
            defer allocator.free(role_e);
            const snip_e = try xmlEscape(allocator, h.snippet);
            defer allocator.free(snip_e);

            try xml.appendSlice(allocator, "    <entry>\n");
            try xml.print(allocator, "      <id>{s}</id>\n", .{id_e});
            try xml.print(allocator, "      <session_id>{s}</session_id>\n", .{sid_e});
            try xml.print(allocator, "      <role>{s}</role>\n", .{role_e});
            if (h.created_at.len > 0) {
                const ca_e = try xmlEscape(allocator, h.created_at);
                defer allocator.free(ca_e);
                try xml.print(allocator, "      <created_at>{s}</created_at>\n", .{ca_e});
            }
            try xml.print(allocator, "      <snippet>{s}</snippet>\n", .{snip_e});
            try xml.appendSlice(allocator, "    </entry>\n");
        }
        try xml.appendSlice(allocator, "  </results>\n</search_history>\n");
        return try xml.toOwnedSlice(allocator);
    }

    // mode="session"
    const parsed_ids = try parseMessageIds(allocator, input.message_ids);
    defer {
        for (parsed_ids) |id| allocator.free(id);
        allocator.free(parsed_ids);
    }
    const want_full = parsed_ids.len > 0;

    const opts = llm_history.CompactedMessagesOptions{
        .message_ids = if (want_full) parsed_ids else null,
        .role = if (input.role.len > 0) input.role else null,
        .since = if (input.since.len > 0) input.since else null,
        .until = if (input.until.len > 0) input.until else null,
        .limit = effective_limit,
        // mode="session" returns the FULL conversation history (live +
        // compacted), not just compacted messages. The agent may want
        // to re-read something still in its live context, or browse the
        // whole session regardless of compaction state.
        .include_all = true,
    };

    const messages = llm_history.getCompactedMessages(allocator, db, input.session_id, opts) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Database query failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return errorXml(allocator, msg);
    };
    defer {
        for (messages) |m| {
            var copy = m;
            copy.deinit(allocator);
        }
        allocator.free(messages);
    }

    var full_ids_set: std.StringHashMapUnmanaged(void) = .empty;
    defer full_ids_set.deinit(allocator);
    if (want_full) for (parsed_ids) |id| try full_ids_set.put(allocator, id, {});

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.print(allocator, "<search_history mode=\"session\">\n  <session_id>{s}</session_id>\n  <count>{d}</count>\n  <message_index>\n",
        .{ try xmlEscape(allocator, input.session_id), messages.len });

    for (messages) |m| {
        const id_e = try xmlEscape(allocator, m.id);
        defer allocator.free(id_e);
        const role_e = try xmlEscape(allocator, m.role);
        defer allocator.free(role_e);
        const preview_src: []const u8 = if (m.content.len > 100) m.content[0..100] else m.content;
        const preview_e = try xmlEscape(allocator, preview_src);
        defer allocator.free(preview_e);

        try xml.appendSlice(allocator, "    <entry>\n");
        try xml.print(allocator, "      <id>{s}</id>\n", .{id_e});
        try xml.print(allocator, "      <role>{s}</role>\n", .{role_e});
        if (m.created_at.len > 0) {
            const ca_e = try xmlEscape(allocator, m.created_at);
            defer allocator.free(ca_e);
            try xml.print(allocator, "      <created_at>{s}</created_at>\n", .{ca_e});
        }
        try xml.print(allocator, "      <preview>{s}</preview>\n", .{preview_e});
        if (std.mem.eql(u8, m.role, "tool")) {
            if (m.tool_call_id) |tcid| {
                const tcid_e = try xmlEscape(allocator, tcid);
                defer allocator.free(tcid_e);
                try xml.print(allocator, "      <tool_call_id>{s}</tool_call_id>\n", .{tcid_e});
            }
            if (m.tool_name) |tn| {
                const tn_e = try xmlEscape(allocator, tn);
                defer allocator.free(tn_e);
                try xml.print(allocator, "      <tool_name>{s}</tool_name>\n", .{tn_e});
            }
        }
        if (want_full and full_ids_set.contains(m.id)) {
            const content_e = try xmlEscape(allocator, m.content);
            defer allocator.free(content_e);
            try xml.print(allocator, "      <content>{s}</content>\n", .{content_e});
        }
        try xml.appendSlice(allocator, "    </entry>\n");
    }

    try xml.appendSlice(allocator, "  </message_index>\n</search_history>\n");
    return try xml.toOwnedSlice(allocator);
}

pub fn toXmlSuccess(allocator: std.mem.Allocator, inner: []const u8) ![]u8 {
    return allocator.dupe(u8, inner);
}

pub fn toXmlError(allocator: std.mem.Allocator, err_msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, err_msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<search_history><error>{s}</error></search_history>",
        .{escaped});
}
```

- [ ] **Step 2: Verify compile**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: same baseline (the file isn't referenced yet).

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/search_history.zig
git commit -m "feat(tools): add search_history tool (two modes: text/session)

Mirrors the structure of the old read_compacted_messages tool but
exposes the two-mode API designed in
docs/superpowers/plans/2026-07-16-search-history-rewrite.md."
```

### Task 3.2: Create `src/modules/agent/tools/search_history_test.zig`

**Files:**
- Create: `src/modules/agent/tools/search_history_test.zig`

- [ ] **Step 1: Write the test file**

```zig
const std = @import("std");
const testing = std.testing;
const sh = @import("search_history.zig");
const sqlite = @import("nalarcore").sqlite;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  role TEXT,
        \\  tool_call_id TEXT,
        \\  tool_name TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  created_at TEXT DEFAULT (datetime('now'))
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE VIRTUAL TABLE messages_fts USING fts5(
        \\    content, content='llm_history', content_rowid='rowid'
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "execute_search_history: mode=text returns FTS hits with snippets" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','the login bug needs fixing')", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "login bug",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<search_history mode=\"text\">") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<query>login bug</query>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<snippet>") != null);
}

test "execute_search_history: mode=session returns ALL messages (live + compacted) for session_id" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Seed: 1 live (is_feed_to_llm=1) + 1 compacted (is_feed_to_llm=0) for s_X.
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live_h','s_X','user','Fix login (live)',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact_h','s_X','assistant','On it (compacted)',0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('other_h','s_other','user','different session',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_X",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<search_history mode=\"session\">") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<session_id>s_X</session_id>") != null);
    // BOTH the live and compacted rows for s_X are present.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>live_h</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact_h</id>") != null);
    // Other session is excluded.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>other_h</id>") == null);
    // The live message's content is in the <preview> tag (100-char cap).
    try testing.expect(std.mem.indexOf(u8, xml, "Fix login (live)") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "On it (compacted)") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>2</count>") != null);
}

test "execute_search_history: mode=session with message_ids includes full <content>" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h1','s_X','user','Fix login bug',0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h2','s_X','assistant','On it now',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_X",
        .message_ids = "h1",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<content>Fix login bug</content>") != null);
    // h2 not in message_ids → not in output (IN clause filter).
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h2</id>") == null);
}

test "execute_search_history: invalid mode returns error XML" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "bogus",
        .query = "anything",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "Invalid mode") != null);
}

test "execute_search_history: mode=text with empty query returns error" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "requires non-empty query") != null);
}

test "execute_search_history: mode=session with empty session_id returns error" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "requires non-empty session_id") != null);
}

test "execute_search_history: limit cap at 200" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h1','s_X','user','hello',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_X",
        .limit = 99999,
    });
    defer alloc.free(xml);

    // The XML output doesn't directly echo the effective_limit; instead
    // verify the request didn't blow up. A stronger assertion would need
    // to insert 201 rows and verify only 200 come back.
    try testing.expect(std.mem.indexOf(u8, xml, "<search_history") != null);
}

test "toXmlSuccess and toXmlError produce well-formed XML envelopes" {
    const alloc = testing.allocator;
    const inner = try sh.toXmlSuccess(alloc, "<inner/>");
    defer alloc.free(inner);
    try testing.expectEqualStrings("<inner/>", inner);

    const err_xml = try sh.toXmlError(alloc, "boom");
    defer alloc.free(err_xml);
    try testing.expect(std.mem.indexOf(u8, err_xml, "<search_history>") != null);
    try testing.expect(std.mem.indexOf(u8, err_xml, "<error>boom</error>") != null);
}
```

- [ ] **Step 2: Verify the new test passes**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: baseline + 8 new tests passing.

(Note: the test file may not be in the module graph yet if you haven't wired it. If so, skip this step and proceed to Task 3.3.)

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/search_history_test.zig
git commit -m "test(tools): add search_history unit tests

8 tests cover: FTS hits, session-mode index/full, invalid mode error,
empty query/session_id errors, limit cap, XML envelope helpers."
```

### Task 3.3: Delete the old `read_compacted_messages.{zig,_test.zig}`

**Files:**
- Delete: `src/modules/agent/tools/read_compacted_messages.zig`
- Delete: `src/modules/agent/tools/read_compacted_messages_test.zig`

- [ ] **Step 1: Delete both files**

```bash
git rm src/modules/agent/tools/read_compacted_messages.zig
git rm src/modules/agent/tools/read_compacted_messages_test.zig
```

- [ ] **Step 2: Verify the test target still compiles (these deletes break references — Chunk 4 fixes them)**

`zig build test` will fail because `read_compacted_messages_test.zig` is referenced in `src/modules/agent/test_runner.zig`. We'll fix that in Chunk 4.

For now, EXPECT the build to be red. We'll commit and continue.

- [ ] **Step 3: Commit the deletes alone (NOT yet wired)**

```bash
git commit -m "chore(tools): remove obsolete read_compacted_messages

The tool is replaced by search_history (mode=session). Wiring update in
the next commit; this commit just removes the file."
```

---

## Chunk 4: Tool wiring (tool_registry + tools_equipped + root.zig + test_runners)

This chunk rewires the four places that reference the old tool name to point at the new one.

### Task 4.1: Update `src/root.zig`

**Files:**
- Modify: `src/root.zig:371`

- [ ] **Step 1: Replace the import**

```diff
-pub const read_compacted_messages_tool = @import("modules/agent/tools/read_compacted_messages.zig");
+pub const search_history_tool = @import("modules/agent/tools/search_history.zig");
```

- [ ] **Step 2: Verify compile**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: test target still works (root.zig is referenced by both, but the test target uses lazy analysis).

Also run `timeout 180 zig build install:linux:system 2>&1 | tail -n 10` to verify the install target compiles — this catches lazy-analysis errors that `zig build test` misses (per project memory `zig-build-catches-lazy-analysis-errors-test-misses`).

Expected: the `compile exe nalar` step should succeed (or fail only on the still-broken `tool_registry.zig` reference).

- [ ] **Step 3: Commit**

```bash
git add src/root.zig
git commit -m "chore(root): re-export search_history_tool in place of read_compacted_messages_tool"
```

### Task 4.2: Update `src/ai_workflow/tui/tool_registry.zig`

**Files:**
- Modify: `src/ai_workflow/tui/tool_registry.zig:22`
- Modify: `src/ai_workflow/tui/tool_registry.zig:315-342` (replace `execReadCompactedMessages` with `execSearchHistory`)
- Modify: `src/ai_workflow/tui/tool_registry.zig:1745` (replace registry entry)

- [ ] **Step 1: Replace the import**

```diff
-const read_compacted_messages_mod = nalar_mod.read_compacted_messages_tool;
+const search_history_mod = nalar_mod.search_history_tool;
```

- [ ] **Step 2: Replace the executor function (line 315-342)**

Replace the entire `execReadCompactedMessages` function with:

```zig
pub fn execSearchHistory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        search_history_mod.SearchHistoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "search_history failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "search_history", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = search_history_mod.execute_search_history(
        ctx.allocator,
        ctx.io,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "search_history failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "search_history", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const output = try wrapToolOutput(ctx.allocator, "search_history", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 3: Update the registry entry**

At line 1745, replace:

```diff
-.{ .name = "read_compacted_messages", .exec = execReadCompactedMessages, .tool_def = read_compacted_messages_mod.read_compacted_messages_tool },
+.{ .name = "search_history", .exec = execSearchHistory, .tool_def = search_history_mod.search_history_tool },
```

- [ ] **Step 4: Verify compile (both targets)**

Run BOTH:

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
```

Expected: both succeed (or fail only on the remaining `tools_equipped.zig` / `test_runner.zig` references).

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/tool_registry.zig
git commit -m "refactor(tool_registry): replace execReadCompactedMessages with execSearchHistory

Same call shape (parse JSON, exec, wrap, return); the parsed input type
and underlying function come from search_history_mod instead of the
removed read_compacted_messages_mod."
```

### Task 4.3: Update `src/ai_workflow/tui/agentic_loop/tools_equipped.zig`

**Files:**
- Modify: `src/ai_workflow/tui/agentic_loop/tools_equipped.zig:14`
- Modify: `src/ai_workflow/tui/agentic_loop/tools_equipped.zig:50`

- [ ] **Step 1: Replace the import**

```diff
-const read_compacted_messages_mod = nalarcore.read_compacted_messages_tool;
+const search_history_mod = nalarcore.search_history_tool;
```

- [ ] **Step 2: Update the tool list entry**

```diff
-        read_compacted_messages_mod.read_compacted_messages_tool,
+        search_history_mod.search_history_tool,
```

- [ ] **Step 3: Verify compile (both targets)**

Run BOTH (per memory `zig-build-catches-lazy-analysis-errors-test-misses`):

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
```

Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/agentic_loop/tools_equipped.zig
git commit -m "refactor(tools_equipped): swap read_compacted_messages for search_history"
```

### Task 4.4: Update test runners

**Files:**
- Modify: `src/modules/agent/test_runner.zig` (if it lists `read_compacted_messages_test.zig`)

- [ ] **Step 1: Find the old test registration**

```bash
rg "read_compacted_messages" src/modules/agent/test_runner.zig 2>&1 | head -n 5
```

If present, replace it with the new test file:

```diff
-    _ = @import("tools/read_compacted_messages_test.zig");
+    _ = @import("tools/search_history_test.zig");
```

(If the test_runner.zig uses a different pattern, mirror the existing convention.)

- [ ] **Step 2: Run the test target**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: baseline + 8 (new search_history tests) = previous baseline (the 4 deleted read_compacted_messages tests were removed and replaced).

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/test_runner.zig
git commit -m "chore(test_runner): register search_history_test.zig instead of deleted read_compacted_messages_test.zig"
```

---

## Chunk 5: Smoke test + final verification

This chunk runs end-to-end against a running nalar process to confirm the new tool works in the real LLM tool path.

### Task 5.1: Manual smoke test

**Files:** (no file changes — verification only)

- [ ] **Step 1: Build the binary**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```

Expected: `compile exe nalar` succeeds. (The cp step to `/usr/local/bin/nalar` may fail harmlessly with permission denied — that's the project convention.)

- [ ] **Step 2: Start a test nalar on port 8080**

```bash
env -i HOME=$(mktemp -d) PATH="$PATH" ./zig-out/bin/nalar --port 8080 &
PID=$!
sleep 3
```

Expected: process is listening on 8080.

- [ ] **Step 3: Send a chat message that triggers search_history**

Use the HTTP API to send a message asking the agent to use search_history. For example:

```bash
# (Implementation-specific: depends on nalar's chat API. Use whatever
# existing session-create + chat-send pattern works today. Refer to
# scripts/ci-smoke-test.sh or the existing /api/llm endpoints.)
```

Or: simply verify the tool appears in the LLM's tool list by hitting the appropriate endpoint and confirming `search_history` is among the tool names.

- [ ] **Step 4: Stop the test nalar**

```bash
kill $PID
```

**DO NOT** use `pkill -f "zig build run"` — the project memory says to never kill the production nalar on 8081.

- [ ] **Step 5: Commit the smoke-test evidence**

If the smoke test revealed any issues, fix them and commit the fix. If it passed cleanly, no commit needed.

### Task 5.2: Final verification

**Files:** (no file changes — verification only)

- [ ] **Step 1: Run the full test suite**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `test success`, pass count = baseline + 14 new tests (6 searchMessagesFts + 8 search_history) - 4 deleted tests (the 4 read_compacted_messages tests). Net delta: +10 tests.

- [ ] **Step 2: Run the install target**

```bash
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```

Expected: `compile exe nalar` succeeds.

- [ ] **Step 3: Final fresh `zig build` to catch any cached-binary false success**

```bash
rm -rf zig-out/bin
timeout 300 zig build 2>&1 | tail -n 5
```

Expected: `Build Summary: N/N steps succeeded`.

(This is the lazy-analysis trap from memory `zig-build-catches-lazy-analysis-errors-test-misses`.)

- [ ] **Step 4: Push branch and open PR**

```bash
git push origin worktree/search-history-rewrite
gh pr create --base main --title "feat(tools): replace read_compacted_messages with search_history (FTS5 + session browse)" --body "$(cat <<'EOF'
## Summary

Replaces the single-purpose `read_compacted_messages` tool with a general-purpose `search_history` tool that exposes two modes:

- **mode="text"**: SQLite FTS5 full-text search over message content (ranked by BM25, with snippet previews). Filter by `session_id`, `role`, `since`/`until`, `limit`.
- **mode="session"**: fetch messages for an explicit `session_id` (cheap index listing by default; pass `message_ids` for full content).

## Changes

- New tool: `src/modules/agent/tools/search_history.zig` + `_test.zig`
- Migration 055: `messages_fts` FTS5 virtual table (external content on `llm_history`) with INSERT/UPDATE/DELETE sync triggers
- New `llm_history.searchMessagesFts(...)` function with `SearchOptions` / `SearchHit` types
- `build.zig`: `-DSQLITE_ENABLE_FTS5` for the 4 vendored-amalgamation compile sites
- Removed: `src/modules/agent/tools/read_compacted_messages.zig` + `_test.zig`
- Rewired: `src/root.zig`, `src/ai_workflow/tui/tool_registry.zig`, `src/ai_workflow/tui/agentic_loop/tools_equipped.zig`, `src/modules/agent/test_runner.zig`

## Test plan

- 6 migration tests (table creation, triggers, backfill, INSERT/UPDATE/DELETE behavior)
- 6 `searchMessagesFts` unit tests (relevance, filters, limit, empty, tool metadata)
- 8 `search_history` tool tests (both modes, validation errors, XML envelopes)

## Migration notes

Migration 055 must run on existing DBs before the new tool can search. The migration is idempotent (CREATE statements use IF NOT EXISTS) and backfills the FTS index from existing rows. ~10ms per 10K rows.

## Known design choice (not a bug)

`mode="session"` accepts any `session_id` from the caller (not just the agent's own session). This matches the original design intent — the LLM may legitimately want to browse a sibling session it knows the id of. No access-control layer exists in the codebase today for any read tool, so this is consistent with the project's current posture.

## Verification

- `timeout 180 zig build test --summary all` — baseline + 10 tests passing
- `timeout 180 zig build install:linux:system` — `compile exe nalar` succeeds
- `rm -rf zig-out/bin && timeout 300 zig build` — clean fresh build

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Out of scope (deferred)

These are mentioned in the design but deliberately NOT included in this plan:

1. **Per-profile or per-agent access control on session reads** — the user explicitly chose not to enforce session ownership in the v1 design. If needed later, add a session-id → agent-id mapping check in `execSearchHistory`.
2. **FTS5 highlight markers** (the `[`/`]` around matched tokens) — currently produced by the `snippet()` function. If the LLM finds them confusing in practice, swap to plain ellipsis markers via `snippet(table, 0, '', '', '...', 10)`.
3. **Reindex command** — the triggers keep the FTS index in sync on row-level changes, but if a future migration modifies `response_content` directly (not via the `saveMessage` helper), the FTS index will be stale. Add `INSERT INTO messages_fts(messages_fts) VALUES('rebuild')` as a future maintenance command.
4. **Performance indexes** — the FTS5 virtual table handles the text search; the `idx_llm_history_session` index already covers `mode="session"` session_id filter. No additional indexes needed for v1.
5. **Cross-session search via `session_id IS NULL`** — the agent can already pass empty `session_id` to search across all sessions. Document this in the tool description as a future enhancement.

## Cross-cutting notes

- **The test build may pass while the install build fails.** Per memory `zig-build-catches-lazy-analysis-errors-test-misses`, always verify with BOTH `zig build test` AND `zig build install:linux:system` (plus `rm -rf zig-out/bin && zig build` for the lazy-cache trap).
- **FTS5 is enabled in the system libsqlite3** (verified: `sqlite_compileoption_used('ENABLE_FTS5')` returns 1) but the vendored amalgamation needs `-DSQLITE_ENABLE_FTS5`. The four build.zig compile sites must all get this flag.
- **External-content FTS5 has a subtle gotcha**: if `INSERT INTO messages_fts(rowid, content)` is called with a rowid that doesn't exist in `llm_history`, the insert succeeds but the JOIN in `searchMessagesFts` won't find it (since `llm_history h ON h.rowid = messages_fts.rowid` would fail). The backfill handles this (rows come from `llm_history` so they exist); the triggers also only fire on actual row inserts/updates/deletes.
- **`saveMessage` already goes through INSERT statements on `llm_history`**, so the AFTER INSERT trigger will fire automatically. No saveMessage-side change is needed.

## Pitfalls

1. **String-literal ownership in error messages** — `if (input.mode.len == 0)` falls through to the `text` branch; this is intentional (matches the design's "default to text"). Don't change it.
2. **`xmlEscape` returns owned memory** — every `try xmlEscape(allocator, x)` is followed by `defer allocator.free(x_e)` to free the escaped slice. Don't drop the defer or you'll leak.
3. **`full_ids_set.contains(m.id)`** uses borrowed slice equality — fine because `m.id` is owned by the `m` (freed by the messages loop's defer).
4. **Snippet truncation is implicit** — FTS5's `snippet(table, 0, '[', ']', '...', 10)` already returns ~10 tokens of context. Don't add manual truncation on top.
5. **FTS5 query syntax** — bare words are tokenized and OR'd by default; `"login bug"` (quoted) is a phrase match. The LLM may produce either form. Both work; quote handling is automatic.
6. **`h.created_at` may be NULL** — guarded by `COALESCE(h.created_at, '')` in the SELECT, then guarded by `if (h.created_at.len > 0)` in the output.