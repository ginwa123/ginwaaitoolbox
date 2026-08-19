# Agent tools: `update_plan` + `get_plan` (session-scoped markdown plan with checklist)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-19
**Task:** `task_1787073929852_8` — "create a agent tool name update_plan, and get_plan"
**User's spec (verbatim):** *"create a new table session_plan, session_plan is just one to one relationship with table session. the tool is overwrite the plan everytime is doing update, plan, the content plan should markdown, with the checklist, if task plan done, every time ai agent complete the task it should checkist and in compaction method, put the plan there so the next agent know what the before agent doing"*
**Branch / worktree:** `worktree/agent-plan-tool` (created from current `in progress` task; per the project rule, do all work in a git worktree and open a PR for review).

**Goal:** Add two agent-callable tools, `update_plan` and `get_plan`, backed by a new `session_plan` SQLite table (1:1 with `sessions`). The plan is plain markdown with a `- [ ]` / `- [x]` checklist; the agent overwrites the row on every `update_plan` call (UPSERT) and is responsible for ticking the boxes as work progresses. The plan is re-injected into every agent iteration (system prompt) AND into the compaction envelope so the next agent after compaction knows what the prior agent was doing.

**Architecture:** New `session_plan` table (session_id TEXT PK, plan_md TEXT NOT NULL DEFAULT '', updated_at DATETIME). Storage layer in `src/ai_workflow/tui/agentic_loop/session_plan.zig` mirroring `agent_memories.zig`'s shape (`savePlan`, `getPlan`, `getPlanOpt`). Two new tool modules in `src/modules/agent/tools/` (`update_plan.zig`, `get_plan.zig`) plus matching exec adapters in `src/ai_workflow/tui/agentic_loop/tools_exec_*.zig`. Tool registration in `tools_equipped.zig` + `tools.zig` + `src/root.zig`. Two system-prompt hooks: a new `prompts_make_plan_context.zig` helper (called from `prompts_build_messages_for_agent_prompt.zig` BEFORE the `final_system.toOwnedSlice` step) injects the current plan as a `## Current Plan` markdown block on every iteration; a new `<plan>` section is added to `enrichCompactionXml` in `workflow_compact_message.zig` so the plan survives compaction. Tool descriptions explicitly tell the agent "call `update_plan` after every checklist item is completed to flip `- [ ]` → `- [x]`".

**Tech Stack:** Zig 0.16 (backend), Vue 3 + TypeScript + Vitest (frontend), SQLite via `nalarcore.sqlite.SqliteBackend`, no new deps. One migration: 076.

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows. Verify with `zig build test --summary all` + `bun run build` + `bunx vitest run`.
- **Tool naming follows project convention**: snake_case file names (`update_plan.zig`, `get_plan.zig`), `update_plan_tool` / `get_plan_tool` const names, `execUpdatePlan` / `execGetPlan` exec fn names. Same pattern as `save_memory.zig` / `load_memory.zig`.
- **No FK on `session_plan.session_id`**: matches the precedent of `llm_history.session_id`, `worker.session_id`, `session_queue_messages.session_id`, `session_activity.session_id` (Migration 073's docstring documents the rationale — "a session could be hard-deleted while keeping its history"). The 1:1 relationship is enforced by the table's PK.
- **Idempotent migration via `CREATE TABLE IF NOT EXISTS`**: matches Migration 070 (`agent_memories`) and Migration 073 (`session_activity`) patterns.
- **Backend-only behaviour**: the agent calls the tool via the LLM tool-call loop; we add ZERO new HTTP endpoints (no `POST /api/sessions/:id/plan`).
- **No new comments above `logger.infoFmt(...)` calls** (see `~/.config/nalar/memories/no-comments-on-logger-calls.md`).
- **Static-contract tests** for the tool registration (mirror `kanban_tasks_create_test.zig`); live DB tests for the storage layer (mirror `agent_memories.zig`'s test setup).
- **No port 8081**: smoke tests use port 8080.
- **Plan MD is agent-trusted**: the storage layer does NOT validate the markdown structure (no checklist parsing, no schema enforcement). The agent is told via the tool description how to format it; the system prompt reinforces the convention.

## Design Decisions (review before execution)

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| D1 | **New `session_plan` table (1:1 with `sessions`)**, keyed by `session_id TEXT PRIMARY KEY` | Mirrors `agent_memories` (per-feature table, not extension of `sessions`). One row per session, naturally enforced by the PK. UPSERT on `update_plan` overwrites the row. Simpler than adding 3 columns to `sessions`. | Add `plan_md` + `plan_updated_at` columns to `sessions` — pollutes the `sessions` table with plan-specific concerns; harder to backfill/migrate later. |
| D2 | **No FK constraint to `sessions.id`** | Matches Migration 073 (`session_activity`) and `llm_history.session_id` precedent. A session can be hard-deleted while keeping its plan (rare, but the policy is consistent). The PK enforces 1:1. | Add `REFERENCES sessions(id) ON DELETE CASCADE` — would require coordinating with the session delete path; inconsistent with the rest of the codebase. |
| D3 | **`session_id` is implicit (from `ctx.session_id`)** | The agent is operating on ONE session at a time. Requiring the LLM to pass `session_id` invites errors (it might pass the wrong one for sub-agents). The exec adapter pulls from `ctx.session_id`. The tool's JSON schema does NOT declare `session_id`. | Require `session_id` in the input — sub-agents operating on a parent's session have to know their parent's id, which isn't always available. Forces every LLM call to redundantly include it. |
| D4 | **`update_plan` is UPSERT, not INSERT-only** | The user said "the tool is overwrite the plan everytime is doing update, plan". One row per session, overwrite semantics. `INSERT … ON CONFLICT(session_id) DO UPDATE` (a.k.a. UPSERT). | Insert-only with a separate `plan_history` table — overkill for v1, adds schema complexity. |
| D5 | **`update_plan` returns the row's `updated_at` timestamp** | Mirrors `save_memory` (returns `<id>`, `<created_at>`, `<updated_at>`). The agent uses this to confirm "yes, the write landed". | Return empty string — the agent can't tell whether the write succeeded. |
| D6 | **`get_plan` returns `<plan>` if present, `<empty/>` if absent** | The agent must distinguish "no plan set" from "plan exists but empty". Use `<empty/>` self-closing XML (matches how other tools signal absence). | Return empty string for both — agent can't tell the difference. |
| D7 | **Plan size cap: 256 KiB** (262,144 bytes) | Smaller than `agent_memories`'s 1 MiB because the plan is injected into the system prompt on every iteration. A 1 MiB plan would balloon the prompt. 256 KiB is plenty for a checklist with ~50 items. Returns `error.ContentTooLarge` on overflow. | 1 MiB cap (agent_memories pattern) — too large for system prompt injection. No cap — runaway agent fills the DB. |
| D8 | **Plan injection in TWO places**: (a) system prompt via `prompts_make_plan_context.zig`, (b) compaction envelope via new `<plan>` section in `enrichCompactionXml` | (a) ensures every iteration sees the current plan, including the FIRST iteration before any compaction happens. (b) ensures the plan survives compaction so the post-compaction agent sees what the prior agent was working on. Both are necessary. | Only inject at compaction — fresh sessions and short sessions would never see the plan. Only inject in system prompt — compaction would lose the plan mid-session. |
| D9 | **No `delete_plan` tool** | The plan is part of the session's history. When the agent finishes a task, they can either (a) leave the plan (history value), (b) overwrite with `update_plan(content="")` to mark "no active plan", or (c) the next session on the same `session_id` will overwrite it anyway. No need for a delete primitive. | Add `delete_plan` — duplicates `update_plan(content="")`. |

## File Structure

```
NEW  src/migrations/migration_076_session_plan.zig                (test file: static-contract tests for the schema)
EDIT src/migrations/migration.zig                                  (+ Migration076CreateSessionPlan struct, + entry in allMigrations slice at line ~1929)
NEW  src/ai_workflow/tui/agentic_loop/session_plan.zig            (storage layer: savePlan, getPlan, getPlanOpt, MAX_PLAN_BYTES)
NEW  src/ai_workflow/tui/agentic_loop/session_plan_test.zig       (live-DB tests mirroring agent_memories_test.zig)
NEW  src/modules/agent/tools/update_plan.zig                       (AgentTool const + UpdatePlanInput struct + executeUpdatePlan pure fn)
NEW  src/modules/agent/tools/update_plan_test.zig                  (pure-fn tests)
NEW  src/modules/agent/tools/get_plan.zig                          (AgentTool const + GetPlanInput struct + executeGetPlan pure fn)
NEW  src/modules/agent/tools/get_plan_test.zig                     (pure-fn tests)
NEW  src/ai_workflow/tui/agentic_loop/tools_exec_update_plan.zig   (thin adapter: parse JSON → call pure fn → wrapToolOutput)
NEW  src/ai_workflow/tui/agentic_loop/tools_exec_get_plan.zig      (thin adapter)
NEW  src/ai_workflow/tui/agentic_loop/tools_exec_update_plan_test.zig (exec-wrapper tests, end-to-end with in-memory DB)
NEW  src/ai_workflow/tui/agentic_loop/tools_exec_get_plan_test.zig
NEW  src/ai_workflow/tui/agentic_loop/prompts_make_plan_context.zig  (BuildPlanContext: reads session_plan, renders `## Current Plan` markdown block)
EDIT src/ai_workflow/tui/agentic_loop/prompts.zig                  (+ pub const makePlanContext re-export)
EDIT src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig  (+ planContent helper call + append to final_system)
EDIT src/ai_workflow/tui/agentic_loop/workflow_compact_message.zig  (+ fetchSessionPlan helper + new <plan> section in enrichCompactionXml)
EDIT src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig (+ pass session_id to enrichCompactionXml + new fetchSessionPlan call)
EDIT src/ai_workflow/tui/agentic_loop/tools.zig                    (+ execUpdatePlan + execGetPlan re-exports)
EDIT src/ai_workflow/tui/agentic_loop/tools_equipped.zig           (+ const update_plan_mod / get_plan_mod + entries in equips() and UNIFIED_TOOL_REGISTRY())
EDIT src/root.zig                                                  (+ pub const update_plan / get_plan re-exports)
EDIT src/apps/desktop/src/components/views/ChatView.vue             (optional: add tool dispatcher branch for update_plan + get_plan)
NEW  src/apps/desktop/src/components/tool_outputs/UpdatePlan.vue    (optional UI: renders the tool result as a checklist summary)
NEW  src/apps/desktop/src/components/tool_outputs/GetPlan.vue       (optional UI: renders the fetched plan as a checklist)
NEW  src/apps/desktop/src/__tests__/ChatView.updatePlan.spec.ts     (optional UI tests)
EDIT docs/SPEC.md                                                    (§3.X new section + PR index entry)
EDIT NALAR.md                                                        (Recent changes entry)
```

Total: **14 NEW files, 11 EDIT files, 1 migration**. No schema change to existing tables.

---

## Root Cause (read this before chunking — saves re-discovery)

### The bug today

An agent working on a multi-step task loses context between:

1. **Iterations within one session** — the LLM only sees the conversation history (which fills up fast on multi-step work). When the prompt gets long enough to require compaction, the compactor's own summary replaces the conversation, but the compactor is NOT told "here is the structured plan you were following." The next agent iteration has to re-derive the plan from the loose conversation summary, often drifting from the original intent.

2. **Sessions that cross compaction boundaries** — once `maybeCompactMessagesNew` fires, the original messages are marked `is_feed_to_llm=0` and replaced by one `<compact_messages>` user-role row. That row carries `<user_history>`, `<read_files>`, `<recent_activities>`, `<session_skills>` (the "compaction_context" enrichment), but does NOT carry the plan. The post-compaction agent literally has no record of the structured task list.

3. **Sub-agent handoffs** — when a `spawn_sub_agent` returns, the parent's prompt grows but no plan metadata is propagated. The sub-agent invents its own sub-plan, writes nothing durable, and the parent has to reconstruct from conversation.

4. **Resume after `kill -9` + restart** — when a worker is wiped by the cleanup cron, the next user message on that `session_id` creates a fresh worker with zero in-memory state. The plan from the previous run is lost unless it lived in the conversation (which it didn't).

### What this plan fixes

- The agent has a primitive `update_plan` that durably stores a markdown plan with a `- [ ]` / `- [x]` checklist in `session_plan`.
- Every iteration re-injects the current plan into the system prompt via `prompts_make_plan_context.zig` — so the agent always sees "you are on step 3 of 7, steps 1-2 are done."
- The compaction enrichment adds a `<plan>` section to the envelope — so even after compaction, the structured plan survives.
- The agent is told (via the tool description + system prompt) to overwrite the plan after every checklist item, flipping `- [ ]` to `- [x]`. This gives the user (and the agent itself) a durable progress indicator.

---

## Task 1 — Storage layer + migration

> **Outcome**: `session_plan` table exists. `savePlan(allocator, db, session_id, content)` UPSERTs the row. `getPlan(allocator, db, session_id)` returns the markdown (or empty string when absent). `getPlanOpt(allocator, db, session_id)` returns `?PlanRow` for the compaction enrich path. Hard 256 KiB cap returns `error.ContentTooLarge`. Migration 076 registers, is idempotent, and runs cleanly on a fresh DB and on a DB that already has the table.

### Step 1.1 — Write the failing test file

Create `src/ai_workflow/tui/agentic_loop/session_plan_test.zig`. Mirror the structure of `agent_memories_test.zig` (live in-memory sqlite + run migrations):

```zig
const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");
const session_plan = @import("session_plan.zig");

fn setupDb(allocator: std.mem.Allocator) !*sqlite.SqliteBackend {
    var db = try sqlite.SqliteBackend.initInMemory(allocator);
    errdefer db.deinit();
    var mgr = migration.MigrationManager.init(allocator, db);
    try migration.registerAllMigrations(&mgr);
    try mgr.runMigrations();
    return db;
}

test "savePlan + getPlan round-trip preserves content" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();

    const session_id = "test_session_1";
    try session_plan.savePlan(allocator, db, .{
        .session_id = session_id,
        .content = "# My Plan\n\n- [ ] step 1\n- [x] step 2\n",
    });
    const got = try session_plan.getPlan(allocator, db, session_id);
    defer allocator.free(got);
    try testing.expectEqualStrings("# My Plan\n\n- [ ] step 1\n- [x] step 2\n", got);
}

test "getPlan on missing session returns empty string" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();
    const got = try session_plan.getPlan(allocator, db, "nonexistent");
    defer allocator.free(got);
    try testing.expectEqualStrings("", got);
}

test "savePlan overwrites existing row (UPSERT semantics)" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();
    const sid = "upsert_test";

    try session_plan.savePlan(allocator, db, .{ .session_id = sid, .content = "v1" });
    try session_plan.savePlan(allocator, db, .{ .session_id = sid, .content = "v2 longer" });

    const got = try session_plan.getPlan(allocator, db, sid);
    defer allocator.free(got);
    try testing.expectEqualStrings("v2 longer", got);
}

test "savePlan rejects content > 256 KiB with ContentTooLarge" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();
    var big = try allocator.alloc(u8, session_plan.MAX_PLAN_BYTES + 1);
    defer allocator.free(big);
    @memset(big, 'a');

    const result = session_plan.savePlan(allocator, db, .{
        .session_id = "big", .content = big,
    });
    try testing.expectError(error.ContentTooLarge, result);
}

test "savePlan rejects empty content with InvalidContent" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();
    const result = session_plan.savePlan(allocator, db, .{
        .session_id = "empty", .content = "",
    });
    try testing.expectError(error.InvalidContent, result);
}

test "getPlanOpt returns null when no row, populated struct when present" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();

    // absent
    const absent = try session_plan.getPlanOpt(allocator, db, "nope");
    try testing.expect(absent == null);

    // present
    try session_plan.savePlan(allocator, db, .{ .session_id = "s", .content = "hello" });
    const present = try session_plan.getPlanOpt(allocator, db, "s");
    try testing.expect(present != null);
    if (present) |row| {
        defer row.deinit(allocator);
        try testing.expectEqualStrings("hello", row.plan_md);
        try testing.expect(row.updated_at.len > 0);
    }
}
```

Run the tests, expect FAIL:

```bash
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

- [ ] Failing tests confirmed (the `session_plan` module doesn't exist yet — compile errors)

### Step 1.2 — Implement the storage layer

Create `src/ai_workflow/tui/agentic_loop/session_plan.zig`. Mirror `agent_memories.zig`'s header doc style:

```zig
//! Storage layer for the `update_plan` + `get_plan` agent tools.
//!
//! Three public functions:
//!   - `savePlan` — UPSERT a plan row (insert-or-replace by `session_id`)
//!   - `getPlan` — fetch the plan markdown (returns "" when absent)
//!   - `getPlanOpt` — fetch the full PlanRow (returns null when absent)
//!
//! Backed by Migration 076's `session_plan` table. UPSERT via
//! `INSERT … ON CONFLICT(session_id) DO UPDATE` so calling `update_plan`
//! repeatedly replaces the prior plan, matching the user spec "the tool
//! is overwrite the plan everytime".
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task: task_1787073929852_8
//!
//! Why a dedicated module (NOT extending llm_history.zig or sessions model)
//! ──────────────────────────────────────────────────────────────────────
//! `sessions` is for chat session metadata; adding plan_md there would dilute
//! it (D1 in the plan). `llm_history` is for chat messages, not durable
//! session-scoped state. A dedicated module matches the project pattern
//! (`agent_memories.zig`, `session_skills.zig`).

const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

/// One row in `session_plan`. All string fields are allocator-owned and
/// must be freed by the caller via `deinit`.
pub const PlanRow = struct {
    session_id: []const u8,
    plan_md: []const u8,
    updated_at: []const u8,

    pub fn deinit(self: PlanRow, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.plan_md);
        if (self.updated_at.len > 0) allocator.free(self.updated_at);
    }
};

/// Arguments for `savePlan`.
pub const SavePlanArgs = struct {
    session_id: []const u8,
    /// The markdown plan body. 1 byte – 256 KiB. Empty string → `error.InvalidContent`.
    content: []const u8,
};

/// Hard cap on plan size. 256 KiB is large enough for ~50 checklist items
/// with prose, small enough to keep system-prompt injection bounded.
pub const MAX_PLAN_BYTES: usize = 256 * 1024;

/// Save (UPSERT) a plan. Overwrites any existing row for `session_id`.
/// Returns the row's `updated_at` timestamp (a freshly-allocated copy
/// the caller must free).
///
/// Errors:
///   - `error.InvalidContent` — content is empty
///   - `error.ContentTooLarge` — content exceeds `MAX_PLAN_BYTES`
///   - DB errors propagate verbatim
pub fn savePlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    args: SavePlanArgs,
) ![]const u8 {
    if (args.content.len == 0) return error.InvalidContent;
    if (args.content.len > MAX_PLAN_BYTES) return error.ContentTooLarge;
    if (args.session_id.len == 0) return error.InvalidSessionId;

    try db.exec(allocator,
        \\INSERT INTO session_plan (session_id, plan_md, updated_at)
        \\VALUES (?, ?, CURRENT_TIMESTAMP)
        \\ON CONFLICT(session_id) DO UPDATE SET
        \\    plan_md = excluded.plan_md,
        \\    updated_at = CURRENT_TIMESTAMP
    , .{ args.session_id, args.content });

    const updated_at = try db.query(allocator,
        "SELECT updated_at FROM session_plan WHERE session_id = ?",
        .{args.session_id});
    defer updated_at.deinit();
    const row = try updated_at.next() orelse return error.RowNotFoundAfterInsert;
    const ts = try allocator.dupe(u8, row.values[0]);
    row.deinit(allocator);
    return ts;
}

/// Fetch the plan markdown for `session_id`. Returns an allocated copy
/// of `""` when the row is absent (canonical "no plan" sentinel —
/// matches the `description` / `tags` convention of empty-string-on-absent).
/// Caller owns the returned slice and must free with `allocator.free()`.
pub fn getPlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    var q = try db.query(allocator,
        "SELECT plan_md FROM session_plan WHERE session_id = ?",
        .{session_id});
    defer q.deinit();

    if (try q.next()) |row| {
        defer row.deinit(allocator);
        if (row.values[0].len == 0) return allocator.dupe(u8, "");
        return allocator.dupe(u8, row.values[0]);
    }
    return allocator.dupe(u8, "");
}

/// Fetch the full `PlanRow` for `session_id`. Returns `null` when absent
/// (matches `agent_memories.getMemoryById` convention). Used by the
/// compaction enrichment to also carry the `updated_at` timestamp.
pub fn getPlanOpt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?PlanRow {
    var q = try db.query(allocator,
        "SELECT session_id, plan_md, COALESCE(updated_at, '') FROM session_plan WHERE session_id = ?",
        .{session_id});
    defer q.deinit();

    const row = (try q.next()) orelse return null;
    const session_id_owned = try allocator.dupe(u8, row.values[0]);
    errdefer allocator.free(session_id_owned);
    const plan_md_owned = try allocator.dupe(u8, row.values[1]);
    errdefer allocator.free(plan_md_owned);
    const updated_at_owned = try allocator.dupe(u8, row.values[2]);
    errdefer allocator.free(updated_at_owned);
    row.deinit(allocator);

    return PlanRow{
        .session_id = session_id_owned,
        .plan_md = plan_md_owned,
        .updated_at = updated_at_owned,
    };
}
```

### Step 1.3 — Add Migration 076

Edit `src/migrations/migration.zig`. Append at the end of the file (after `Migration075RenameTimestampColumnsToNanoSuffix`, before the older migrations):

```zig
// ============================================================================
// Migration 076 — `session_plan` 1:1 table with `sessions` for the agent's
// persistent task plan (markdown + checklist).
// ============================================================================
//
// Schema:
//   - session_id TEXT PRIMARY KEY  (logical 1:1 with sessions.id; no FK
//                                   because sessions may be hard-deleted
//                                   while keeping their plan — matches
//                                   llm_history.session_id, worker.session_id,
//                                   session_queue_messages.session_id,
//                                   session_activity.session_id precedent;
//                                   see Migration 073's docstring.)
//   - plan_md TEXT NOT NULL DEFAULT ''  (the markdown body)
//   - updated_at DATETIME DEFAULT CURRENT_TIMESTAMP  (auto-bumped on every UPSERT)
//
// Why a dedicated table (not columns on `sessions`)
// - Single Responsibility: `sessions` is chat metadata; plan_md is plan content.
// - Backward compat: future schema changes to plan only touch this table.
// - PK on session_id enforces 1:1 without an extra UNIQUE index.
//
// Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
// Task: task_1787073929852_8
pub const Migration076CreateSessionPlan = struct {
    pub const version: u32 = 76;
    pub const name = "create_session_plan";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_plan (
            \\    session_id TEXT PRIMARY KEY,
            \\    plan_md TEXT NOT NULL DEFAULT '',
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});
        // No FK on session_id (matches session_activity Migration 073 precedent).
        // No index — session_id IS the PK, lookups are O(log n) by definition.
    }
};
```

Edit `src/migrations/migration.zig` again. Append the registration entry to `allMigrations` (find the slice around line 1929, after Migration 075's entry):

```zig
.{ .version = Migration076CreateSessionPlan.version,
   .name    = Migration076CreateSessionPlan.name,
   .up      = Migration076CreateSessionPlan.up },
```

### Step 1.4 — Run tests, expect PASS

```bash
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

- [ ] All 6 `session_plan_test.zig` tests pass
- [ ] No regression (baseline ~2271 + 6 new ≈ 2277)
- [ ] Migration 076 runs idempotently (verified by running tests twice in a row)

### Step 1.5 — Commit

```bash
git add src/migrations/migration.zig \
        src/ai_workflow/tui/agentic_loop/session_plan.zig \
        src/ai_workflow/tui/agentic_loop/session_plan_test.zig

git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(plan): session_plan table + storage layer (Migration 076)

Adds the session_plan table (1:1 with sessions, session_id TEXT PK,
plan_md TEXT NOT NULL DEFAULT '', updated_at DATETIME) and a
session_plan.zig storage layer with savePlan (UPSERT, 256 KiB cap),
getPlan (returns empty string when absent), and getPlanOpt (returns
PlanRow for the compaction enrich path).

Mirrors the agent_memories.zig pattern (per-feature module, not
extension of an existing table). No FK on session_id (matches the
llm_history / worker / session_queue_messages / session_activity
precedent documented in Migration 073 — a session may be hard-deleted
while keeping its plan).

Live-DB tests cover round-trip, UPSERT overwrite, size cap, empty
rejection, and getPlanOpt absent/present branches.

Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
Task 1 of 9"
```

---

## Task 2 — Tool module: `update_plan` (pure-fn layer)

> **Outcome**: `src/modules/agent/tools/update_plan.zig` exists with the `update_plan_tool` JSON schema (the wire contract sent to the LLM), the `UpdatePlanInput` struct, and the `executeUpdatePlan(allocator, db, input)` pure function that wraps `session_plan.savePlan`. Pure-fn tests pass without needing the agentic loop.

### Step 2.1 — Write the failing pure-fn test

Create `src/modules/agent/tools/update_plan_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");
const update_plan_mod = @import("update_plan.zig");

fn setupDb(allocator: std.mem.Allocator) !*sqlite.SqliteBackend {
    var db = try sqlite.SqliteBackend.initInMemory(allocator);
    errdefer db.deinit();
    var mgr = migration.MigrationManager.init(allocator, db);
    try migration.registerAllMigrations(&mgr);
    try mgr.runMigrations();
    return db;
}

test "executeUpdatePlan: success returns successXml with updated_at" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();

    const result = try update_plan_mod.executeUpdatePlan(allocator, db, .{
        .content = "# Plan\n\n- [ ] step 1\n",
    });
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<update_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<session_id>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<updated_at>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "# Plan") != null); // content echoed (xml-escaped if needed)
}

test "executeUpdatePlan: invalid content (empty) returns errorXml" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();

    const result = try update_plan_mod.executeUpdatePlan(allocator, db, .{ .content = "" });
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "non-empty") != null);
}

test "executeUpdatePlan: oversized content returns errorXml" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();
    var big = try allocator.alloc(u8, update_plan_mod.MAX_PLAN_BYTES + 1);
    defer allocator.free(big);
    @memset(big, 'x');

    const result = try update_plan_mod.executeUpdatePlan(allocator, db, .{ .content = big });
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "256 KiB") != null);
}

test "update_plan_tool JSON schema: name='update_plan', properties has content (required)" {
    try testing.expectEqualStrings("update_plan", update_plan_mod.update_plan_tool.function.name);
    try testing.expect(std.mem.indexOf(u8, update_plan_mod.update_plan_tool.function.description.?[:], "update_plan") != null);
    try testing.expect(std.mem.indexOf(u8, update_plan_mod.update_plan_tool.function.description.?[:], "checklist") != null);
    // Required: ["content"]
    try testing.expectEqual(@as(usize, 1), update_plan_mod.update_plan_tool.function.parameters.required.len);
    try testing.expectEqualStrings("content", update_plan_mod.update_plan_tool.function.parameters.required[0]);
    // Properties: content only (no session_id — implicit per D3)
    try testing.expectEqual(@as(usize, 1), update_plan_mod.update_plan_tool.function.parameters.properties.len);
    try testing.expectEqualStrings("content", update_plan_mod.update_plan_tool.function.parameters.properties[0].name);
}
```

Run, expect FAIL (compile errors):

```bash
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

- [ ] Failing tests confirmed

### Step 2.2 — Implement `update_plan.zig`

Create `src/modules/agent/tools/update_plan.zig`. Mirror `save_memory.zig`'s doc-style + structure exactly:

```zig
//! Agent-callable tool: `update_plan` — UPSERT the agent's task plan for
//! the current session as markdown with a checklist.
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task: task_1787073929852_8
//!
//! Wire shape:
//!   input:  { content: string }
//!   output: <update_plan><session_id>...</session_id><updated_at>...</updated_at>
//!            </update_plan>
//!   or:     <update_plan><error>...</error></update_plan>
//!
//! The actual UPSERT lives in `session_plan.savePlan`. This file is a
//! thin XML wrapper (mirrors the `save_memory.zig` pattern).
//!
//! Design choices:
//!   - session_id is NOT in the input (D3 — implicit from
//!     `ToolExecContext.session_id` in the exec adapter).
//!   - Hard cap is 256 KiB (`session_plan.MAX_PLAN_BYTES`) — see D7.
//!   - Empty content is rejected (InvalidContent) — distinguishes
//!     "no plan" (use `get_plan` and see `<empty/>`) from "explicitly
//!     clear" (caller should not call update_plan with empty).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const session_plan = nalarcore.session_plan;

const helpers = nalarcore.helpers;
const xmlEscape = helpers.xml_escape;

pub const MAX_PLAN_BYTES: usize = session_plan.MAX_PLAN_BYTES;

/// Input for `update_plan`.
pub const UpdatePlanInput = struct {
    /// The markdown plan body. 1 byte – 256 KiB. Empty content is rejected.
    /// Use plain markdown with `- [ ]` for todo items and `- [x]` for done.
    content: []const u8 = "",
};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to use this tool — it explicitly
/// tells the agent to overwrite the plan after every checklist item.
pub const update_plan_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "update_plan",
        .description =
            \\Overwrite (UPSERT) the agent's structured task plan for the current session.
            \\The plan is plain markdown with a `- [ ]` (todo) / `- [x]` (done) checklist.
            \\
            \\Use this tool to:
            \\1. Lay out your plan BEFORE you start work (after understanding the user's request).
            \\2. Overwrite the plan AFTER completing each checklist item, flipping `- [ ]` to `- [x]`.
            \\
            \\The plan is automatically re-injected into your system prompt on every iteration,
            \\so the next agent (after compaction, restart, or sub-agent handoff) sees the
            \\same structured progress you do.
            \\
            \\Format suggestion (the agent is free to adapt):
            \\```
            \\## Goal
            \\<one-line summary>
            \\
            \\## Steps
            \\- [x] Step 1 — done
            \\- [ ] Step 2 — in progress
            \\- [ ] Step 3 — pending
            \\
            \\## Notes
            \\<free-form>
            \\```
            \\
            \\Constraints:
            \\- `content` must be 1 byte – 256 KiB. Empty content is rejected.
            \\- The tool overwrites the prior plan every time — there is no merge.
            \\- session_id is implicit (the tool operates on the current session).
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "content", .type = "string", .description = "The full markdown plan body. 1 byte – 256 KiB. Replaces any existing plan. Required." },
            },
            .required = &.{"content"},
        },
    },
};

/// Execute update_plan. Returns an XML string for the LLM.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn executeUpdatePlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: UpdatePlanInput,
) ![]const u8 {
    // The session_id comes from the exec adapter (ctx.session_id), not from input.
    // We pass a placeholder here; the exec adapter injects the real session_id.
    return error.UnreachableUseExecAdapter;
}
```

> **IMPORTANT design note**: The pure fn `executeUpdatePlan` needs the `session_id`, but the input struct doesn't carry it (D3). The pure-fn API becomes:

Replace the `executeUpdatePlan` signature with the explicit-session-id form (mirrors `agent_memories.saveMemory` taking its own `SaveMemoryArgs` struct, not borrowing from context):

```zig
/// Pure-fn API used by the exec adapter. The exec adapter pulls
/// `session_id` from `ToolExecContext` and calls this.
pub fn executeUpdatePlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    input: UpdatePlanInput,
) ![]const u8 {
    const updated_at = session_plan.savePlan(allocator, db, .{
        .session_id = session_id,
        .content = input.content,
    }) catch |err| {
        const msg = switch (err) {
            error.InvalidContent => "content must be non-empty (1 byte minimum)",
            error.ContentTooLarge => "content exceeds the 256 KiB per-plan cap",
            error.InvalidSessionId => "session_id is required (this is a bug — exec adapter should pass ctx.session_id)",
            else => @errorName(err),
        };
        return errorXml(allocator, msg);
    };
    defer allocator.free(updated_at);

    return successXml(allocator, session_id, updated_at);
}

fn successXml(allocator: std.mem.Allocator, session_id: []const u8, updated_at: []const u8) ![]u8 {
    const sid_e = try xmlEscape(allocator, session_id);
    defer allocator.free(sid_e);
    const ts_e = try xmlEscape(allocator, updated_at);
    defer allocator.free(ts_e);
    return std.fmt.allocPrint(allocator,
        "<update_plan>" ++
        "<session_id>{s}</session_id>" ++
        "<updated_at>{s}</updated_at>" ++
        "</update_plan>",
        .{ sid_e, ts_e });
}

fn errorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<update_plan><error>{s}</error></update_plan>",
        .{escaped});
}
```

> The test signature needs to pass `session_id` explicitly. Update the tests above to call `executeUpdatePlan(allocator, db, "test_session", .{ .content = "..." })`.

### Step 2.3 — Run tests, expect PASS

```bash
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

- [ ] All 4 `update_plan_test.zig` tests pass
- [ ] No regression

### Step 2.4 — Commit

```bash
git add src/modules/agent/tools/update_plan.zig \
        src/modules/agent/tools/update_plan_test.zig

git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(plan): update_plan tool — pure-fn layer + JSON schema

Adds the update_plan agent tool's pure-fn layer. JSON schema
declares one required string param (content); session_id is
implicit (D3 — pulled from ToolExecContext in the exec adapter).
Description explicitly tells the agent to overwrite the plan
after every checklist item, flipping - [ ] to - [x].

Pure-fn tests cover success path (returns session_id + updated_at),
empty content (InvalidContent), oversized content (ContentTooLarge),
and JSON-schema shape (name, required, properties).

Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
Task 2 of 9"
```

---

## Task 3 — Tool module: `get_plan` (pure-fn layer)

> **Outcome**: `src/modules/agent/tools/get_plan.zig` exists with `get_plan_tool` JSON schema, `GetPlanInput` struct, and `executeGetPlan(allocator, db, session_id)` that calls `session_plan.getPlan`. Returns `<get_plan><plan>...</plan></get_plan>` when present, `<get_plan><empty/></get_plan>` when absent (D6). Pure-fn tests pass.

### Step 3.1 — Write the failing pure-fn test

Create `src/modules/agent/tools/get_plan_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");
const get_plan_mod = @import("get_plan.zig");
const update_plan_mod = @import("update_plan.zig");
const session_plan = @import("../../../ai_workflow/tui/agentic_loop/session_plan.zig");

fn setupDb(allocator: std.mem.Allocator) !*sqlite.SqliteBackend {
    var db = try sqlite.SqliteBackend.initInMemory(allocator);
    errdefer db.deinit();
    var mgr = migration.MigrationManager.init(allocator, db);
    try migration.registerAllMigrations(&mgr);
    try mgr.runMigrations();
    return db;
}

test "executeGetPlan: returns the plan when present" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();

    try update_plan_mod.executeUpdatePlan(allocator, db, "s1", .{
        .content = "# Plan\n- [x] done\n- [ ] pending\n",
    });

    const result = try get_plan_mod.executeGetPlan(allocator, db, "s1");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<get_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "# Plan") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[x] done") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[ ] pending") != null);
}

test "executeGetPlan: returns <empty/> when no plan exists (D6)" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();

    const result = try get_plan_mod.executeGetPlan(allocator, db, "nonexistent");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<get_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<empty/>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<plan>") == null); // no <plan> tag when absent
}

test "executeGetPlan: XML-escapes special chars in plan_md" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();

    try update_plan_mod.executeUpdatePlan(allocator, db, "esc", .{
        .content = "Note: <hello> & 'world'",
    });

    const result = try get_plan_mod.executeGetPlan(allocator, db, "esc");
    defer allocator.free(result);

    // The raw '<hello>' must be escaped to '&lt;hello&gt;' inside <plan>
    try testing.expect(std.mem.indexOf(u8, result, "&lt;hello&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, result, "&amp;") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<plan>Note: <hello>") == null); // NOT raw
}

test "get_plan_tool JSON schema: name='get_plan', no required params" {
    try testing.expectEqualStrings("get_plan", get_plan_mod.get_plan_tool.function.name);
    // No required: get_plan needs no input (operates on current session)
    try testing.expectEqual(@as(usize, 0), get_plan_mod.get_plan_tool.function.parameters.required.len);
    try testing.expectEqual(@as(usize, 0), get_plan_mod.get_plan_tool.function.parameters.properties.len);
}
```

### Step 3.2 — Implement `get_plan.zig`

Create `src/modules/agent/tools/get_plan.zig`. Mirror `load_memory.zig`'s structure:

```zig
//! Agent-callable tool: `get_plan` — fetch the agent's current task plan.
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task: task_1787073929852_8
//!
//! Wire shape:
//!   input:  {} (no params — session_id is implicit)
//!   output: <get_plan><plan><![CDATA[...markdown...]]></plan></get_plan>
//!   or:     <get_plan><empty/></get_plan> (when no plan set)
//!
//! The actual read lives in `session_plan.getPlan`. This file is a thin
//! XML wrapper (mirrors the `load_memory.zig` pattern).
//!
//! CDATA wrapping: the plan content is wrapped in CDATA so the raw
//! `<`, `>`, `&` inside user-written markdown never breaks the XML envelope
//! (same pattern as `enrichCompactionXml`'s session_skills section).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const session_plan = nalarcore.session_plan;

/// Input for `get_plan`. Empty struct — no params, session_id is implicit.
pub const GetPlanInput = struct {};

/// Top-level tool definition for the LLM.
pub const get_plan_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "get_plan",
        .description =
            \\Fetch the agent's current task plan for this session. Returns the markdown
            \\body wrapped in `<plan><![CDATA[...]]></plan>`, or `<empty/>` when no plan
            \\has been set yet (use `update_plan` to lay one out).
            \\
            \\The plan is also re-injected into your system prompt on every iteration,
            \\so calling `get_plan` is mostly useful for explicit verification, or after
            \\you've made several changes and want to see the current state without
            \\scrolling back through the system prompt.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
    },
};

/// Pure-fn API used by the exec adapter.
pub fn executeGetPlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    const plan = try session_plan.getPlan(allocator, db, session_id);
    defer allocator.free(plan);

    if (plan.len == 0) {
        return allocator.dupe(u8, "<get_plan><empty/></get_plan>");
    }

    // CDATA escape: XML CDATA sections cannot contain `]]>`. Split if needed.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<get_plan><plan><![CDATA[\n");
    if (std.mem.indexOf(u8, plan, "]]>") == null) {
        try out.appendSlice(allocator, plan);
    } else {
        var rest = plan;
        while (std.mem.indexOf(u8, rest, "]]>")) |idx| {
            try out.appendSlice(allocator, rest[0..idx]);
            try out.appendSlice(allocator, "]]><![CDATA[>");
            rest = rest[idx + 3 ..];
        }
        try out.appendSlice(allocator, rest);
    }
    try out.appendSlice(allocator, "\n]]></plan></get_plan>");
    return out.toOwnedSlice(allocator);
}
```

### Step 3.3 — Run tests, expect PASS

```bash
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

- [ ] All 4 `get_plan_test.zig` tests pass
- [ ] No regression

### Step 3.4 — Commit

```bash
git add src/modules/agent/tools/get_plan.zig \
        src/modules/agent/tools/get_plan_test.zig

git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(plan): get_plan tool — pure-fn layer + JSON schema

Adds the get_plan agent tool's pure-fn layer. JSON schema declares
zero required params (session_id is implicit per D3). Returns the
plan wrapped in CDATA inside <plan>...</plan>, or <empty/> when
absent (D6).

Pure-fn tests cover present + absent branches + XML escape via
CDATA wrapping (matches the enrichCompactionXml session_skills
pattern for free-form content).

Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
Task 3 of 9"
```

---

## Task 4 — Exec adapters (`tools_exec_update_plan.zig`, `tools_exec_get_plan.zig`)

> **Outcome**: Both tools are wired into the dispatcher via thin exec adapters. `execUpdatePlan` pulls `session_id` from `ctx.session_id` and calls `update_plan_mod.executeUpdatePlan`. `execGetPlan` does the same for get_plan. Both wrap results via `wrapToolOutput`. Exec-wrapper tests pin the wire contract end-to-end.

### Step 4.1 — Write the failing exec-wrapper test

Create `src/ai_workflow/tui/agentic_loop/tools_exec_update_plan_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");
const tools = @import("tools.zig");
const update_plan_mod = @import("../../../modules/agent/tools/update_plan.zig");

fn setupDb(allocator: std.mem.Allocator) !*sqlite.SqliteBackend {
    var db = try sqlite.SqliteBackend.initInMemory(allocator);
    errdefer db.deinit();
    var mgr = migration.MigrationManager.init(allocator, db);
    try migration.registerAllMigrations(&mgr);
    try mgr.runMigrations();
    return db;
}

fn fakeToolCall(name: []const u8, args: []const u8) @import("nalarcore").agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = args },
    };
}

test "execUpdatePlan: writes to session_plan and returns wrapped success" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();
    const io = std.Io.Threaded.init(allocator);
    defer io.deinit();

    var logger_buf: [4096]u8 = undefined;
    var logger = std.log.testing.logger(&logger_buf);
    _ = &logger_buf;

    const ctx = tools.ToolExecContext{
        .allocator = allocator,
        .io = io,
        .db = db,
        .logger = &logger,
        .session_id = "sess_exec",
        .model = "gpt-4",
        .cwd = "/tmp",
        .api_key = "test",
        .base_url = "http://test",
        .config = undefined,
        .agent_temperature = undefined,
        .is_thinking = undefined,
    };

    const tc = fakeToolCall("update_plan", "{\"content\":\"# Plan\\n- [ ] step\"}");
    const result = try tools.execUpdatePlan(ctx, tc);
    defer allocator.free(result.output);

    // The wrapped envelope contains a <success>true</success> and an inner <update_plan>...</update_plan>
    try testing.expect(std.mem.indexOf(u8, result.output, "<tool name=\"update_plan\">") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>true</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<session_id>sess_exec</session_id>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<updated_at>") != null);

    // Verify the row landed in session_plan
    const got = try @import("nalarcore").session_plan.getPlan(allocator, db, "sess_exec");
    defer allocator.free(got);
    try testing.expectEqualStrings("# Plan\n- [ ] step", got);
}

test "execUpdatePlan: empty content returns wrapped error with success=false" {
    // ... mirror the success test but with content=""
    // Asserts <success>false</success> and <error>non-empty</error>
}

test "execUpdatePlan: malformed JSON returns wrapped parse error" {
    // ... pass garbage arguments, expect <success>false</success><error>parse...</error>
}
```

> **NOTE on the test harness**: The above test shape may need adaptation to match the actual `ToolExecContext` struct's required fields (logger, agent_temperature, is_thinking — these are pointers; the test pattern needs to allocate scratch storage). Reference `tools_exec_write_file_test.zig` and `tools_exec_load_memory_test.zig` for the exact scaffolding. Mirror their pattern rather than guessing.

### Step 4.2 — Implement the exec adapters

Create `src/ai_workflow/tui/agentic_loop/tools_exec_update_plan.zig`. Mirror `tools_exec_save_memory.zig`'s structure exactly:

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const update_plan_mod = nalarcore.update_plan;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execUpdatePlan(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        update_plan_mod.UpdatePlanInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "update_plan failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = update_plan_mod.executeUpdatePlan(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "update_plan failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the <update_plan><error>...</error></update_plan> shape
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

Create `src/ai_workflow/tui/agentic_loop/tools_exec_get_plan.zig`. Same pattern, slightly simpler (no parse):

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const get_plan_mod = nalarcore.get_plan;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execGetPlan(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = tc; // No input to parse.

    const inner = get_plan_mod.executeGetPlan(ctx.allocator, ctx.db, ctx.session_id) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "get_plan failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "get_plan", "{}", false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "get_plan", "{}", true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

### Step 4.3 — Register re-exports

Edit `src/ai_workflow/tui/agentic_loop/tools.zig`. Add at the end of the `pub const execXxx = ...` block (after `execSpawnSubAgent` at line 61):

```zig
// 2026-08-19 — session_plan agent tools (Task 4 of 2026-08-19-session-plan-agent-tool.md).
pub const execUpdatePlan = @import("tools_exec_update_plan.zig").execUpdatePlan;
pub const execGetPlan = @import("tools_exec_get_plan.zig").execGetPlan;
```

### Step 4.4 — Wire into `tools_equipped.zig`

Edit `src/ai_workflow/tui/agentic_loop/tools_equipped.zig`. Add the module imports at the top (after the other `const xxx_mod = ...` declarations):

```zig
// 2026-08-19 — session_plan agent tools.
const update_plan_mod = nalarcore.update_plan;
const get_plan_mod = nalarcore.get_plan;
```

Add entries to `equips()` (inside the `comptime &[_]AgentTool{ ... }` block, grouped near `update_activity` which is also an "agent control" tool that influences future behaviour):

```zig
update_plan_mod.update_plan_tool,
get_plan_mod.get_plan_tool,
```

Add entries to `UNIFIED_TOOL_REGISTRY()`:

```zig
// === PLAN TOOLS ===
// 2026-08-19 — session_plan agent tools. UPSERT / fetch the agent's
// markdown task plan with a - [ ] / - [x] checklist. See plan
// 2026-08-19-session-plan-agent-tool.md.
.{ .name = "update_plan", .exec = tools.execUpdatePlan, .tool_def = update_plan_mod.update_plan_tool },
.{ .name = "get_plan", .exec = tools.execGetPlan, .tool_def = get_plan_mod.get_plan_tool },
```

### Step 4.5 — Wire into `src/root.zig`

Edit `src/root.zig`. Add the module re-exports in the appropriate section (near `update_activity` at line 532):

```zig
// 2026-08-19 — session_plan agent tools (Task 4 of 2026-08-19-session-plan-agent-tool.md).
pub const update_plan = @import("modules/agent/tools/update_plan.zig");
pub const get_plan = @import("modules/agent/tools/get_plan.zig");
pub const session_plan = @import("ai_workflow/tui/agentic_loop/session_plan.zig");
```

> Also add `pub const session_plan = ...` if it's not already there. Check first — the explore report didn't surface it (it surfaced `agent_memories` at line 563). Add `session_plan` right after `agent_memories`.

### Step 4.6 — Run tests, expect PASS

```bash
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

- [ ] All `tools_exec_update_plan_test.zig` + `tools_exec_get_plan_test.zig` tests pass
- [ ] No regression
- [ ] `tools_equipped.UNIFIED_TOOL_REGISTRY()` includes both tools

### Step 4.7 — Commit

```bash
git add src/ai_workflow/tui/agentic_loop/tools_exec_update_plan.zig \
        src/ai_workflow/tui/agentic_loop/tools_exec_get_plan.zig \
        src/ai_workflow/tui/agentic_loop/tools_exec_update_plan_test.zig \
        src/ai_workflow/tui/agentic_loop/tools_exec_get_plan_test.zig \
        src/ai_workflow/tui/agentic_loop/tools.zig \
        src/ai_workflow/tui/agentic_loop/tools_equipped.zig \
        src/root.zig

git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(plan): wire update_plan + get_plan into tool dispatcher

Thin exec adapters parse the JSON input, call the pure fn with
ctx.session_id (D3), and wrap results via wrapToolOutput. Tools
registered in tools_equipped.zig's equips() + UNIFIED_TOOL_REGISTRY()
and re-exported through tools.zig + src/root.zig (the
nalarcore.update_plan / nalarcore.get_plan / nalarcore.session_plan
aliases).

Exec-wrapper tests pin the wire contract end-to-end: success path
writes to session_plan, error path surfaces <success>false</success>,
malformed-JSON path returns a parse error envelope.

Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
Task 4 of 9"
```

---

## Task 5 — System prompt injection: `prompts_make_plan_context.zig` + `buildMessages` hook

> **Outcome**: A new `prompts_make_plan_context.zig` helper reads `session_plan` and renders a `## Current Plan` markdown block (or empty string when no plan exists). `prompts_build_messages_for_agent_prompt.zig` calls it and appends the result to `final_system` between the `inherited_md` block and the `toOwnedSlice` step, so every iteration sees the current plan.

### Step 5.1 — Write the failing helper test

Create `src/ai_workflow/tui/agentic_loop/prompts_make_plan_context_test.zig`. Mirror the structure of `prompts_make_kanban_context.zig` (use the inline `test "..."` pattern at the bottom of the source file rather than a separate file). Actually, the kanban helper has tests in its own file. Mirror that pattern.

```zig
const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");
const plan_ctx = @import("prompts_make_plan_context.zig");
const update_plan_mod = @import("../../../modules/agent/tools/update_plan.zig");

fn setupDb(allocator: std.mem.Allocator) !*sqlite.SqliteBackend {
    var db = try sqlite.SqliteBackend.initInMemory(allocator);
    errdefer db.deinit();
    var mgr = migration.MigrationManager.init(allocator, db);
    try migration.registerAllMigrations(&mgr);
    try mgr.runMigrations();
    return db;
}

test "makePlanContext: empty plan returns empty string (silently omitted from system prompt)" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();

    const got = try plan_ctx.makePlanContext(allocator, db, "no_plan");
    defer allocator.free(got);
    try testing.expectEqualStrings("", got);
}

test "makePlanContext: present plan renders ## Current Plan markdown block" {
    const allocator = testing.allocator;
    const db = try setupDb(allocator);
    defer db.deinit();

    try update_plan_mod.executeUpdatePlan(allocator, db, "s1", .{
        .content = "# Goal\n\n- [x] done\n- [ ] pending",
    });

    const got = try plan_ctx.makePlanContext(allocator, db, "s1");
    defer allocator.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "## Current Plan") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Use `update_plan`") != null);
    try testing.expect(std.mem.indexOf(u8, got, "[x] done") != null);
    try testing.expect(std.mem.indexOf(u8, got, "[ ] pending") != null);
}

test "makePlanContext: plan survives DB read across calls (UPSERT consistency)" {
    // Write v1, read; write v2, read; assert each call sees the latest version.
}
```

Run, expect FAIL:

```bash
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

- [ ] Failing tests confirmed

### Step 5.2 — Implement `prompts_make_plan_context.zig`

Create `src/ai_workflow/tui/agentic_loop/prompts_make_plan_context.zig`. Mirror `prompts_make_kanban_context.zig`'s structure (early-return "" on empty session_id, log+"" on DB error, render a markdown block):

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const session_plan = nalarcore.session_plan;

/// Build a "## Current Plan" section for the system prompt. Reads
/// `session_plan` for the current session and renders the markdown
/// inside a labelled block, with explicit instructions for the agent
/// to call `update_plan` after every checklist item.
///
/// Returns `""` when no plan exists (silently omitted from the system
/// prompt, matching `makeKanbanContext`'s empty-case behavior).
///
/// Block shape when present:
///
/// ```markdown
/// ## Current Plan
///
/// This session has an active task plan. **You MUST keep it in sync**
/// by calling the `update_plan` tool after completing each checklist
/// item (flip `- [ ]` → `- [x]`). The plan is also re-injected into
/// every iteration of your loop, so you always see the current state.
///
/// <![CDATA[
/// <full plan markdown, raw>
/// ]]>
///
/// Last updated: <iso timestamp>
/// ```
pub fn makePlanContext(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    const row = session_plan.getPlanOpt(allocator, db, session_id) catch |err| {
        std.log.warn("BuildPlanContext: getPlanOpt failed: {}", .{err});
        return allocator.dupe(u8, "");
    };
    defer if (row) |r| r.deinit(allocator);

    const plan_row = row orelse return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Current Plan\n\n");
    try out.appendSlice(allocator,
        \\This session has an active task plan. **You MUST keep it in sync**
        \\by calling the `update_plan` tool after completing each checklist
        \\item (flip `- [ ]` → `- [x]`). The plan is automatically re-injected
        \\into your system prompt on every iteration, so you always see the
        \\current state.
        \\
    );
    try out.appendSlice(allocator, "\n```markdown\n");
    try out.appendSlice(allocator, plan_row.plan_md);
    try out.appendSlice(allocator, "\n```\n");
    if (plan_row.updated_at.len > 0) {
        try out.appendSlice(allocator, "\n_Last updated: ");
        try out.appendSlice(allocator, plan_row.updated_at);
        try out.appendSlice(allocator, "_\n");
    }

    return out.toOwnedSlice(allocator);
}
```

### Step 5.3 — Re-export from `prompts.zig`

Edit `src/ai_workflow/tui/agentic_loop/prompts.zig`. Add at the end of the file:

```zig
pub const makePlanContext = @import("prompts_make_plan_context.zig").makePlanContext;
```

### Step 5.4 — Hook into `buildMessages`

Edit `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig`. After the `inherited_md` block (line 168), add:

```zig
// Build the "## Current Plan" section. Reads session_plan for the
// current session_id. Returns "" when no plan exists (silently omitted).
// Mirrors the kanban/design pattern (graceful-skip on empty, render
// between context sections and the inherited context block).
const planContent = try agentic_loop.prompts_mod.makePlanContext(allocator, db, session_id);
defer allocator.free(planContent);
```

Then inside the `final_system.appendSlice` chain (lines 170-176), inject the plan content between the inherited_md block and the `toOwnedSlice` step:

```zig
var final_system: std.ArrayList(u8) = .empty;
defer final_system.deinit(allocator);
try final_system.appendSlice(allocator, systemContent);
if (inherited_md.len > 0) {
    try final_system.appendSlice(allocator, "\n\n");
    try final_system.appendSlice(allocator, inherited_md);
}
if (planContent.len > 0) {
    try final_system.appendSlice(allocator, "\n\n");
    try final_system.appendSlice(allocator, planContent);
}
const final_system_content = try final_system.toOwnedSlice(allocator);
```

> Note: The `planContent` block renders BEFORE the inherited_md block on subsequent edits if you prefer. The exact ordering (inherited first vs plan first) is a UX call — pick one and stick with it. Plan-first means "here's what YOU were doing, now here's what your parent did" — natural reading order.

### Step 5.5 — Run tests, expect PASS

```bash
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

- [ ] All `prompts_make_plan_context_test.zig` tests pass
- [ ] No regression
- [ ] Manual smoke: start an agent with a plan, run for several iterations, verify the system prompt contains the plan each time (print debug + grep)

### Step 5.6 — Commit

```bash
git add src/ai_workflow/tui/agentic_loop/prompts_make_plan_context.zig \
        src/ai_workflow/tui/agentic_loop/prompts_make_plan_context_test.zig \
        src/ai_workflow/tui/agentic_loop/prompts.zig \
        src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig

git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(plan): inject current plan into system prompt on every iteration

New makePlanContext helper reads session_plan and renders a
'## Current Plan' markdown block with explicit instructions to
call update_plan after every checklist item. Hooked into
buildMessages between the inherited_md block and the final
system-message construction (mirrors the kanban/design pattern).

Empty plan → silently omitted (matches makeKanbanContext's
empty-case behavior). Tests cover empty + present branches.

Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
Task 5 of 9"
```

---

## Task 6 — Compaction enrichment: `<plan>` section in `enrichCompactionXml`

> **Outcome**: When compaction fires, the current plan is fetched BEFORE the messages are marked `is_feed_to_llm=0`, and embedded as a `<plan>` section in the `<compaction_context>` envelope. The post-compaction agent sees the structured plan in the compact_messages user-role row.

### Step 6.1 — Write the failing helper test

The existing `workflow_compaction_envelope_test.zig` has 50+ tests for `enrichCompactionXml`. Add 3 new tests:

```zig
test "enrichCompactionXml embeds <plan> when session_plan has a plan" {
    // Setup: session_plan with content "## Goal\n- [ ] step"
    // Setup: minimal compaction inputs (empty user_turns, empty read_files, etc.)
    // Call enrichCompactionXml with the plan
    // Assert the output contains "<plan>" + "<![CDATA[" + the plan content + "]]></plan>"
}

test "enrichCompactionXml omits <plan> when session_plan is empty/absent" {
    // Same setup but no plan row
    // Assert the output does NOT contain "<plan>"
}

test "enrichCompactionXml CDATA-escapes ]]> sequences in plan content" {
    // Setup: plan content containing the literal "]]>" sequence
    // Assert the output splits the CDATA cleanly
}
```

> Reference the existing test file pattern (it uses a real sqlite in-memory DB + runs migrations). The test currently sets up user_turns / read_files / recent_activities / session_skills fixtures; add a `setupPlan` fixture for the new param.

### Step 6.2 — Add `fetchSessionPlan` helper

Edit `src/ai_workflow/tui/agentic_loop/workflow_compact_message.zig`. Add a new helper near the other `fetch*` helpers (lines 277-322):

```zig
/// Fetch the current session plan for the compaction envelope. Returns
/// `null` when no plan exists (matches the convention used by the other
/// compaction fetchers). Caller owns the returned `PlanRow` and must
/// call `.deinit(allocator)` on it (or `null`).
pub fn fetchSessionPlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?session_plan_mod.PlanRow {
    return session_plan_mod.getPlanOpt(allocator, db, session_id);
}
```

Add the import at the top of the file:

```zig
const session_plan_mod = nalarcore.session_plan;
```

### Step 6.3 — Add `plan` parameter to `enrichCompactionXml`

Edit `src/ai_workflow/tui/agentic_loop/workflow_compact_message.zig`. Update the signature (line 298):

```zig
pub fn enrichCompactionXml(
    allocator: std.mem.Allocator,
    compacted_xml: []const u8,
    user_turns: []const UserTurn,
    read_files: []const ReadFileTurn,
    recent_activities: []const RecentActivity,
    session_skills: []const llm_history.SkillInfo,
    /// Optional plan row fetched BEFORE mark_history_not_for_llmrun.
    /// `null` when no plan exists (silently omitted from the envelope).
    plan: ?session_plan_mod.PlanRow,
    cwd: []const u8,
) ![]u8 {
```

Insert the `<plan>` section AFTER `<session_skills>` (line 424) and BEFORE `<summary>` (line 426):

```zig
    // ── plan (current task plan, when set) ─────────────────────────
    // Mirrors the session_skills pattern: omitted entirely when absent
    // so the envelope stays clean for sessions without a plan. Wrapped
    // in CDATA so the raw `<`, `>`, `&` inside the plan markdown never
    // breaks the envelope.
    if (plan) |p| {
        try out.appendSlice(allocator, "  <plan");
        if (p.updated_at.len > 0) {
            try out.print(allocator, " updated_at=\"{s}\"", .{p.updated_at});
        }
        try out.appendSlice(allocator, ">\n    <content><![CDATA[\n");
        if (std.mem.indexOf(u8, p.plan_md, "]]>") == null) {
            try out.appendSlice(allocator, p.plan_md);
        } else {
            var rest = p.plan_md;
            while (std.mem.indexOf(u8, rest, "]]>")) |idx| {
                try out.appendSlice(allocator, rest[0..idx]);
                try out.appendSlice(allocator, "]]><![CDATA[>");
                rest = rest[idx + 3 ..];
            }
            try out.appendSlice(allocator, rest);
        }
        try out.appendSlice(allocator, "\n    ]]></content>\n  </plan>\n");
    }
```

### Step 6.4 — Update `enrichCompactionXml`'s caller

Edit `src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig`. After the `session_skills` fetch (line 322), add:

```zig
// Current task plan — fetched BEFORE mark_history_not_for_llmrun so
// the next iteration's enriched INSERT carries the plan forward.
// `null` when no plan exists (silently omitted from the envelope).
const session_plan_row = compact_message.fetchSessionPlan(allocator, db, session_id) catch |err| {
    logger.warnFmt("[COMPACTION] fetchSessionPlan failed: {s}", .{@errorName(err)});
    break :blk null;
};
defer if (session_plan_row) |*p| p.deinit(allocator);
```

Update the `enrichCompactionXml` call (line 324) to pass the new param:

```zig
const enriched_xml = compact_message.enrichCompactionXml(
    allocator,
    compacted_xml,
    user_turns.items,
    read_files.items,
    recent_activities.items,
    session_skills,
    session_plan_row,
    cwd,
) catch ...;
```

### Step 6.5 — Update `workflow.zig`'s re-export (if applicable)

`workflow.zig:83` re-exports `enrichCompactionXml` for test access. Since the signature changed, verify the re-export still works (it just points at the function). If `workflow.zig` itself calls `enrichCompactionXml` directly (it might not — the call is in `workflow_commpact_message.zig`), update that call site too.

### Step 6.6 — Run tests, expect PASS

```bash
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

- [ ] All `workflow_compaction_envelope_test.zig` tests pass (existing + new)
- [ ] No regression in `workflow_commpact_message.zig`'s integration tests

### Step 6.7 — Manual smoke

Boot the desktop app on port 8080. Start an agent, give it a multi-step task. Once the agent calls `update_plan`, then artificially trigger compaction by sending a long message or pressing the manual `/compact` button (if available). Verify the new `<compact_messages>` envelope in `llm_history` contains `<plan>...</plan>`:

```bash
sqlite3 ~/.local/share/nalar/data.db "SELECT substr(response_content, 1, 500) FROM llm_history WHERE role='user' AND response_content LIKE '%compact_messages%' ORDER BY created_at DESC LIMIT 1;"
```

Expected output includes `<plan updated_at="..."><content><![CDATA[...]]></content></plan>`.

- [ ] Compact envelope contains `<plan>` block

### Step 6.8 — Commit

```bash
git add src/ai_workflow/tui/agentic_loop/workflow_compact_message.zig \
        src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig \
        src/ai_workflow/tui/agentic_loop/workflow_compaction_envelope_test.zig \
        src/ai_workflow/tui/agentic_loop/workflow.zig

git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(plan): embed <plan> section in compaction envelope

When compaction fires, fetch the current session_plan row BEFORE
mark_history_not_for_llmrun and embed it as a <plan><content>
CDATA section in the <compaction_context> envelope (mirrors the
session_skills pattern).

Post-compaction agent sees the structured plan in the compact_messages
user-role row alongside user_history, read_files, recent_activities,
and session_skills. CDATA wrapping protects against ]]> sequences
inside the plan body.

3 new tests: plan present, plan absent (omitted), CDATA split on ]]>.
Manual smoke verifies the envelope on a real compaction event.

Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
Task 6 of 9"
```

---

## Task 7 — Tool description enhancement + system prompt hint

> **Outcome**: The static `## Your Active Agent Configuration` section (or equivalent) gets a hint about the plan tool. The tool descriptions already say "call `update_plan` after every checklist item"; this task adds a small nudge in the system prompt itself so the agent remembers even on first iteration.

### Step 7.1 — Add plan hint to PROMPT_SECTIONS

The system prompt builder (`src/modules/agent/prompts.zig`) has a `PROMPT_SECTIONS` array of static markdown blocks rendered before the dynamic context. Look for that array (around line 285-336 based on the explored file structure). Add a new section that's gated on having the `update_plan` tool equipped (use the `.requires_tool` field):

```zig
// In PROMPT_SECTIONS, add:
.{
    .content =
        \\## Task Planning
        \\
        \\For multi-step work, lay out a structured plan early with the `update_plan` tool, then
        \\keep it in sync by calling `update_plan` after completing each checklist item (flip
        \\`- [ ]` → `- [x]`). The plan is automatically re-injected into your system prompt on
        \\every iteration, so you always see the current state. Use `get_plan` to verify the
        \\current state explicitly.
        \\
    ,
    .requires_tool = "update_plan",
},
```

### Step 7.2 — Run tests, expect PASS (no test changes needed)

```bash
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 180 zig build test --summary all 2>&1 | tail -n 30
```

- [ ] No regression

### Step 7.3 — Commit

```bash
git add src/modules/agent/prompts.zig

git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(plan): nudge the agent about update_plan in the system prompt

Adds a static '## Task Planning' section to PROMPT_SECTIONS that's
gated on the update_plan tool being equipped. Reinforces the
'use update_plan to track multi-step work' hint that the tool
description already carries, so the agent remembers on the very
first iteration (before it's seen any prior tool calls).

Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
Task 7 of 9"
```

---

## Task 8 — Optional UI: render `update_plan` + `get_plan` tool cards

> **Outcome**: When the LLM calls `update_plan` or `get_plan`, the chatview shows a compact tool card with a checklist summary (instead of the generic collapsed pill). The card is collapsible and shows the plan content with checkbox rendering.

### Step 8.1 — Write the failing component test

Create `src/apps/desktop/src/__tests__/ChatView.updatePlan.spec.ts`:

```ts
/**
 * Tests for the update_plan + get_plan tool dispatcher in ChatView.vue.
 *
 * The component imports UpdatePlan.vue + GetPlan.vue which must be
 * stubbed via vi.mock(...) following the SubAgentPeekPanel.spec.ts
 * pattern.
 *
 * Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
 *   Task 8
 */
import { afterEach, beforeBefore,,,expect, it, vi } from 'vitest'
// ... (mirror the SubAgentPeekPanel.spec.ts scaffolding)
```

### Step 8.2 — Create `UpdatePlan.vue` + `GetPlan.vue`

Create `src/apps/desktop/src/components/tool_outputs/UpdatePlan.vue`. A simple component that takes the `update_plan` XML envelope and renders the new content as a checklist summary. Use the existing `ToolCardHeader.vue` chrome. Render checklist items (`- [x]` / `- [ ]`) as HTML checkboxes.

Create `src/apps/desktop/src/components/tool_outputs/GetPlan.vue`. Same shape, but for the read-back path.

### Step 8.3 — Wire into `ChatView.vue`

Edit `src/apps/desktop/src/components/views/ChatView.vue`. Add the new components to the import block (lines 21-49) and add the dispatcher branch in the `v-else-if="group.role === 'tool'"` block (around line 2489):

```vue
<UpdatePlan v-else-if="msg.tool_name === 'update_plan'" :message="msg" />
<GetPlan v-else-if="msg.tool_name === 'get_plan'" :message="msg" />
```

Also add a `renderResponse` branch for the collapsed-bubble summary (around line 175-399):

```ts
} else if (msg.tool_name === 'update_plan') {
  // Extract the new content from <update_plan> envelope (or fall back to the raw args)
  return `update_plan → wrote ${bytes}b of plan`
} else if (msg.tool_name === 'get_plan') {
  return `get_plan → fetched current plan`
}
```

### Step 8.4 — Run tests, expect PASS

```bash
cd /home/ginwa/.worktrees/agent-plan-tool/src/apps/desktop && timeout 120 bunx vitest run ChatView.updatePlan.spec.ts 2>&1 | tail -n 30
```

- [ ] Component tests pass
- [ ] No regression in existing ChatView tests

### Step 8.5 — Type-check

```bash
cd /home/ginwa/.worktrees/agent-plan-tool/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20
```

- [ ] vue-tsc passes with no errors

### Step 8.6 — Commit

```bash
git add src/apps/desktop/src/components/tool_outputs/UpdatePlan.vue \
        src/apps/desktop/src/components/tool_outputs/GetPlan.vue \
        src/apps/desktop/src/components/views/ChatView.vue \
        src/apps/desktop/src/__tests__/ChatView.updatePlan.spec.ts

git -c user.name=ginwa -c user.email=ginwa@local commit -m "feat(plan): render update_plan + get_plan as checklist cards in chatview

Adds two new tool-output components (UpdatePlan.vue, GetPlan.vue)
that render the tool result as a collapsible checklist card with
checkbox rendering for - [ ] / - [x] items. Wired into ChatView.vue's
tool dispatcher (lines ~2489) alongside the existing per-tool cards.

The collapsed-bubble summary (renderResponse) shows 'update_plan →
wrote N bytes' / 'get_plan → fetched current plan' so users can
track plan activity at a glance.

Behavioural test stubs the new components via vi.mock(...) following
the SubAgentPeekPanel.spec.ts pattern. vue-tsc type-check + bunx
vitest pass.

Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
Task 8 of 9"
```

---

## Task 9 — Docs: SPEC.md + NALAR.md

> **Outcome**: SPEC.md has a new section (§3.X) documenting the plan tool + the system-prompt + compaction-enrichment integration. NALAR.md has a Recent-changes bullet. The PR index entry is added.

### Step 9.1 — Update SPEC.md

Edit `docs/SPEC.md`. Append a new section after the existing kanban-task-detail-start-agent plan's §3.7.X entry (search for "2026-08-18-kanban-task-detail-start-agent"):

```markdown
#### 3.7.X Session-scoped plan tools: `update_plan` + `get_plan` (2026-08-19)

Two new agent-callable tools persist a per-session structured task plan (markdown with a `- [ ]` / `- [x]` checklist) in the new `session_plan` table. One row per `sessions.id`; `update_plan` overwrites the row on every call (UPSERT), `get_plan` fetches it.

Wire shape:
- `update_plan(content)` → `<update_plan><session_id>...</session_id><updated_at>...</updated_at></update_plan>`
- `get_plan()` → `<get_plan><plan><![CDATA[...markdown...]]></plan></get_plan>` or `<get_plan><empty/></get_plan>`

Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md

Design decisions (full list in plan §Design Decisions):
- D1: dedicated `session_plan` table (1:1 with `sessions`, session_id TEXT PK)
- D2: no FK constraint to `sessions.id` (matches `session_activity` / `llm_history` precedent)
- D3: `session_id` is implicit from `ToolExecContext.session_id` (LLM never passes it)
- D4: UPSERT overwrite (no history table in v1)
- D7: 256 KiB content cap (smaller than `agent_memories`'s 1 MiB because plan is injected into system prompt)
- D8: injection in TWO places — (a) system prompt via `prompts_make_plan_context.zig`, (b) compaction envelope via new `<plan>` section

User-visible behaviour: when an agent runs on a kanban task that requires multi-step work, it calls `update_plan` with a markdown checklist at the start, then re-calls after every step. The plan is visible to the human via the chat bubble's tool chip; the agent itself always sees it in the system prompt; the post-compaction agent always sees it in the compact_messages envelope.

Backward compat: zero — new table, new tools, new optional UI. No existing call sites change behaviour.
```

Also add a PR index entry near the existing 2026-08-19 entries:

```
| `2026-08-19-session-plan-agent-tool.md` | ✅ | `update_plan` + `get_plan` agent tools + `session_plan` table (1:1 with sessions). Plan re-injected on every iteration + survives compaction. See §3.7.X above. |
```

### Step 9.2 — Update NALAR.md

Edit `NALAR.md`. Append a new "Recent changes" entry at the top of the list:

```markdown
- **Agent tools `update_plan` + `get_plan` — session-scoped markdown plan with checklist** (2026-08-19): Two new agent-callable tools (`update_plan` overwrites the plan; `get_plan` fetches it) backed by a new `session_plan` SQLite table (1:1 with `sessions`, session_id TEXT PK, plan_md TEXT NOT NULL, updated_at DATETIME). The plan is plain markdown with a `- [ ]` / `- [x]` checklist; the agent overwrites on every call (UPSERT, 256 KiB cap). Plan is re-injected into every agent iteration (system prompt via `prompts_make_plan_context.zig`) AND embedded as a `<plan>` section in the compaction envelope (via `enrichCompactionXml`) so the next agent after compaction knows what the prior agent was doing. `update_plan` returns `<session_id>` + `<updated_at>`; `get_plan` returns the plan wrapped in CDATA or `<empty/>` when absent. No FK constraint (sessions `session_activity` precedent). `session_id` is implicit (pulled from `ToolExecContext`); the LLM never passes it. Optional UI: `UpdatePlan.vue` + `GetPlan.vue` Vue components render the tool result as a collapsible checklist card in the chatview. Migration: 076 (`create_session_plan`). Branch: `worktree/agent-plan-tool`. Plan: `docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md`.
```

### Step 9.3 — Commit

```bash
git add docs/SPEC.md NALAR.md

git -c user.name=ginwa -c user.email=ginwa@local commit -m "docs: SPEC.md + NALAR.md for update_plan + get_plan tools

SPEC.md §3.7.X documents the new tools, the 1:1 table, the two
injection points (system prompt + compaction envelope), and the
backward-compat story. PR index entry added. NALAR.md Recent
changes summarises the user-visible behaviour for humans.

Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
Task 9 of 9"
```

---

## Verification

Before claiming the work is done, run ALL of the following and confirm each passes:

```bash
# 1. Zig: full test suite
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 300 zig build test --summary all 2>&1 | tail -n 5
# Expected: "all N tests passed" (baseline ~2271 + ~30 new = ~2301)

# 2. Frontend: type-check (if Task 8 was done)
cd /home/ginwa/.worktrees/agent-plan-tool/src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 20
# Expected: vue-tsc completes with no errors

# 3. Frontend: behavioural tests (if Task 8 was done)
cd /home/ginwa/.worktrees/agent-plan-tool/src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 30
# Expected: all tests pass

# 4. Migration: verify 076 runs cleanly on a fresh DB
rm -f /tmp/plan_migration_test.db
cd /home/ginwa/.worktrees/agent-plan-tool && timeout 30 zig build run -- --port 8080 --db /tmp/plan_migration_test.db &
PID=$!
sleep 5
sqlite3 /tmp/plan_migration_test.db "SELECT name FROM sqlite_master WHERE type='table' AND name='session_plan';"
# Expected: session_plan
sqlite3 /tmp/plan_migration_test.db ".schema session_plan"
# Expected: CREATE TABLE session_plan (session_id TEXT PRIMARY KEY, plan_md TEXT NOT NULL DEFAULT '', updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)
kill $PID 2>/dev/null

# 5. Tool registration: verify both tools are in the dispatcher
cd /home/ginwa/.worktrees/agent-plan-tool && grep -rn "update_plan\|get_plan" src/ai_workflow/tui/agentic_loop/tools_equipped.zig
# Expected: matches in both equips() and UNIFIED_TOOL_REGISTRY()

# 6. Manual smoke (port 8080)
# Boot the desktop app, open a kanban task, send "Build a feature X with these steps: A, B, C"
# Verify in the agent's response:
#   - The first iteration calls update_plan with a checklist of A, B, C
#   - Subsequent iterations see "## Current Plan" in the system prompt
#   - After ~10 iterations, the conversation triggers compaction
#   - The new <plan> section appears in the compact_messages envelope (check via DB)
#   - The post-compaction agent sees the plan and continues ticking items
```

---

## Pitfalls (known failure modes)

- **session_id mismatch between exec adapter and storage layer.** The exec adapter pulls `ctx.session_id` from the orchestrator; the storage layer takes it as a parameter. If the orchestrator ever passes a different `session_id` than `ctx.session_id` (e.g. for sub-agents operating on a parent session), the plan would be saved to the wrong row. The pure-fn signature `executeUpdatePlan(allocator, db, session_id, input)` is explicit about this; the exec adapter MUST use `ctx.session_id`. Add a regression test in Task 4 to lock this in.

- **Plan content with `]]>` breaks the CDATA section.** Both `<plan>` blocks (system prompt + compaction envelope) wrap content in CDATA; the literal sequence `]]>` inside user-written markdown would close the CDATA early. The implementation handles this by splitting (mirroring `enrichCompactionXml`'s session_skills pattern). Tests cover this in Task 6.3.

- **Plan inflation by a runaway agent.** If the agent writes a 256 KiB plan every iteration (e.g. copy-pasting prior content), the system prompt grows by 256 KiB per iteration, exhausting the LLM context window fast. The 256 KiB cap is the hard ceiling, but a soft cap + warning (e.g. log a warning if the plan is > 16 KiB on each write) would help. Future work.

- **Race between `update_plan` and compaction.** If compaction fires while `update_plan` is mid-write, the fetch-then-mark pattern in `fetchSessionPlan` (Task 6.4) ensures we read the pre-write state. The agent's UPSERT happens after compaction (via the next iteration's tool call), at which point `makePlanContext` reads the new plan. No data loss, but a race window where the post-compaction agent sees the OLD plan + the just-written plan was lost. The window is microseconds; acceptable for v1.

- **`update_plan(content="")` is rejected, but the agent might want to "clear" the plan.** Document this in the tool description: "to mark no active plan, overwrite with a final marker like `# Plan complete\n\nAll steps done.`". The user didn't ask for a `delete_plan` tool (D9); documenting the workaround in the description is sufficient.

- **The `prompts_make_plan_context.zig` block contains raw markdown that might break the agent's parser.** The block is wrapped in ```` ```markdown ```` fences so the agent's parser sees it as a code block, not as instructions. The "Last updated" line is plain prose. Tested in Task 5.1.

- **`workspace_item_tasks` link is gone.** The plan is per-session, not per-task. If the user opens two kanban tasks that share a session_id (rare — `task.id == session_id` per Migration 052), they'd share the plan. This is the documented behavior; a future `session_plan_v2` could key on `(workspace_id, task_id)` instead. Out of scope.

- **The `getPlanOpt` path is used by the compaction enrich; `getPlan` is used by `executeGetPlan`.** Two entry points, two purposes. Don't unify them — the compaction path needs the `updated_at` timestamp for the envelope attribute, while the tool path just wants the markdown body.

---

## Files touched (summary)

| File | Change |
|---|---|
| `src/migrations/migration.zig` | + `Migration076CreateSessionPlan` struct + entry in `allMigrations` |
| `src/ai_workflow/tui/agentic_loop/session_plan.zig` | NEW — storage layer (savePlan, getPlan, getPlanOpt, MAX_PLAN_BYTES) |
| `src/ai_workflow/tui/agentic_loop/session_plan_test.zig` | NEW — 6 live-DB tests |
| `src/modules/agent/tools/update_plan.zig` | NEW — AgentTool const + UpdatePlanInput struct + executeUpdatePlan pure fn |
| `src/modules/agent/tools/update_plan_test.zig` | NEW — 4 pure-fn tests |
| `src/modules/agent/tools/get_plan.zig` | NEW — AgentTool const + GetPlanInput struct + executeGetPlan pure fn |
| `src/modules/agent/tools/get_plan_test.zig` | NEW — 4 pure-fn tests |
| `src/ai_workflow/tui/agentic_loop/tools_exec_update_plan.zig` | NEW — thin adapter (parse JSON → call pure fn → wrapToolOutput) |
| `src/ai_workflow/tui/agentic_loop/tools_exec_get_plan.zig` | NEW — thin adapter |
| `src/ai_workflow/tui/agentic_loop/tools_exec_update_plan_test.zig` | NEW — 3 exec-wrapper tests |
| `src/ai_workflow/tui/agentic_loop/tools_exec_get_plan_test.zig` | NEW — 1+ exec-wrapper test |
| `src/ai_workflow/tui/agentic_loop/prompts_make_plan_context.zig` | NEW — makePlanContext helper |
| `src/ai_workflow/tui/agentic_loop/prompts_make_plan_context_test.zig` | NEW — 3 helper tests |
| `src/ai_workflow/tui/agentic_loop/prompts.zig` | + `pub const makePlanContext` re-export |
| `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig` | + planContent helper call + append to final_system |
| `src/ai_workflow/tui/agentic_loop/workflow_compact_message.zig` | + fetchSessionPlan helper + <plan> section in enrichCompactionXml |
| `src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig` | + pass session_id + plan to enrichCompactionXml + new fetchSessionPlan call |
| `src/ai_workflow/tui/agentic_loop/workflow.zig` | re-export signature update (if applicable) |
| `src/ai_workflow/tui/agentic_loop/tools.zig` | + execUpdatePlan + execGetPlan re-exports |
| `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` | + const update_plan_mod / get_plan_mod + entries in equips() and UNIFIED_TOOL_REGISTRY() |
| `src/root.zig` | + pub const update_plan / get_plan / session_plan re-exports |
| `src/modules/agent/prompts.zig` | + "## Task Planning" static section gated on update_plan tool |
| `src/apps/desktop/src/components/tool_outputs/UpdatePlan.vue` | NEW — checklist card for update_plan results |
| `src/apps/desktop/src/components/tool_outputs/GetPlan.vue` | NEW — checklist card for get_plan results |
| `src/apps/desktop/src/components/views/ChatView.vue` | + tool dispatcher branches + renderResponse branches |
| `src/apps/desktop/src/__tests__/ChatView.updatePlan.spec.ts` | NEW — behavioural test |
| `docs/SPEC.md` | + §3.7.X new section + PR index entry |
| `NALAR.md` | + Recent changes bullet |

**Total: 13 NEW, 10 EDIT, 1 migration.** No schema change to existing tables. No new dependencies.

---

## Out of scope (deliberate, for follow-up kanban tasks)

- **`session_plan_history` table** for audit trail of every plan write (D4 was deliberate — overwrite only). Future task: add `(version, previous_plan_md, changed_at)` history; the agent could query "what was the plan 3 iterations ago?"
- **Structured checklist parsing** — the storage layer treats plan_md as opaque markdown. A future task could parse `- [ ]` / `- [x]` into a structured checklist table for nicer UI rendering (current Vue components render the raw markdown).
- **Plan search across sessions** — no `search_plans` tool. v1 is per-session only via `get_plan`.
- **Plan templates** — no "new feature template", "bug fix template", etc. Future task: agent picks a template at session start, fills in checklist items.
- **Visual plan UI in the sidebar** — Task 8's optional components render inside the chatview. A future task could add a dedicated plan panel in the kanban card or sidebar showing the live plan + checklist.
- **Plan-aware tool execution** — could the agent's tools refuse to run if the plan is empty / stale? e.g. refuse `bash` if no plan exists. Out of scope; v1 is "agent chooses to use the tool or not".
- **Compaction-trigger UI** — let the user manually trigger compaction. Currently compaction is automatic when token count exceeds threshold; a manual button could help. Out of scope.

---

**End of plan.** 9 tasks, each with test → implement → verify → commit cycle. Total estimated effort: 8–12 hours of focused implementation + 2 hours of code review. Open the PR to `in_review_task` column when done.