# Fix Anthropic Total Tokens — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Anthropic `total_tokens` (and `prompt_tokens`) match OpenAI's semantics — include `cache_read_input_tokens` as processed tokens (still billable at a discounted rate, but still tokens). Cache breakdown stays available on `Usage` for future billing.

**Architecture:** Extend the existing `Usage` struct with 2 optional fields (`cache_creation_input_tokens`, `cache_read_input_tokens`); switch the Anthropic SSE parser's `message_delta` formula from `input + cache_creation + output` to `input + cache_creation + cache_read + output`. Add Migration 074 to persist the cache breakdown on `llm_history`. Wire the 2 new fields through 4 call sites (`saveMessage`, `insertLLMHistories`, `LLMHistory` row struct, `callDynamicAgentNew` return path). Cost-log fix is explicitly out of scope (user-confirmed follow-up).

**Tech Stack:** Zig 0.16, SQLite (via `databases` package), Vue/TS frontend unchanged, Anthropic SSE parser already in `Agent.zig:1489`.

**Spec:** `docs/superpowers/specs/2026-08-13-fix-anthropic-total-tokens-design.md`

## Global Constraints

- **Backward compatible.** OpenAI profiles are byte-for-byte unchanged at the `Usage` and DB level — new fields default to 0.
- **No wire-shape change.** Anthropic HTTP request body unchanged. SSE parser only grows (3 more integer reads).
- **No new error variants.**
- **Pure Zig change** — Linux/macOS/Windows compile + test must all pass.
- **Migration 074 is idempotent** (per project-wide `migration-is-idempotent` invariant).
- **Cost log formula at `Agent.zig:2014-2016` is NOT changed in this PR.** Comment gets updated to warn future readers; pricing changes ship as follow-up.
- **TDD:** Every code change has a failing test written before the implementation patch, verified to fail, then made to pass.

---

## Task 1: Extend `Agent.Usage` struct with 2 cache fields (no behaviour change yet)

**File:** `src/modules/agent/Agent.zig` (modify `pub const Usage = struct {…}` at L616-620)

**Why first:** Every other change is downstream of this struct shape. Doing it in isolation lets the rest of the patch keep the new fields explicitly typed.

**Step 1.1:** Write the structural-contract test.

**File:** `src/modules/agent/parse_anthropic_sse_test.zig` (append; don't break existing tests)

Add after the existing test block:

```zig
test "Agent.Usage struct has cache_creation_input_tokens + cache_read_input_tokens fields (structural contract)" {
    const T = struct {
        fn expectType(comptime _: @TypeOf(@as(agent.Usage, undefined).cache_creation_input_tokens)) void {}
    };
    T.expectType(0); // type must exist and be coercible from integer literal 0
    // Default-initialized Usage has the 2 cache fields = 0 (open paths).
    const u: agent.Usage = .{};
    try expectEqual(@as(usize, 0), u.cache_creation_input_tokens);
    try expectEqual(@as(usize, 0), u.cache_read_input_tokens);
    // Existing fields still work.
    try expectEqual(@as(usize, 0), u.prompt_tokens);
    try expectEqual(@as(usize, 0), u.completion_tokens);
    try expectEqual(@as(usize, 0), u.total_tokens);
}
```

(Use `expectEqual = std.testing.expectEqual` already imported at the top of the file.)

**Step 1.2:** Run the test, confirm it FAILS.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg -A 5 "Agent.Usage struct has cache_creation|cache_creation_input_tokens"
```

Expected: compile error on `cache_creation_input_tokens` does not exist on `Usage`. That's the failure mode we want — proves the contract is not yet met.

**Step 1.3:** Extend `Usage`.

**File:** `src/modules/agent/Agent.zig`, replace L616-620:

```zig
pub const Usage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
    /// Anthropic-only: tokens used to write a cache entry on this call.
    /// Billed at the cache-write rate (typically ~1.25× input rate), so
    /// DO add this to any billing formula. 0 for non-Anthropic profiles.
    cache_creation_input_tokens: usize = 0,
    /// Anthropic-only: tokens read from a cache entry on this call.
    /// Billed at the cache-read rate (typically ~0.1× input rate) — but
    /// still tokens the model processed, so this IS included in
    /// `prompt_tokens` and `total_tokens` (matching OpenAI's semantic
    /// of "tokens the LLM saw"). 0 for non-Anthropic profiles.
    cache_read_input_tokens: usize = 0,
};
```

**Step 1.4:** Run the test, confirm it PASSES.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg "Agent.Usage struct has cache_creation"
```

Expected: 1 of 1 passing. (Other tests may also pass since the default-0 fields don't break the OpenAI path.)

**Step 1.5:** Commit.

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/modules/agent/Agent.zig src/modules/agent/parse_anthropic_sse_test.zig
git commit -m "feat(agent): extend Usage with cache_creation + cache_read input token fields"
```

---

## Task 2: Anthropic SSE parser — include cache_read in prompt_tokens + total_tokens

**File:** `src/modules/agent/Agent.zig` (modify `parse_anthropic_stream_chunk` at L1489-1658)

**Why second:** This is the actual behaviour change. Once the fields exist (Task 1), the parser is the only code that needs updating to make the totals correct.

**Step 2.1:** Write the failing tests.

**File:** `src/modules/agent/parse_anthropic_sse_test.zig` (append after the Task 1 test)

```zig
test "parse_stream_chunk (anthropic): message_delta includes BOTH cache_creation AND cache_read in prompt + total" {
    // Reproduces the spec TL;DR example:
    // input=1000 + cache_creation=500 + cache_read=5000 + output=1000
    // expected: prompt = 6500, completion = 1000, total = 7500
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start caches input_tokens=1000.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1000,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // message_delta: cache_creation=500, cache_read=5000, output=1000.
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":5000,"output_tokens":1000}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expect(chunk.?.usage != null);
    try expectEqual(@as(usize, 6500), chunk.?.usage.?.prompt_tokens);
    try expectEqual(@as(usize, 1000), chunk.?.usage.?.completion_tokens);
    try expectEqual(@as(usize, 7500), chunk.?.usage.?.total_tokens);
    try expectEqual(@as(usize, 500), chunk.?.usage.?.cache_creation_input_tokens);
    try expectEqual(@as(usize, 5000), chunk.?.usage.?.cache_read_input_tokens);
}

test "parse_stream_chunk (anthropic): cache_creation + cache_read are surfaced to Usage" {
    // The cache fields on Usage are populated whenever message_delta carries
    // them, even if they're zero. (Mirrors the OpenAI path's prompt_tokens
    // always being populated.)
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    // Cache reads ONLY (no cache writes) → prompt = input + cache_read.
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":10,"cache_read_input_tokens":128,"output_tokens":7}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expect(chunk.?.usage != null);
    try expectEqual(@as(usize, 138), chunk.?.usage.?.prompt_tokens); // 10 + 128
    try expectEqual(@as(usize, 7), chunk.?.usage.?.completion_tokens);
    try expectEqual(@as(usize, 145), chunk.?.usage.?.total_tokens);
    try expectEqual(@as(usize, 0), chunk.?.usage.?.cache_creation_input_tokens);
    try expectEqual(@as(usize, 128), chunk.?.usage.?.cache_read_input_tokens);
}
```

**Step 2.2:** Run the new tests; confirm BOTH fail (with the current `cache_read_tokens` dropped on the floor).

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg "message_delta includes BOTH|cache_creation + cache_read are surfaced"
```

Expected: each test fails because the chunk.usage?.prompt_tokens is currently `input + cache_creation` (not including cache_read).

**Step 2.3:** Update `parse_anthropic_stream_chunk` in `Agent.zig`.

Two surgical edits, both in the function at L1489-1658:

(a) `message_start` branch (around L1512-1523). Add `cache_read_input_tokens` parsing alongside `input_tokens`:

```zig
if (std.mem.eql(u8, event_type, "message_start")) {
    // Cache input_tokens from message.message.usage.input_tokens.
    // Emit no chunk — the first delta will carry the usage.
    const message = root.object.get("message") orelse return null;
    if (message != .object) return null;
    const usage = message.object.get("usage") orelse return null;
    if (usage != .object) return null;
    if (usage.object.get("input_tokens")) |it| {
        if (it == .integer) self._anthropic_input_tokens = @intCast(it.integer);
    }
    // Some relays send `cache_read_input_tokens` at message_start but not
    // at message_delta — keep it around so the first-delta usage chunk can
    // include it.
    if (usage.object.get("cache_read_input_tokens")) |cr| {
        if (cr == .integer) self._anthropic_cache_read_tokens = @intCast(cr.integer);
    }
    if (usage.object.get("cache_creation_input_tokens")) |cc| {
        if (cc == .integer) self._anthropic_cache_creation_tokens = @intCast(cc.integer);
    }
    return null;
}
```

(b) Add 2 new per-call fields on `Agent` (next to the existing
`_anthropic_input_tokens` at L864-873):

```zig
/// Anthropic-only: cached cache_read_input_tokens from message_start.
/// Used to populate `chunk.usage.cache_read_input_tokens` and to fold
/// into `prompt_tokens` for the first-delta usage chunk. Reset to 0 at
/// the top of every `callStreaming` invocation.
_anthropic_cache_read_tokens: u32 = 0,
/// Anthropic-only: cached cache_creation_input_tokens from message_start.
/// (At message_start some relays already include the cache write; the
/// strict API sends it only at message_delta.) Reset to 0 at the top of
/// every `callStreaming` invocation.
_anthropic_cache_creation_tokens: u32 = 0,
```

(c) Reset them at the top of `callStreaming` (next to the existing
reset at L1689-1690):

```zig
self._anthropic_input_tokens = 0;
self._anthropic_usage_emitted = false;
self._anthropic_cache_read_tokens = 0;
self._anthropic_cache_creation_tokens = 0;
```

(d) `message_delta` branch (L1589-1651). Replace the block at L1627-1649:

```zig
if (root.object.get("usage")) |usage_val| {
    if (usage_val == .object) {
        // Per the new convention, `prompt_tokens` includes ALL input-shaped
        // tokens the model processed — input_tokens + cache_creation_input_tokens
        // + cache_read_input_tokens — so that `total_tokens = prompt +
        // completion` matches OpenAI's semantic.
        //
        // `message_delta.usage.input_tokens` is the AUTHORITATIVE input
        // count (some relays return 0 at message_start and the real value
        // here). Same for the cache fields: `message_delta` overrides the
        // cached message_start values, mirroring the input_tokens rule.
        //
        // `total_tokens` is `prompt_tokens + completion_tokens` — kept as
        // the same single source of truth the rest of the pipeline uses.
        var input_tokens: u32 = self._anthropic_input_tokens;
        var cache_creation_tokens: u32 = self._anthropic_cache_creation_tokens;
        var cache_read_tokens: u32 = self._anthropic_cache_read_tokens;
        var output_tokens: u32 = 0;

        if (usage_val.object.get("input_tokens")) |it| {
            if (it == .integer) input_tokens = @intCast(it.integer);
        }
        if (usage_val.object.get("cache_creation_input_tokens")) |cc| {
            if (cc == .integer) cache_creation_tokens = @intCast(cc.integer);
        }
        if (usage_val.object.get("cache_read_input_tokens")) |cr| {
            if (cr == .integer) cache_read_tokens = @intCast(cr.integer);
        }
        if (usage_val.object.get("output_tokens")) |ot| {
            if (ot == .integer) output_tokens = @intCast(ot.integer);
        }

        if (output_tokens > 0) {
            const prompt_tokens = input_tokens + cache_creation_tokens + cache_read_tokens;
            chunk.usage = .{
                .prompt_tokens = prompt_tokens,
                .completion_tokens = output_tokens,
                .total_tokens = prompt_tokens + output_tokens,
                .cache_creation_input_tokens = cache_creation_tokens,
                .cache_read_input_tokens = cache_read_tokens,
            };
        }
    }
}
```

(e) Update the first-delta usage chunk (around L1581-1588) — the
existing `chunk.usage = .{prompt_tokens, 0, prompt_tokens}` block —
to also include the cached cache_read (when present) so consumers
that ONLY see the first-delta usage (because message_delta doesn't
fire for some reason) get the right total.

Replace:

```zig
if (self._anthropic_input_tokens > 0 and !self._anthropic_usage_emitted) {
    chunk.usage = .{
        .prompt_tokens = self._anthropic_input_tokens,
        .completion_tokens = 0,
        .total_tokens = self._anthropic_input_tokens,
    };
    self._anthropic_usage_emitted = true;
}
```

with:

```zig
if (self._anthropic_input_tokens > 0 and !self._anthropic_usage_emitted) {
    const cached_read = self._anthropic_cache_read_tokens;
    const cached_creation = self._anthropic_cache_creation_tokens;
    const prompt_first_delta: u32 = self._anthropic_input_tokens + cached_creation + cached_read;
    chunk.usage = .{
        .prompt_tokens = prompt_first_delta,
        .completion_tokens = 0,
        .total_tokens = prompt_first_delta,
        .cache_creation_input_tokens = cached_creation,
        .cache_read_input_tokens = cached_read,
    };
    self._anthropic_usage_emitted = true;
}
```

**Step 2.4:** Run the new tests; confirm BOTH pass.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg "message_delta includes BOTH|cache_creation + cache_read are surfaced"
```

Expected: 2 of 2 passing.

**Step 2.5:** Run the FULL test suite — confirm OpenAI path and existing Anthropic tests are unaffected.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 600 zig build test --summary all 2>&1 | tail -20
```

Expected: all green. Pay attention to the 4 existing Anthropic usage tests (lines 298-417 of `parse_anthropic_sse_test.zig`) — none use `cache_read`, so totals should be unchanged for those.

**Step 2.6:** Commit.

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/modules/agent/Agent.zig src/modules/agent/parse_anthropic_sse_test.zig
git commit -m "fix(agent): include Anthropic cache_read_input_tokens in prompt + total_tokens"
```

---

## Task 3: Add the 2 cache columns to `llm_history` (Migration 074)

**File:** `src/migrations/migration.zig` (add `Migration074AddLlmHistoryCacheTokenColumns`)

**Why third:** Tasks 1-2 fix the in-memory `Usage` and the parser. Task 3 makes the cache counts durable so consumers of `llm_history` (compaction, frontend, future billing) can read them.

**Step 3.1:** Write the failing test.

**File:** `src/migrations/migration_074_test.zig` (NEW, copy `src/migrations/migration_073_test.zig` as the starting template)

The test file needs 4 tests:
1. Columns added with the correct names in the right order.
2. Existing rows still insert successfully (default 0 applies).
3. Re-running the migration is idempotent.
4. Explicit INSERT + SELECT round-trip populates both cache fields.

Use the exact same `TestCtx` / `setupDb` pattern as
`migration_073_test.zig`. Tests can be lifted with minor rewording:

```zig
//! Behavioural regression checks for Migration 074
//! (`llm_history.cache_creation_input_tokens` + `llm_history.cache_read_input_tokens`).
//!
//! Why this file exists
//! ────────────────────
//! Migration 074 adds two cache-breakdown columns to `llm_history` so
//! the Anthropic profile's `cache_creation_input_tokens` and
//! `cache_read_input_tokens` survive the trip from the SSE parser
//! through `CallResponse.usage` → `saveMessage` / `insertLLMHistories`
//! → the row. OpenAI rows always carry 0 (the parser never sets the
//! fields for that profile).
//!
//! The migration must:
//!   1. Add `cache_creation_input_tokens` and `cache_read_input_tokens`
//!      columns to `llm_history`, both INTEGER DEFAULT 0 (so legacy
//!      rows backfill cleanly).
//!   2. Be idempotent on a re-run — `ALTER TABLE … ADD COLUMN` is NOT
//!      idempotent, so we wrap in `try`/ignore or check
//!      pragma_table_info first. Use the same idempotency pattern as
//!      Migration 013 (the prompt/completion/total token columns).
//!   3. Allow INSERT + SELECT round-trip on a row with explicit cache
//!      values.
//!
//! Plan: docs/superpowers/plans/2026-08-13-fix-anthropic-total-tokens.md
//! Task: task_1786640688092 ("fixing antropic agent total tokens")

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration074AddLlmHistoryCacheTokenColumns = @import("migration.zig").Migration074AddLlmHistoryCacheTokenColumns;

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
    return .{ .db = db, .threaded = threaded };
}

/// Set up a fresh DB with the `llm_history` baseline table (mirrors what
/// Migration 001 creates on a real DB) so we can run Migration 074 against it.
/// Walks the migrations table schema only — doesn't run any other migration
/// (074 is fully additive; it must work on a DB where ONLY Migration 001 has
/// run).
fn setupWithLlmHistoryBaseline(ctx: *TestCtx, alloc: std.mem.Allocator) !void {
    try ctx.db.exec(alloc,
        \\CREATE TABLE IF NOT EXISTS llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_results_json TEXT,
        \\    finish_reason TEXT,
        \\    usage_json TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    parent_session_id TEXT,
        \\    parent_id TEXT
        \\)
    , &.{});
}

// ... 4 tests following the migration_073_test.zig shape.
```

**Step 3.2:** Register the new test file.

**File:** `src/migrations/test_runner.zig` (L41)

Add at the end of the `test { _ = @import(...) }` block:

```zig
_ = @import("migration_074_test.zig");  // llm_history.cache_creation_input_tokens + cache_read_input_tokens (anthropic-total-tokens plan, 2026-08-13)
```

**Step 3.3:** Run the tests; confirm 1 fails (the migration is undefined yet — `Migration074AddLlmHistoryCacheTokenColumns` doesn't exist).

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg "Migration074|cache_creation_input_tokens + cache_read_input_tokens"
```

Expected: compile error (undefined identifier `Migration074AddLlmHistoryCacheTokenColumns`).

**Step 3.4:** Add `Migration074AddLlmHistoryCacheTokenColumns` to `migration.zig`.

**File:** `src/migrations/migration.zig`

(a) Append the struct definition after the closing `};` of
`Migration073AddSessionActivity` (around L2983-3010):

```zig
/// Migration 074 — Add `cache_creation_input_tokens` +
/// `cache_read_input_tokens` columns to `llm_history` so the Anthropic
/// profile's cache breakdown survives from the SSE parser through to the
/// persistent row. OpenAI rows always carry 0.
///
/// Idempotency via the existing `addColumnIfMissing` helper
/// (`migration.zig:1643`) — probes `pragma_table_info('llm_history')`
/// before issuing the ALTER, so re-runs are no-ops on a DB that already
/// has the columns. `ALTER TABLE … ADD COLUMN` is NOT natively
/// idempotent in SQLite — re-running it raises "duplicate column name".
///
/// Plan: docs/superpowers/plans/2026-08-13-fix-anthropic-total-tokens.md
/// Task: task_1786640688092 ("fixing antropic agent total tokens")
pub const Migration074AddLlmHistoryCacheTokenColumns = struct {
    pub const version: u32 = 74;
    pub const name = "add_llm_history_cache_token_columns";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Anthropic cache write breakdown. Default 0 for legacy rows +
        // non-Anthropic profiles.
        try addColumnIfMissing(
            db,
            allocator,
            "llm_history",
            "cache_creation_input_tokens",
            "cache_creation_input_tokens INTEGER DEFAULT 0",
        );

        // Anthropic cache read breakdown. Default 0 for legacy rows +
        // non-Anthropic profiles.
        try addColumnIfMissing(
            db,
            allocator,
            "llm_history",
            "cache_read_input_tokens",
            "cache_read_input_tokens INTEGER DEFAULT 0",
        );
    }
};
```

(b) Register in the `allMigrations` list — right after the Migration 073
entry at L1850 (just before the closing `];` of the array):

```zig
// Migration 074 — llm_history.cache_creation_input_tokens +
// cache_read_input_tokens so the Anthropic SSE parser's cache breakdown
// survives the trip from CallResponse.usage to the row. OpenAI rows
// always carry 0. Plan:
// docs/superpowers/plans/2026-08-13-fix-anthropic-total-tokens.md.
// Task: task_1786640688092 ("fixing antropic agent total tokens").
.{ .version = Migration074AddLlmHistoryCacheTokenColumns.version, .name = Migration074AddLlmHistoryCacheTokenColumns.name, .up = Migration074AddLlmHistoryCacheTokenColumns.up },
```

**Step 3.5:** Run the migration tests; confirm all 4 PASS.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg "Migration074"
```

Expected: 4 of 4 passing. Especially: the "idempotent on re-run" test must
prove the `try`/probe-then-ALTER pattern works (not raising "duplicate
column name").

**Step 3.6:** Run the FULL test suite; confirm nothing else regressed.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 600 zig build test --summary all 2>&1 | tail -10
```

Expected: all green.

**Step 3.7:** Commit.

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/migrations/migration.zig src/migrations/test_runner.zig src/migrations/migration_074_test.zig
git commit -m "feat(db): Migration 074 — add cache_creation + cache_read input token columns to llm_history"
```

---

## Task 4: Wire the 2 cache fields through `saveMessage` (`llm_history.zig`)

**File:** `src/ai_workflow/tui/llm_history.zig` (modify `saveMessage` at L1078-1258 and `SaveMessageInput` at L1057-1076)

**Why fourth:** The migration creates the columns (Task 3); this task makes the application writer populate them. Both are needed before any consumer reads cache counts.

**Step 4.1:** Write the failing test.

**File:** `src/ai_workflow/tui/agentic_loop/llm_history.zig` (update the existing "default fields" test at L62-90)

Modify the test to also assert the new defaults:

```zig
try testing.expectEqual(@as(u32, 0), h.prompt_tokens);
try testing.expectEqual(@as(u32, 0), h.completion_tokens);
try testing.expectEqual(@as(u32, 0), h.total_tokens);
try testing.expectEqual(@as(u32, 0), h.cache_creation_input_tokens);
try testing.expectEqual(@as(u32, 0), h.cache_read_input_tokens);
```

**Step 4.2:** Run the test; confirm it FAILS (`cache_creation_input_tokens` doesn't exist on `LLMHistory` yet).

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg "LLMHistory default fields|default fields are safe"
```

Expected: compile error on `h.cache_creation_input_tokens`.

**Step 4.3:** Add 2 fields to `LLMHistory` row struct.

**File:** `src/ai_workflow/tui/agentic_loop/llm_history.zig` (L22-24)

```zig
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
    /// Anthropic-only: cache write tokens (cache_creation_input_tokens).
    /// 0 for OpenAI rows.
    cache_creation_input_tokens: u32 = 0,
    /// Anthropic-only: cache read tokens (cache_read_input_tokens).
    /// 0 for OpenAI rows.
    cache_read_input_tokens: u32 = 0,
```

**Step 4.4:** Run the test; confirm it PASSES.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg "LLMHistory default fields"
```

Expected: 1 of 1 passing.

**Step 4.5:** Add the 2 fields + INSERT columns to `SaveMessageInput` + the INSERT SQL.

**File:** `src/ai_workflow/tui/llm_history.zig` (modify `SaveMessageInput` at L1057-1076 AND the `INSERT` at L1128-1162 AND the args at L1224)

(a) Add to `SaveMessageInput`:

```zig
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
    cache_creation_input_tokens: usize = 0,
    cache_read_input_tokens: usize = 0,
```

(b) Add to the `INSERT INTO llm_history` column list (after `total_tokens,`):

```sql
\\    cache_creation_input_tokens,
\\    cache_read_input_tokens,
```

(c) Add to the placeholder list:

```sql
\\    ?, ?, ?, ?, ?, ?, ?, ?
```

(d) Add the 2 string-args + extend the `sqlArgs` tuple after `total_tokens_str`:

```zig
    const cache_creation_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.cache_creation_input_tokens});
    defer allocator.free(cache_creation_tokens_str);
    const cache_read_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.cache_read_input_tokens});
    defer allocator.free(cache_read_tokens_str);

    const sqlArgs = &.{ ..., total_tokens_str, cache_creation_tokens_str, cache_read_tokens_str, if (input.is_input) "1" else "0", ... };
```

(The exact order / `defer` placements need to match L1180-1224 of `llm_history.zig`. Mirror them.)

**Step 4.6:** Run the test suite; confirm nothing else regressed.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 600 zig build test --summary all 2>&1 | tail -10
```

Expected: all green. No other callers of `saveMessage` exist in the test
suite that pin a specific column count, so we shouldn't have new failures.

**Step 4.7:** Commit.

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/agentic_loop/llm_history.zig
git commit -m "feat(llm_history): persist cache_creation + cache_read input tokens on saveMessage"
```

---

## Task 5: Wire the 2 cache fields through `insertLLMHistories`

**File:** `src/ai_workflow/tui/agentic_loop/insert_llm_histories.zig` (modify SQL + sqlArgs around L88-184)

**Why fifth:** Mirror Task 4 for the parallel INSERT path used by the
`stop`-finish branch of the workflow.

**Step 5.1:** Make the surgical edits.

**File:** `src/ai_workflow/tui/agentic_loop/insert_llm_histories.zig`

(a) Add the 2 columns to the INSERT SQL after `total_tokens`:

```sql
\\    cache_creation_input_tokens,
\\    cache_read_input_tokens,
```

(b) Add 2 `?` placeholders, mirroring Task 4's string-arg plumbing.

(c) Extend the `sqlArgs` tuple to include `cache_creation_tokens_str`,
`cache_read_tokens_str` right after `total_tokens_str`.

**Step 5.2:** Run the test suite; confirm nothing regresses.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 600 zig build test --summary all 2>&1 | tail -10
```

Expected: all green. (No existing test pins column count on
`insert_llm_histories`; the changes are mechanical.)

**Step 5.3:** Commit.

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/ai_workflow/tui/agentic_loop/insert_llm_histories.zig
git commit -m "feat(llm_history): persist cache token columns through insertLLMHistories"
```

---

## Task 6: Wire the 2 cache fields through workflow.zig call sites

**File:** `src/ai_workflow/tui/agentic_loop/workflow.zig` (2 sites: L1201-1225 and L1583-1587) AND `src/ai_workflow/tui/agentic_loop/handle_tool.zig` (L419-441)

**Why last:** With persistence in place (Tasks 3-5), the workflow +
handle_tool need to forward the new fields from `CallResponse.usage` to
the DB layer.

**Step 6.1:** Update `workflow.zig`'s `finish_reason == .stop` insert
block (around L1201-1225). Add 2 `.cache_*_input_tokens` lines after the
existing `total_tokens = ...` line:

```zig
.prompt_tokens = @intCast(res_dynamic_agent.usage.prompt_tokens),
.completion_tokens = @intCast(res_dynamic_agent.usage.completion_tokens),
.total_tokens = @intCast(res_dynamic_agent.usage.total_tokens),
.cache_creation_input_tokens = @intCast(res_dynamic_agent.usage.cache_creation_input_tokens),
.cache_read_input_tokens = @intCast(res_dynamic_agent.usage.cache_read_input_tokens),
```

**Step 6.2:** Update `workflow.zig`'s `usage_for_agent` literal at
L1583-1587. Add the 2 cache fields and forward them:

```zig
const usage_for_agent: agent.Usage = .{
    .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
    .completion_tokens = res_dynamic_agent.usage.completion_tokens,
    .total_tokens = res_dynamic_agent.usage.total_tokens,
    .cache_creation_input_tokens = res_dynamic_agent.usage.cache_creation_input_tokens,
    .cache_read_input_tokens = res_dynamic_agent.usage.cache_read_input_tokens,
};
```

**Step 6.3:** Update `handle_tool.zig`'s `saveMessage` call at L419-441.
Add 2 `.cache_*_input_tokens` lines after the existing
`.total_tokens = ...` line:

```zig
.prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
.completion_tokens = res_dynamic_agent.usage.completion_tokens,
.total_tokens = res_dynamic_agent.usage.total_tokens,
.cache_creation_input_tokens = res_dynamic_agent.usage.cache_creation_input_tokens,
.cache_read_input_tokens = res_dynamic_agent.usage.cache_read_input_tokens,
```

**Step 6.4:** Run the test suite; confirm nothing regresses.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 600 zig build test --summary all 2>&1 | tail -10
```

Expected: all green. Tests are structural, not behavioral, so no new
failures expected. If any test fails on the new lines, the most likely
issue is a typo in the field name from Task 1.

**Step 6.5:** Commit.

```bash
cd /home/ginwa/ginwaaitoolbox
git add src/ai_workflow/tui/agentic_loop/workflow.zig src/ai_workflow/tui/agentic_loop/handle_tool.zig
git commit -m "feat(workflow): forward Anthropic cache token fields from CallResponse.usage to llm_history"
```

---

## Task 7: Final verification + docs update

**Step 7.1:** Run the FULL test suite one more time.

```bash
cd /home/ginwa/ginwaaitoolbox
timeout 600 zig build test --summary all 2>&1 | tail -15
```

Expected: all green. If anything fails, fix the regression in a
follow-up commit before proceeding.

**Step 7.2:** Update `AGENTS.md` changelog.

Append a one-line entry under the "Recent changes" section:

```markdown
- **Fix Anthropic token usage accounting — include cache_read_input_tokens in prompt + total** (2026-08-13): `Agent.Usage` gained `cache_creation_input_tokens` + `cache_read_input_tokens` fields; the Anthropic SSE parser's `message_delta` formula now includes cache_read in `prompt_tokens` and `total_tokens` (matching OpenAI's semantic). Migration 074 added the 2 columns to `llm_history` so the cache breakdown survives to the row. Plan: `docs/superpowers/plans/2026-08-13-fix-anthropic-total-tokens.md`.
```

**Step 7.3:** Open the PR with `gh` (or push to remote and open via the
web UI) and request code review.

```bash
cd /home/ginwa/ginwaaitoolbox
git push -u origin worktree/fix-anthropic-total-tokens
gh pr create --title "fix(agent): include Anthropic cache_read_input_tokens in prompt + total_tokens" --body-file - <<'EOF'
## Summary

Anthropic `url_style` profiles were reporting `total_tokens` significantly
lower than equivalent OpenAI calls — exactly by the size of
`cache_read_input_tokens`. The parser correctly included cache writes
(billable at ~1.25× input rate) but dropped cache reads from the total
entirely. This made Anthropic totals invisible to compaction, the
chat-header token pill, and any future cross-provider billing comparison.

## Changes

* **`Agent.Usage`** gains 2 optional fields:
  `cache_creation_input_tokens` + `cache_read_input_tokens` (both default
  0 — no breakage for OpenAI).
* **Anthropic SSE parser** (`parse_anthropic_stream_chunk`): the
  `message_delta` formula becomes
  `prompt = input + cache_creation + cache_read`,
  `total = prompt + completion`. The cache breakdown is preserved on
  `Usage` for downstream billing.
* **`message_start` cache** now also caches the 2 cache fields when the
  strict API / a relay returns them before `message_delta`, mirroring the
  existing input_tokens-cache pattern.
* **Migration 074** adds the 2 columns to `llm_history` (idempotent
  via pragma_table_info probe + ALTER).
* **`saveMessage` / `insertLLMHistories`** persist the new columns.
* **`workflow.zig` + `handle_tool.zig`** forward the 2 new fields from
  `CallResponse.usage` to `LLMHistory`.

## Behavioural matrix

| Profile | Cache shape | Before `total` | After `total` |
|---------|-------------|----------------|---------------|
| openai  | n/a         | `prompt + completion` | **same** |
| anthropic | input=1000, cache_creation=500, output=1000 | 2500 | 2500 (unchanged) |
| anthropic | input=1000, cache_read=5000, output=1000 | 2000 ❌ | **7000** ✅ |
| anthropic | input=1000, cache_creation=500, cache_read=5000, output=1000 | 2500 ❌ | **7500** ✅ |

## Out of scope (intentionally)

Cost-log formula at `Agent.zig:2014-2016` is NOT updated. The prompt
_tokens field is no longer safe as a billable-input metric (it includes
discounted cache reads), but Anthropic's pricing multipliers aren't
documented in this repo — separate research task → separate PR.

## Spec / plan

* `docs/superpowers/specs/2026-08-13-fix-anthropic-total-tokens-design.md`
* `docs/superpowers/plans/2026-08-13-fix-anthropic-total-tokens.md`
EOF
```

(Adapt the `gh pr create` invocation to whatever the user usually uses.)

**Step 7.4:** Move the kanban card to `in_review_task` once all tests are green.
