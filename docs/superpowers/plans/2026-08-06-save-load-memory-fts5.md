# `save_memory` + `load_memory` Tools (SQLite FTS5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two new LLM-callable tools — `save_memory` (UPSERT) and `load_memory` (FTS5 phrase search) — backed by a new `agent_memories` SQLite table + `agent_memories_fts` FTS5 virtual table. The agent can persist short notes (preferences, decisions, facts) and recall them later via free-text search.

**Architecture:** Migration 070 adds the table + FTS5 virtual table + sync triggers (mirrors the `messages_fts` pattern from Migration 058). A new `agent_memories.zig` module in `src/ai_workflow/tui/` owns the CRUD + FTS5 query helpers. Two new tool files (`save_memory.zig`, `load_memory.zig`) follow the existing `kanban_list.zig` / legacy history-tool pattern. Two exec wrappers (`tools_exec_save_memory.zig`, `tools_exec_load_memory.zig`) wire the tools into the agent registry. No frontend changes.

**Tech Stack:** Zig 0.16, SQLite 3 with FTS5, existing `escapeFtsQuery` helper from `llm_history.zig`, existing `AgentTool` schema from `src/modules/agent/tools/schemas.zig`.

## Global Constraints

- **Cross-platform**: every change must compile on Linux + macOS + Windows. Verify with `zig build-obj -fno-emit-bin -target X` for Windows + macOS after the migration lands.
- **Test by migration, not by hand-rolling schema.** Per project memory `llm-history-test-use-migrations-module.md`, the new tests MUST use `MigrationManager` to walk all 71 migrations. No hand-rolled `CREATE TABLE` for the new feature.
- **Idempotent migrations.** Use `addColumnIfMissing` / `CREATE TABLE IF NOT EXISTS` so re-running Migration 070 is a no-op.
- **FTS5 query sanitization.** Reuse `escapeFtsQuery` from `llm_history.zig`. Do NOT reinvent.
- **Snippets only by default.** `load_memory` returns `<snippet>` (FTS5 10-token window with `[match]` markers). Raw `<content>` is opt-in via `with_content=true` and capped at 2 KiB per row.
- **No frontend changes.**
- **No delete_memory tool.** Per user decision.
- **Auto-generated id format: `mem_<16-hex>`** (64-bit random, opaque, collision-free). Caller-supplied `id` slug is an alternative for UPSERT.
- **Per-row size cap: 1 MiB** for `save_memory`. Reject (400) anything larger.
- **Memory never auto-deleted.** No TTL or cleanup. The agent decides when to UPSERT.

## File Structure

| File | Change |
|---|---|
| `src/migrations/migration.zig` | + `Migration070AddAgentMemories` (table + FTS5 + triggers) |
| `src/migrations/migration_070_test.zig` | NEW (5 tests) |
| `src/migrations/test_runner.zig` | + register the new test |
| `src/ai_workflow/tui/agent_memories.zig` | NEW (CRUD + FTS5 helpers) |
| `src/ai_workflow/tui/agent_memories_test.zig` | NEW (8 helper-level tests) |
| `src/ai_workflow/tui/agentic_loop/handle_tool.zig` | (no change — exec wrappers pattern) |
| `src/modules/agent/tools/save_memory.zig` | NEW (tool def + execute) |
| `src/modules/agent/tools/save_memory_test.zig` | NEW (8 tests) |
| `src/modules/agent/tools/load_memory.zig` | NEW (tool def + execute) |
| `src/modules/agent/tools/load_memory_test.zig` | NEW (10 tests) |
| `src/modules/agent/tools/tools.zig` | + re-exports |
| `src/ai_workflow/tui/agentic_loop/tools_exec_save_memory.zig` | NEW |
| `src/ai_workflow/tui/agentic_loop/tools_exec_load_memory.zig` | NEW |
| `src/ai_workflow/tui/agentic_loop/tools.zig` | + `execSaveMemory` / `execLoadMemory` |
| `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` | + entries in `all_agent_tools` + `.exec` table |
| `src/root.zig` | + `nalarcore.save_memory` / `nalarcore.load_memory` re-exports |
| `docs/SPEC.md` | + changelog row |
| `AGENTS.md` | + changelog block |

## Tasks

### Task 1: Migration 070 — `agent_memories` table + FTS5 virtual table + triggers

**Files:** `src/migrations/migration.zig`, `src/migrations/migration_070_test.zig`, `src/migrations/test_runner.zig`

- [ ] **Step 1: Write the failing test** in `src/migrations/migration_070_test.zig`. Cover:
  - A: Migration adds `agent_memories` table with `id`, `content`, `tags`, `created_at`, `updated_at` columns
  - B: Migration is idempotent on re-run
  - C: Migration creates `agent_memories_fts` FTS5 virtual table with `content` + `tags` columns
  - D: Sync triggers keep FTS5 in lockstep with source table (insert / delete / update)
  - E: Migration is registered in `allMigrations` (per `migration-registration-trap` memory)
- [ ] **Step 2: Run the test to confirm it fails** with "table not found" or "Migration 070 not registered".
- [ ] **Step 3: Implement `Migration070AddAgentMemories`** in `src/migrations/migration.zig` (append at the end, version `70`):
  - `CREATE TABLE IF NOT EXISTS agent_memories (id TEXT PRIMARY KEY, content TEXT NOT NULL, tags TEXT NOT NULL DEFAULT '', created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)`
  - `CREATE INDEX IF NOT EXISTS idx_agent_memories_updated ON agent_memories(updated_at DESC)`
  - `CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts USING fts5(content, tags, tokenize='porter unicode61 remove_diacritics 2', content='agent_memories', content_rowid='rowid')`
  - 3 triggers: `agent_memories_ai` AFTER INSERT, `agent_memories_ad` AFTER DELETE (uses `'delete'` command), `agent_memories_au` AFTER UPDATE (delete + insert)
  - Use `IF NOT EXISTS` everywhere for idempotency
  - Follow the pattern from `Migration058AddLlmHistoryFts` — see `migration.zig:1480-1573` for the reference
- [ ] **Step 4: Add the migration to `allMigrations`** slice in `src/migrations/migration.zig` (find the `allMigrations` const near the bottom of the file).
- [ ] **Step 5: Register the test in `src/migrations/test_runner.zig`** (search for `_ = @import("migration_069_test.zig")` and add the line for `migration_070_test.zig` below it).
- [ ] **Step 6: Run the migration test** with `zig build test --summary all` — confirm 5/5 pass.
- [ ] **Step 7: Cross-compile smoke** (mandatory — SQL helpers can hide behind lazy analysis):
  ```bash
  zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
    --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
  zig build-obj -fno-emit-bin -target aarch64-macos -lc \
    --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
  ```
  Both must exit 0.
- [ ] **Step 8: Commit** with message `migration(070): agent_memories table + FTS5 virtual table + sync triggers`.

### Task 2: Backend helpers — `agent_memories.zig`

**Files:** `src/ai_workflow/tui/agent_memories.zig`, `src/ai_workflow/tui/agent_memories_test.zig`

- [ ] **Step 1: Write the failing tests** in `src/ai_workflow/tui/agent_memories_test.zig`. Cover:
  - A: `saveMemory` inserts a new row with auto-generated `mem_<16-hex>` id when caller passes empty id
  - B: `saveMemory` UPSERTs when caller passes an existing id (updated_at bumps, content replaces)
  - C: `saveMemory` `||`-joins tags for storage (input `["a", "b"]` → stored `"a||b"`)
  - D: `saveMemory` rejects empty content with `error.InvalidContent`
  - E: `saveMemory` rejects content > 1 MiB with `error.ContentTooLarge`
  - F: `loadMemoriesByFts` returns ranked hits with snippets (use `escapeFtsQuery` internally)
  - G: `loadMemoriesByFts` AND-filters by tags (each tag must be present in `tags LIKE '%tag%'`)
  - H: `loadMemoriesByFts` paginates via `limit` + `offset` and reports `total_count`
- [ ] **Step 2: Run the tests to confirm they fail** with "module not found" or "function not exported".
- [ ] **Step 3: Implement `src/ai_workflow/tui/agent_memories.zig`** with the following public API:
  - `pub const MemoryRow = struct { id: []const u8, content: []const u8, tags: []const u8, created_at: []const u8, updated_at: []const u8 };` — owned strings, caller frees with `freeMemoryRow` (or `freeMemoryRows`).
  - `pub const MemoryHit = struct { id: []const u8, tags: []const u8, snippet: []const u8, created_at: []const u8, updated_at: []const u8, total_count: u32 };` — what `loadMemoriesByFts` returns.
  - `pub fn saveMemory(allocator, io, db, args: SaveMemoryArgs) !MemoryRow` — UPSERT logic. Generates `mem_<16-hex>` if `args.id.len == 0`. Validates `content.len > 0 || return error.InvalidContent` and `content.len <= 1 << 20 || return error.ContentTooLarge`.
  - `pub fn loadMemoriesByFts(allocator, io, db, opts: LoadOptions) ![]MemoryHit` — FTS5 query with `snippet(agent_memories_fts, 0, '[', ']', '…', 10)`. Joins back to source table for `tags` + `created_at` + `updated_at`. AND-filters by tags via `LIKE '%tag%'`. Computes `total_count` via `COUNT(*) OVER ()` window function (pre-LIMIT).
  - `pub fn freeMemoryRow(allocator, row: MemoryRow) void` — frees all owned strings.
  - `pub fn freeMemoryRows(allocator, rows: []MemoryRow) void` — slice version.
  - `pub fn freeMemoryHits(allocator, hits: []MemoryHit) void` — hits don't own content, so each `hit.snippet` is freed.
  - Use `std.c.getrandom` for the 16-hex generation (8 random bytes → 16 hex chars). Wrap in retry-on-short-read loop per `zig-cross-platform.md` patterns.
- [ ] **Step 4: Run the tests** with `zig build test --summary all` — confirm 8/8 pass.
- [ ] **Step 5: Cross-compile smoke** (same two commands as Task 1, Step 7).
- [ ] **Step 6: Commit** with message `feat(agent_memories): saveMemory + loadMemoriesByFts helpers + 8 unit tests`.

### Task 3: `save_memory` tool

**Files:** `src/modules/agent/tools/save_memory.zig`, `src/modules/agent/tools/save_memory_test.zig`

- [ ] **Step 1: Write the failing tests** in `src/modules/agent/tools/save_memory_test.zig`. Cover:
  - A: tool definition has `name = "save_memory"`
  - B: tool definition includes `content` + `tags` + `id` parameters
  - C: tool definition is present in `UNIFIED_TOOL_REGISTRY` (per `tool_registry.zig` historical pattern — verify via `tools_equipped.zig`)
  - D: `executeSaveMemory` returns `<save_memory><id>...</id>...</save_memory>` XML on success
  - E: `executeSaveMemory` returns `<save_memory><error>...</error></save_memory>` on empty content
  - F: `executeSaveMemory` returns `<save_memory><error>...</error></save_memory>` on content > 1 MiB
  - G: `executeSaveMemory` UPSERTs on second call with same id (id matches, updated_at >= previously-recorded)
  - H: `executeSaveMemory` auto-generates `mem_<16-hex>` id when no id provided
- [ ] **Step 2: Run the tests to confirm they fail** with "module not found".
- [ ] **Step 3: Implement `src/modules/agent/tools/save_memory.zig`** following the `kanban_list.zig` pattern:
  - `pub const SaveMemoryInput = struct { content: []const u8 = "", tags: []const []const u8 = &.{}, id: []const u8 = "" };`
  - `pub const save_memory_tool = AgentTool{ ... }` — description explicitly mentions UPSERT, FTS5, global scope, 1 MiB cap, `mem_<16-hex>` auto-id.
  - `pub fn executeSaveMemory(allocator, io, db, input: SaveMemoryInput) ![]const u8` — wraps `agent_memories.saveMemory`, returns XML.
  - `pub fn successXml(allocator, row: MemoryRow) ![]u8` — `<save_memory><id>...</id><created_at>...</created_at><updated_at>...</updated_at></save_memory>`.
  - `pub fn errorXml(allocator, msg: []const u8) ![]u8` — `<save_memory><error>...</error></save_memory>`.
- [ ] **Step 4: Run the tests** — confirm 8/8 pass.
- [ ] **Step 5: Add `pub const save_memory = @import("save_memory.zig");` to `src/modules/agent/tools/tools.zig`** (alongside the existing `pub const list_memory = ...` line).
- [ ] **Step 6: Commit** with message `feat(agent_tools): save_memory tool (UPSERT, FTS5-indexed, 1 MiB cap) + 8 tests`.

### Task 4: `load_memory` tool

**Files:** `src/modules/agent/tools/load_memory.zig`, `src/modules/agent/tools/load_memory_test.zig`

- [ ] **Step 1: Write the failing tests** in `src/modules/agent/tools/load_memory_test.zig`. Cover:
  - A: tool definition has `name = "load_memory"`
  - B: tool definition includes `query` + `tags` + `limit` + `offset` + `with_content` parameters
  - C: tool definition is present in `UNIFIED_TOOL_REGISTRY`
  - D: `executeLoadMemory` returns `<load_memory><count>N</count><total_count>N</total_count><results>...</results></load_memory>` on success
  - E: `executeLoadMemory` returns `<load_memory><error>...</error></load_memory>` on empty query
  - F: `executeLoadMemory` caps limit at 50 (set `limit=999` → only 50 returned)
  - G: `executeLoadMemory` snippets contain `[match]` markers (verify format)
  - H: `executeLoadMemory` filters by tags (insert one memory with `tags="user"`, one with `tags="preferences"`; search with `tags=["user"]` → only the first returns)
  - I: `executeLoadMemory` without `with_content` returns snippets only (no raw `<content>` field)
  - J: `executeLoadMemory` with `with_content=true` returns truncated content capped at 2 KiB per row
  - K: `executeLoadMemory` paginates correctly (insert 15 memories, `limit=10` returns 10, `offset=10` returns 5)
  - L: `executeLoadMemory` sanitizes FTS5 queries (query `"handle_tool.zig"` doesn't crash)
- [ ] **Step 2: Run the tests to confirm they fail** with "module not found".
- [ ] **Step 3: Implement `src/modules/agent/tools/load_memory.zig`** following the legacy history-tool pattern but with the context-bloat guard:
  - `pub const LoadMemoryInput = struct { query: []const u8 = "", tags: []const []const u8 = &.{}, limit: u32 = 10, offset: u32 = 0, with_content: bool = false };`
  - `pub const load_memory_tool = AgentTool{ ... }` — description explicitly mentions: snippets-only by default, `with_content=true` for full content (capped at 2 KiB/row), `limit` default 10 cap 50, FTS5 sanitization, tag filtering.
  - `pub const MAX_FULL_CONTENT_BYTES: u32 = 2 * 1024;` — 2 KiB cap when `with_content=true`.
  - `pub fn executeLoadMemory(allocator, io, db, input: LoadMemoryInput) ![]const u8` — wraps `agent_memories.loadMemoriesByFts`, builds XML.
  - `pub fn successXml(allocator, hits: []MemoryHit, raw_rows: ?[]MemoryRow, input: LoadMemoryInput) ![]u8` — emits `<load_memory>` with optional `<content>` truncated blocks.
  - `pub fn errorXml(allocator, msg: []const u8) ![]u8` — `<load_memory><error>...</error></load_memory>`.
  - The XML builder: if `with_content=true`, also fetch the full row by id (using `getMemoryById`) and truncate content to `MAX_FULL_CONTENT_BYTES`, emitting `<content truncated="0|1">...</content>`.
- [ ] **Step 4: Add `pub const getMemoryById` helper to `src/ai_workflow/tui/agent_memories.zig`** (a small additional helper — not in Task 2's scope but needed for `with_content=true`). Returns `?MemoryRow` (null if not found). Add 1 unit test.
- [ ] **Step 5: Run the tests** — confirm 12/12 pass.
- [ ] **Step 6: Add `pub const load_memory = @import("load_memory.zig");` to `src/modules/agent/tools/tools.zig`**.
- [ ] **Step 7: Commit** with message `feat(agent_tools): load_memory tool (FTS5 phrase search, snippets by default, 2 KiB content cap) + 12 tests`.

### Task 5: Exec wrappers

**Files:** `src/ai_workflow/tui/agentic_loop/tools_exec_save_memory.zig`, `src/ai_workflow/tui/agentic_loop/tools_exec_load_memory.zig`

- [ ] **Step 1: Implement `tools_exec_save_memory.zig`** following the `tools_exec_kanban_list.zig` pattern (parse input → call execute → wrap via `wrapToolOutput` → detect `<error>` to surface as tool failure).
- [ ] **Step 2: Implement `tools_exec_load_memory.zig`** with the same pattern.
- [ ] **Step 3: Add `execSaveMemory` and `execLoadMemory` declarations to `src/ai_workflow/tui/agentic_loop/tools.zig`** (mirrors `execKanbanList` declaration).
- [ ] **Step 4: Run `zig build test --summary all`** — confirm no failures (compile test from the wrappers).
- [ ] **Step 5: Commit** with message `feat(agentic_loop): tools_exec_save_memory + tools_exec_load_memory wrappers`.

### Task 6: Tool registry wiring

**Files:** `src/ai_workflow/tui/agentic_loop/tools_equipped.zig`, `src/root.zig`

- [ ] **Step 1: Add `save_memory_mod` and `load_memory_mod` constant imports** to `tools_equipped.zig`:
  ```zig
  const save_memory_mod = nalarcore.save_memory;
  const load_memory_mod = nalarcore.load_memory;
  ```
- [ ] **Step 2: Add to `all_agent_tools` slice** (after `list_memory_mod.list_memory_tool`):
  ```zig
  save_memory_mod.save_memory_tool,
  load_memory_mod.load_memory_tool,
  ```
- [ ] **Step 3: Add to `tool_dispatch` table** (mirror the `list_memory` entry):
  ```zig
  .{ .name = "save_memory", .exec = tools.execSaveMemory, .tool_def = save_memory_mod.save_memory_tool },
  .{ .name = "load_memory", .exec = tools.execLoadMemory, .tool_def = load_memory_mod.load_memory_tool },
  ```
- [ ] **Step 4: Re-export `save_memory` and `load_memory` from `src/root.zig`**:
  ```zig
  pub const save_memory = nalarcore_mod.save_memory;
  pub const load_memory = nalarcore_mod.load_memory;
  ```
  (verify the existing `pub const list_memory = ...` line for the pattern).
- [ ] **Step 5: Run `zig build test --summary all`** — confirm no regressions (the tools should now be reachable via the registry; existing tests must still pass).
- [ ] **Step 6: Commit** with message `feat(agentic_loop): register save_memory + load_memory in UNIFIED_TOOL_REGISTRY`.

### Task 7: Verification gate

- [ ] **Step 1: Backend tests** — `timeout 180 zig build test --summary all`. Expect 23+ new tests pass (5 migration + 8 helpers + 1 getMemoryById + 8 save_memory + 12 load_memory). 0 new failures. Document any pre-existing failures (the 2 design_model_set_element_parent_test leaks).
- [ ] **Step 2: Linux build** — `timeout 180 zig build install:linux:system`. Expect success (cp-to-`/usr/local/bin` may fail on perms — that's fine).
- [ ] **Step 3: Fresh rebuild** — `rm -rf zig-out/bin && timeout 360 zig build`. All 3 binaries (nalar, nalarcore-linux-x86_64, nalar-desktop) produced.
- [ ] **Step 4: Cross-compile smoke** (mandatory):
  ```bash
  zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
    --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
  zig build-obj -fno-emit-bin -target aarch64-macos -lc \
    --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
  ```
  Both must exit 0.
- [ ] **Step 5: Live smoke on port 8080** — start `zig-out/bin/nalar` on port 8080 (NOT 8081 — that's the dev instance). Drive the agent via the kanban chat flow:
  - Send a message asking the agent to remember "the test passed today"
  - Open a new session, ask the agent "what was the test result?"
  - Confirm the agent uses `load_memory` to retrieve the saved note
  - Verify the response (no error envelope, no context bloat)
- [ ] **Step 6: Compliance check** — run `grep -rn 'expect(source)' src/ai_workflow/tui/agent_memories_test.zig src/modules/agent/tools/save_memory_test.zig src/modules/agent/tools/load_memory_test.zig src/migrations/migration_070_test.zig` — expect 0 hits (no static-contract tests, per the 2026-07-29 rule).
- [ ] **Step 7: Update `docs/SPEC.md`** with a new "✅ Implemented" row under §3.2 (Backend — LLM Workflow + Tools). Format: `2026-08-06-save-load-memory-fts5.md | ✅ | New agent tools: save_memory (UPSERT) + load_memory (FTS5 phrase search) over a new agent_memories table + agent_memories_fts virtual table (Migration 070). Snippets by default; with_content=true caps raw content at 2 KiB/row to prevent context bloat (max 50 rows = 100 KiB worst case). No delete_memory by design.`
- [ ] **Step 8: Update `AGENTS.md`** with a "### 2026-08-06: save_memory + load_memory tools (SQLite FTS5)" changelog block. Mirror the format from older entries — one paragraph summary + one bullet list of what landed + a "Why" section + a "Verification" section + a "Pitfalls" section.
- [ ] **Step 9: Commit** with message `docs(070): SAVE-LOAD-MEMORY changelog entries + verification report`.

## Pitfalls

These are the non-obvious traps surfaced during the design — record them in the code comments so the next agent doesn't relearn:

1. **External-content FTS5 + `snippet()`** — `snippet()` works on external-content tables IF the query JOINs back to the source table to read the original text. See `messages_fts` pattern in `searchMessagesFts` (`src/ai_workflow/tui/llm_history.zig:1797`).
2. **DELETE trigger for external-content FTS5** — uses the special `'delete'` command (`INSERT INTO agent_memories_fts(agent_memories_fts, rowid, ...) VALUES('delete', ...)`), NOT a plain `DELETE FROM`. See migration 058 for the reference.
3. **`escapeFtsQuery`** — don't reinvent. Reuse `llm_history.escapeFtsQuery` (sanitizes `.`, `-`, `:`, `*`, `^`, `(`, `)`, `"`, `+` → wraps in FTS5 phrase syntax).
4. **Per-row size cap** — `1 MiB` is a sane default. Anything larger is a bug or abuse. Return `error.ContentTooLarge` (not silently truncate).
5. **Context bloat** — `load_memory` snippets are ~10 tokens = ~80-120 chars. 50 rows × 120 chars = 6 KiB. With `with_content=true`, 50 × 2 KiB = 100 KiB. NEVER emit raw content without truncation.
6. **Tag filtering** — `LIKE '%tag%'` is the existing convention (matches `tags` column in `workspace_item_tasks`). The agent picks tag names so substring collisions are unlikely.
7. **`mem_<16-hex>` generation** — use `std.c.getrandom` (per `zig-cross-platform.md`). 8 random bytes → 16 hex chars. Collision odds for 10K rows: ~1 in 10^19 (astronomically safe).
8. **`updated_at` bumps on UPSERT** — the UPSERT must REPLACE `content` and `tags` AND set `updated_at = CURRENT_TIMESTAMP`. The tests in Task 3.7 verify this.
9. **No frontend changes** — both tools are LLM-side only. The user sees the save/load via the conversation transcript.
10. **registration trap** — per project memory `migration-registration-trap`, defining `Migration070AddAgentMemories` is NOT enough. Must add it to `allMigrations` and verify with a test.

## Verification

- [ ] `zig build test --summary all` — all 23+ new tests pass; 0 new failures.
- [ ] `zig build install:linux:system` — builds.
- [ ] `rm -rf zig-out/bin && zig build` — all 3 binaries produced.
- [ ] `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` — clean.
- [ ] `zig build-obj -fno-emit-bin -target aarch64-macos` — clean.
- [ ] Live smoke on port 8080 — save → load → FTS5 phrase match works.
- [ ] `grep -rn 'expect(source)'` on the new test files — 0 hits (no static-contract tests).
- [ ] `docs/SPEC.md` and `AGENTS.md` updated.
- [ ] Branch: `worktree/save-load-memory-fts5` ready for squash-merge.
