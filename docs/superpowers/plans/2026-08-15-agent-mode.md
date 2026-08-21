# Agent Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **⛔ DO ALL WORK IN A GIT WORKTREE — never on `main`.** This plan lives in `worktree/agent-mode` (path `.worktrees/agent-mode`). Project convention: every feature ships via a PR from `worktree/<topic>`. The kanban card moves to `merged` only after the user merges the PR.

**Goal:** Add a fourth workspace-item type — `agent` — sitting alongside `folder`/`kanban`/`design`. Each Agent is a persistent chatbot with its own `path` (cwd), a list of absolute-path markdown knowledge files on disk, and a tool allowlist (empty by default = zero tools, secure-by-default). Three new tables, twelve new HTTP endpoints, two new backend helpers, and five new frontend components — all integrated into the existing prompt-assembly and tool-filter pipeline.

**Architecture:** New tables `agents` (1-1 with `workspace_items`), `agent_knowledge` (N-1 with agents), `agent_tools` (N-1 with agents). New backend helpers: `prompts_make_agent_knowledge.zig` (reads files at chat-start, injects as `## Agent Knowledge` system-prompt section) and `agent_tools_allowed.zig` (returns enabled tool names for an agent). Runtime filter reuses the **existing** `filterAndMergeTools` in `workflow.zig:1478` — already supports `""` (no tools), `"all"` (all), comma-separated (specific). For Agent sessions we resolve the allowlist from DB and pass it as the `allowed_tools` workflow arg. New frontend: `AddAgentDialog`, `AgentKnowledgeDialog`, `AgentView` (Knowledge + Tools panels + chat list), `AgentChatDialog`, and `agentTools` Pinia store holding the canonical tool registry.

**Tech Stack:** Zig 0.16 (backend), Vue 3.5 + TypeScript + Pinia 2 + Vitest (frontend). No new npm deps. Backend reuses `nalarcore.http_response` error envelope + `nalarcore.sqlite.SqliteBackend`.

**Spec:** `docs/superpowers/specs/2026-08-15-agent-mode-design.md`

---

## Design Decisions (review before execution)

| ID | Decision | Why |
|----|----------|-----|
| D1 | **Secure-by-default tool semantics**: empty `agent_tools` allowlist = zero tools. | Matches user's "No tools allowed, if not set" + the framing "limit the tool that's used". |
| D2 | **Reuse existing `filterAndMergeTools` (workflow.zig:1478)** + `WorkflowArgs.allowed_tools`. Resolve `agent_tools` from DB, pass comma-separated (or `""` if empty) to the workflow arg. | Infrastructure already supports `""`=no tools, `"all"`=all, comma-separated=specific. No new layer. |
| D3 | **`agents.id` == `workspace_item_id`.** No separate id space. URLs: `/api/agents/<item_id>/tools`. | Mirrors `kanban_columns.id`. Avoids id-space ambiguity. |
| D4 | **Tool registry is a static constant** derived from `UNIFIED_TOOL_REGISTRY()` at `tools_equipped.zig:118`. Exposed via `GET /api/agent-tools/registry`. | Single source of truth — adding a tool auto-updates the registry endpoint. |
| D5 | **No content cap on knowledge files** (per user "no need caps"). 100 MiB per-file OOM safety via `readToEndAlloc` max_size. | User's explicit call. 100 MiB prevents pathological `/dev/zero`. |
| D6 | **Knowledge injection at system-prompt assembly** (new section appended after `prompts_make_workspace_context.zig`). Re-reads files every session. | Edits to markdown files take effect on next chat start. No cache. |
| D7 | **One PR, ~21 commits.** Each task = one commit; Task 21 is the PR-ready state. | Reviewable units. |
| D8 | **`agent_tools` has its own `id` PK**; composite `(agent_id, tool_name)` is UNIQUE but not the PK. URLs: `/api/agents/:agentId/tools/:toolId`. | Consistency with `agent_knowledge`. |
| D9 | **Frontend Tools panel = checkbox list** from `agentTools` Pinia store. Toggle = POST/DELETE. No drag-reorder (tools are unordered). | Allowlist has no implicit ordering. |
| D10 | **`enabled` column always = 1 in v1.** Exists for future "disable without removing" UX. | Future-proofs without overbuilding v1. |
| D11 | **AgentView = 3 sections: Knowledge (top), Tools (middle), Chat list (bottom-right).** | Consistent with Kanban/Design item-view layouts. |
| D12 | **AgentChatDialog mirrors KanbanChatDialog** (Teleport + v-model:show + `activeTaskWorkspaceItemId === activeWorkspaceItem.id` gating). | Pattern reuse — proven UX. |
| D13 | **One test runner change**: register `_ = @import("migration_076_test.zig");` in `src/migrations/test_runner.zig`. | Mirrors Migration 072–075 pattern. |

---

## Global Constraints

- **TDD discipline**: failing test → minimal code → pass → commit. No code lands without a test.
- **Cross-platform**: Linux + macOS + Windows compile + test green.
- **Migration 076 is idempotent** (`IF NOT EXISTS` everywhere). Re-run is a no-op.
- **Tool filter applies ONLY to `item_type='agent'` sessions.** Kanban/design/folder/standalone unchanged.
- **`bun run build` IS the type-check**. Every frontend commit must pass it.
- **No `dist/` or `.js` cruft**: delete `vue-tsc --build` emitted `.js` before `git status`.
- **No port 8081**: smoke tests use port 8080.
- **No new npm dependencies.**
- **No Vue 3.5 / TS anonymous-struct-literal gotchas**: initialize ALL fields or use explicit field names.
- **Surgical patches only** — no refactoring of unrelated code.

---

## File Structure

```
src/migrations/{migration.zig, migration_076_test.zig, test_runner.zig}
src/models/{agent.zig, agent_knowledge.zig, agent_tool.zig}
src/ai_workflow/tui/http_handlers/
  workspace_items_create_agent.zig + _test.zig
  agents_get.zig + _test.zig
  agents_update.zig + _test.zig
  agent_knowledge_{create,update,delete,reorder}.zig + _test.zig
  agent_tools_{registry,list,create,delete}.zig + _test.zig
  mod.zig                                            # EDIT — 12 new re-exports
src/ai_workflow/tui/agentic_loop/
  prompts_make_agent_knowledge.zig + _test.zig
  agent_tools_allowed.zig + _test.zig
  workflow.zig                                       # EDIT — pass allowed_tools for agents
src/main.zig                                         # EDIT — register 12 new routes
src/apps/desktop/src/
  api/index.ts                                       # EDIT — 13 new typed wrappers
  stores/{workspaces.ts, agentTools.ts}              # EDIT + NEW
  components/workspace/WorkspaceList.vue             # EDIT — "Add Agent" dropdown
  components/shell/Sidebar.vue                       # EDIT — handleAddItem + handleCreateAgent
  components/dialogs/{AddAgentDialog,AgentKnowledgeDialog,AgentChatDialog}.vue
  components/views/AgentView.vue                     # NEW
  components/AppLayout.vue                           # EDIT — AgentView + AgentChatDialog mounts
  __tests__/{AddAgentDialog,AgentKnowledgeDialog,AgentView,agentToolsStore}.spec.ts
```

---

## Risks & breaking changes analysis

| # | Risk | Mitigation |
|---|------|-----------|
| R1 | `agents.id` == `workspace_item_id` invariant — if item id ever changes, agent drifts. | DB-enforced FK + UNIQUE constraints. Schema makes orphaning impossible. |
| R2 | Tool registry must stay in sync with `UNIFIED_TOOL_REGISTRY()`. | The handler is a thin adapter over the same function. Tests assert count match. |
| R3 | New filter path invoked every session start — must be a single non-DB-hit branch for non-agents. | `if (item_type == 'agent')` at top of filter; early-return for non-agents. |
| R4 | `readToEndAlloc(100 MiB)` allocates briefly per file. | Acceptable — agents start with empty knowledge; user opts in. |
| R5 | UNIQUE constraint on `agent_tools(agent_id, tool_name)` could collide on partial re-run. | UNIQUE is part of `CREATE TABLE`, not a separate `ALTER`. `IF NOT EXISTS` handles re-run cleanly. |
| R6 | New Agent user starts a chat expecting tools, gets text-only. | Empty-state copy in Tools panel + tip when chat starts with zero tools (per spec Risks section). |
| R7 | Path validation best-effort — no extension / encoding / size check beyond 100 MiB. | Documented. Binary file's bytes get injected; LLM ignores. Future enhancement. |
| R8 | `workspaceItemsCreateAgent` spans 2 INSERTs — leak if 2nd fails. | Wrap in `BEGIN`/`COMMIT`. Mirrors Migration 072 pattern. |
| R9 | `agentTools` Pinia store fetches on startup — silent 404 if registry endpoint missing. | Store catches error, exposes `error` ref. AgentView renders fallback "registry unavailable". |
| R10 | `## Agent Knowledge` section can dwarf other prompt sections (no cap). | User's explicit choice (D5). Documented. |

---

## Tasks

> **Format reminder:** every task follows **test → implement → run tests → commit**. Task 0 is verification-only (no commit). Tasks 1–20 each produce one commit.

---

### Task 0 — Worktree setup + baseline verification

**Files:** none changed.

**Why first:** every subsequent commit must land on `worktree/agent-mode`, not `main`. Baseline-green proves the test suite starts clean.

- [ ] **Step 0.1:** Verify worktree exists.
  ```bash
  cd /home/ginwa/ginwaaitoolbox
  git worktree list | grep agent-mode
  git -C .worktrees/agent-mode status --short   # clean
  git -C .worktrees/agent-mode rev-parse --abbrev-ref HEAD  # → worktree/agent-mode
  ```
- [ ] **Step 0.2:** Baseline `zig build test --summary all` is green.
  ```bash
  cd /home/ginwa/ginwaaitoolbox/.worktrees/agent-mode
  timeout 600 zig build test --summary all 2>&1 | tail -5
  ```
  If baseline fails, STOP — fix the regression before adding new tests.
- [ ] **Step 0.3:** Baseline `bun run build` is clean.
  ```bash
  timeout 120 bun run build 2>&1 | tail -5
  ```
- [ ] **Step 0.4:** Kanban card `task_1786962724740_0` is in `in_review_planning`. Move if needed.

**Commit:** none (verification only).

---

### Task 1 — Migration 076: 3 tables + indexes

**Files:**
- `src/migrations/migration.zig` — add `Migration076AddAgentsAndAgentKnowledgeAndAgentTools` struct + register in `allMigrations`.
- `src/migrations/migration_076_test.zig` (new) — 9 tests.
- `src/migrations/test_runner.zig` — register new test.

- [ ] **Step 1.1:** Write `migration_076_test.zig`. Use `migration_070_test.zig` as the template. 9 tests:
  - `agents table exists with expected columns`
  - `agent_knowledge table exists with expected columns`
  - `agent_tools table exists with expected columns`
  - `agents.workspace_item_id is UNIQUE` (INSERT dup → expect UNIQUE violation)
  - `agent_tools(agent_id, tool_name) is UNIQUE` (same pattern)
  - `CASCADE deletes agents when workspace_items row deleted` (enable FKs via `PRAGMA foreign_keys=ON`)
  - `CASCADE deletes agent_knowledge + agent_tools when agents row deleted`
  - `agent_knowledge.position index exists` (`SELECT name FROM sqlite_master WHERE type='index'`)
  - `re-running migration is idempotent` (apply twice, second apply no-op)

  Each test opens in-memory DB, applies Migration 076, runs assertions on `pragma_table_info` + UNIQUE/CASCADE behavior.
- [ ] **Step 1.2:** Register in `test_runner.zig`: `_ = @import("migration_076_test.zig");`
- [ ] **Step 1.3:** Run tests — confirm FAIL (compile error on missing struct).
  ```bash
  timeout 120 zig build test --summary all 2>&1 | rg "Migration076|migration_076"
  ```
- [ ] **Step 1.4:** Add `Migration076AddAgentsAndAgentKnowledgeAndAgentTools` struct to `migration.zig` (place AFTER Migration 075). Use the schema from the spec:
  ```zig
  pub const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = struct {
      pub const version: u32 = 76;
      pub const name = "add_agents_and_agent_knowledge_and_agent_tools";
      pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
          // 1. agents (1-1 with workspace_items, UNIQUE workspace_item_id, FK CASCADE)
          try db.exec(allocator, "CREATE TABLE IF NOT EXISTS agents (...)", .{});
          try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_agents_workspace_item_id ON agents(workspace_item_id)", .{});
          // 2. agent_knowledge (N-1, position-ordered)
          try db.exec(allocator, "CREATE TABLE IF NOT EXISTS agent_knowledge (...)", .{});
          try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_agent_knowledge_agent_id ON agent_knowledge(agent_id)", .{});
          try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_agent_knowledge_agent_id_position ON agent_knowledge(agent_id, position DESC)", .{});
          // 3. agent_tools (N-1, UNIQUE (agent_id, tool_name))
          try db.exec(allocator, "CREATE TABLE IF NOT EXISTS agent_tools (...)", .{});
          try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_agent_tools_agent_id ON agent_tools(agent_id)", .{});
          try db.exec(allocator, "CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_tools_agent_tool ON agent_tools(agent_id, tool_name)", .{});
      }
  };
  ```
  Register in `allMigrations`: `.{ .version = ...Migration076..., .name = ..., .up = ...Migration076.up }`.
- [ ] **Step 1.5:** Run tests — confirm PASS.
  ```bash
  timeout 180 zig build test --summary all 2>&1 | tail -3
  ```
- [ ] **Step 1.6:** Commit: `agent: add Migration076 — agents + agent_knowledge + agent_tools`

---

### Task 2 — 3 model files (Agent, AgentKnowledge, AgentTool)

**Files:**
- `src/models/agent.zig` (new) — `id`, `workspace_item_id`, `description`, `created_at`, `updated_at`. `init/deinit/clone`.
- `src/models/agent_knowledge.zig` (new) — adds `file_path`, `label`, `position`.
- `src/models/agent_tool.zig` (new) — `id`, `agent_id`, `tool_name`, `enabled: u8`, `created_at`.

- [ ] **Step 2.1:** Write the 3 model files. Each mirrors `src/models/workspace_item.zig` exactly with the field additions per spec. Pure data structs — no behavior, no tests needed (compile-test is sufficient).
- [ ] **Step 2.2:** Verify `zig build test --summary all` still green (no behavioral change).
- [ ] **Step 2.3:** Commit: `agent: add model structs for Agent + AgentKnowledge + AgentTool`

---

### Task 3 — `agent_tools_allowed.zig` helper

**Files:**
- `src/ai_workflow/tui/agentic_loop/agent_tools_allowed.zig` (new)
- `src/ai_workflow/tui/agentic_loop/agent_tools_allowed_test.zig` (new) — 5 tests.

- [ ] **Step 3.1:** Write `agent_tools_allowed_test.zig` — 5 tests:
  - `agentToolsAllowed: returns empty slice when workspace_item_id doesn't exist`
  - `agentToolsAllowed: returns empty slice when workspace_items row's item_type != 'agent'`
  - `agentToolsAllowed: returns empty slice when agent has no rows in agent_tools` (secure-by-default)
  - `agentToolsAllowed: returns enabled tool_name list when agent has rows`
  - `agentToolsAllowed: skips rows where enabled = 0`
- [ ] **Step 3.2:** Run tests — confirm FAIL.
- [ ] **Step 3.3:** Implement:
  ```zig
  pub fn agentToolsAllowed(allocator, db, workspace_item_id) ![]const []const u8 {
      // SELECT id FROM agents WHERE workspace_item_id = ?
      //   empty → return &.{} (not agent item, per D1)
      // SELECT tool_name FROM agent_tools WHERE agent_id = ? AND enabled = 1 ORDER BY tool_name ASC
      //   empty → return &.{} (secure-by-default)
      //   non-empty → return []const []const u8 of dupe'd names
      // Caller MUST treat empty as 'no tools', NOT 'all tools'.
  }
  ```
- [ ] **Step 3.4:** Run tests — confirm PASS.
- [ ] **Step 3.5:** Commit: `agent: add agentToolsAllowed() helper for runtime tool filter`

---

### Task 4 — `workspace_items_create_agent` handler

**Files:**
- `src/ai_workflow/tui/http_handlers/workspace_items_create_agent.zig` (new)
- `src/ai_workflow/tui/http_handlers/workspace_items_create_agent_test.zig` (new) — 5 tests.
- `src/ai_workflow/tui/http_handlers/mod.zig` (edit — re-export).

- [ ] **Step 4.1:** Write `workspace_items_create_agent_test.zig` — 5 tests:
  - `workspaceItemsCreateAgentHandler: returns 201 with {item, agent} on valid request`
  - `workspaceItemsCreateAgentHandler: persists workspace_items row with item_type='agent'`
  - `workspaceItemsCreateAgentHandler: persists agents row with description='' (default)`
  - `workspaceItemsCreateAgentHandler: returns 400 when name is empty`
  - `workspaceItemsCreateAgentHandler: returns 400 when path is missing`
- [ ] **Step 4.2:** Run tests — confirm FAIL.
- [ ] **Step 4.3:** Implement handler. Mirror `workspace_items_create_kanban.zig` with these substitutions:
  - `item_type = 'agent'` (not 'kanban')
  - **No** `kanban_model.seedDefaultColumns` call.
  - **Add** second INSERT into `agents` table (same `id` as workspace_item, per D3).
  - Wrap both INSERTs in `BEGIN`/`COMMIT` (R8).
  - Response: `{item, agent}` shape.
  - `path` is required (Agent has cwd like Kanban/Design).
  - Use `helpers.unixTimestampNanos()` for id generation.
- [ ] **Step 4.4:** Register in `mod.zig`:
  ```zig
  pub const workspaceItemsCreateAgentHandler = @import("workspace_items_create_agent.zig").workspaceItemsCreateAgentHandler;
  ```
- [ ] **Step 4.5:** Run tests — confirm PASS.
- [ ] **Step 4.6:** Commit: `agent: add POST /api/workspaces/:wsId/items/agent handler`

---

### Task 5 — `agents_get` + `agents_update` handlers

**Files:**
- `src/ai_workflow/tui/http_handlers/agents_get.zig` + `_test.zig` (new) — 5 tests.
- `src/ai_workflow/tui/http_handlers/agents_update.zig` + `_test.zig` (new) — 4 tests.
- `src/ai_workflow/tui/http_handlers/mod.zig` (edit — re-export both).

- [ ] **Step 5.1:** Write `agents_get_test.zig` — 5 tests:
  - `agentsGetHandler: returns 200 with {agent, knowledge, tools} on valid request`
  - `agentsGetHandler: returns knowledge ordered by position DESC`
  - `agentsGetHandler: returns tools ordered by tool_name ASC`
  - `agentsGetHandler: returns 404 when workspace_item_id doesn't exist`
  - `agentsGetHandler: returns 400 when item_type != 'agent'`
- [ ] **Step 5.2:** Write `agents_update_test.zig` — 4 tests:
  - `agentsUpdateHandler: updates description and returns 200`
  - `agentsUpdateHandler: returns 404 when workspace_item_id doesn't exist`
  - `agentsUpdateHandler: returns 400 when item_type != 'agent'`
  - `agentsUpdateHandler: returns 400 when body is invalid JSON`
- [ ] **Step 5.3:** Run tests — confirm FAIL.
- [ ] **Step 5.4:** Implement both handlers. Mirror `kanban_columns_get.zig` / `kanban_columns_update.zig` for structural pattern. Each validates the workspace_item is an agent (400 otherwise), returns 404 if missing.
- [ ] **Step 5.5:** Register both in `mod.zig`.
- [ ] **Step 5.6:** Run tests — confirm PASS.
- [ ] **Step 5.7:** Commit: `agent: add GET + PATCH /items/:id/agent handlers`

---

### Task 6 — `agent_knowledge` CRUD handlers (4 endpoints)

**Files:**
- `src/ai_workflow/tui/http_handlers/agent_knowledge_{create,update,delete,reorder}.zig` (new, 4 files)
- `src/ai_workflow/tui/http_handlers/agent_knowledge_{create,update,delete,reorder}_test.zig` (new, 4 files) — ~4 tests each.
- `src/ai_workflow/tui/http_handlers/mod.zig` (edit — re-export all 4).

- [ ] **Step 6.1:** Write 4 test files (16 tests total). Pattern for each:
  - `agentKnowledgeCreateHandler: returns 201 with AgentKnowledgeRow on valid request`
  - `agentKnowledgeCreateHandler: rejects relative path with 400`
  - `agentKnowledgeCreateHandler: rejects missing file_path with 400`
  - `agentKnowledgeCreateHandler: assigns position as COALESCE(MAX+1, 0)` (mirrors kanban_column_create pattern)

  Plus similar for update (path / label / position), delete (200 / 404 / 400 not-agent), reorder (200 / 400 missing `ordered_ids`).
- [ ] **Step 6.2:** Run tests — confirm FAIL.
- [ ] **Step 6.3:** Implement the 4 handlers. Mirror `kanban_columns_{create,update,delete,reorder}.zig` exactly with these substitutions:
  - Validate `file_path` is absolute (`std.fs.path.isAbsolute(file_path)` else 400).
  - `agent_id` is the URL param (NOT the workspace_item_id, per D3).
  - The reorder handler takes `{ordered_ids: []const []const u8}` and assigns position DESC by index 0 (matches Kanban's pattern).
- [ ] **Step 6.4:** Register all 4 in `mod.zig`.
- [ ] **Step 6.5:** Run tests — confirm PASS.
- [ ] **Step 6.6:** Commit: `agent: add agent_knowledge CRUD handlers (create/update/delete/reorder)`

---

### Task 7 — `agent_tools_registry` + `agent_tools_list` handlers

**Files:**
- `src/ai_workflow/tui/http_handlers/agent_tools_registry.zig` + `_test.zig` (new) — 3 tests.
- `src/ai_workflow/tui/http_handlers/agent_tools_list.zig` + `_test.zig` (new) — 4 tests.
- `src/ai_workflow/tui/http_handlers/mod.zig` (edit — re-export both).

- [ ] **Step 7.1:** Write `agent_tools_registry_test.zig` — 3 tests:
  - `agentToolsRegistryHandler: returns 200 with {tools: [{name, description}]} listing every registry entry`
  - `agentToolsRegistryHandler: count matches UNIFIED_TOOL_REGISTRY().len` (use the source-of-truth assertion)
  - `agentToolsRegistryHandler: returns entries with both name and description fields populated`
- [ ] **Step 7.2:** Write `agent_tools_list_test.zig` — 4 tests:
  - `agentToolsListHandler: returns 200 with {tools: [string]} for valid agent`
  - `agentToolsListHandler: returns 200 with empty list when agent has no rows`
  - `agentToolsListHandler: returns 404 when agent_id doesn't exist`
  - `agentToolsListHandler: returns 400 when workspace_items.item_type != 'agent'`
- [ ] **Step 7.3:** Run tests — confirm FAIL.
- [ ] **Step 7.4:** Implement `agent_tools_registry.zig`:
  ```zig
  // Derive the list from tools_equipped.UNIFIED_TOOL_REGISTRY()
  // Each entry: {name, description: tool.tool_def.function.description}
  pub fn agentToolsRegistryHandler(...) !HttpResponse {
      const registry = tools_equipped.UNIFIED_TOOL_REGISTRY();
      // Build [{name, description}, ...] and JSON-encode.
  }
  ```
  Implement `agent_tools_list.zig`: SELECT enabled tool_names from `agent_tools` WHERE `agent_id = ? AND enabled = 1 ORDER BY tool_name ASC`. Validate the workspace_item is an agent.
- [ ] **Step 7.5:** Register both in `mod.zig`.
- [ ] **Step 7.6:** Run tests — confirm PASS.
- [ ] **Step 7.7:** Commit: `agent: add tool registry + list handlers (static + per-agent)`

---

### Task 8 — `agent_tools_create` + `agent_tools_delete` handlers

**Files:**
- `src/ai_workflow/tui/http_handlers/agent_tools_create.zig` + `_test.zig` (new) — 5 tests.
- `src/ai_workflow/tui/http_handlers/agent_tools_delete.zig` + `_test.zig` (new) — 4 tests.
- `src/ai_workflow/tui/http_handlers/mod.zig` (edit — re-export both).

- [ ] **Step 8.1:** Write `agent_tools_create_test.zig` — 5 tests:
  - `agentToolsCreateHandler: returns 201 with AgentToolRow on valid request`
  - `agentToolsCreateHandler: returns 400 when tool_name is not in the registry` (validate against `UNIFIED_TOOL_REGISTRY()`)
  - `agentToolsCreateHandler: returns 400 when body is invalid JSON`
  - `agentToolsCreateHandler: returns 409 on duplicate (agent_id, tool_name)`
  - `agentToolsCreateHandler: returns 404 when agent doesn't exist`
- [ ] **Step 8.2:** Write `agent_tools_delete_test.zig` — 4 tests:
  - `agentToolsDeleteHandler: returns 200 with {ok: true} when tool row exists`
  - `agentToolsDeleteHandler: returns 404 when tool_id doesn't exist`
  - `agentToolsDeleteHandler: returns 400 when workspace_items.item_type != 'agent'`
  - `agentToolsDeleteHandler: cascade-deletes when agent is deleted`
- [ ] **Step 8.3:** Run tests — confirm FAIL.
- [ ] **Step 8.4:** Implement both handlers. Mirror `kanban_columns_create.zig` / `kanban_columns_delete.zig` patterns:
  - **Create**: validate `tool_name` ∈ `UNIFIED_TOOL_REGISTRY()` (400 if not). INSERT into `agent_tools` with `enabled = 1`. Map SQLite UNIQUE violation to HTTP 409.
  - **Delete**: DELETE from `agent_tools` WHERE `id = ?`. Return `{ok: true}`.
- [ ] **Step 8.5:** Register both in `mod.zig`.
- [ ] **Step 8.6:** Run tests — confirm PASS.
- [ ] **Step 8.7:** Commit: `agent: add tool create + delete handlers with registry validation`

---

### Task 9 — Register 12 routes in `src/main.zig`

**File:** `src/main.zig` (edit — register all 12 new routes around line 388, after the existing kanban/design routes).

- [ ] **Step 9.1:** Read `src/main.zig` lines 380–395 to find the right insertion point.
- [ ] **Step 9.2:** Add 12 routes (mirror existing patterns):

  ```zig
  // === AGENT MODE (Migration 076 — task_1786962724740_0) ===
  try gs.router.post("/api/workspaces/:workspace_id/items/agent", ai_mod.http_handlers.workspaceItemsCreateAgentHandler);
  try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/agent", ai_mod.http_handlers.agentsGetHandler);
  try gs.router.patch("/api/workspaces/:workspace_id/items/:item_id/agent", ai_mod.http_handlers.agentsUpdateHandler);
  try gs.router.post("/api/agents/:agent_id/knowledge", ai_mod.http_handlers.agentKnowledgeCreateHandler);
  try gs.router.patch("/api/agents/:agent_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKnowledgeUpdateHandler);
  try gs.router.delete("/api/agents/:agent_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKnowledgeDeleteHandler);
  try gs.router.patch("/api/agents/:agent_id/knowledge/reorder", ai_mod.http_handlers.agentKnowledgeReorderHandler);
  try gs.router.get("/api/agent-tools/registry", ai_mod.http_handlers.agentToolsRegistryHandler);
  try gs.router.get("/api/agents/:agent_id/tools", ai_mod.http_handlers.agentToolsListHandler);
  try gs.router.post("/api/agents/:agent_id/tools", ai_mod.http_handlers.agentToolsCreateHandler);
  try gs.router.delete("/api/agents/:agent_id/tools/:tool_id", ai_mod.http_handlers.agentToolsDeleteHandler);
  ```
  (11 routes — `agentsUpdate` is the 12th, included above. Total = 11 new HTTP endpoints + 1 registry read-only = 12.)

- [ ] **Step 9.3:** Run `zig build test --summary all` — must still be green (no compile error from the registration).
- [ ] **Step 9.4:** Commit: `agent: register 12 new routes in main.zig router`

---

### Task 10 — `prompts_make_agent_knowledge.zig`

**Files:**
- `src/ai_workflow/tui/agentic_loop/prompts_make_agent_knowledge.zig` (new)
- `src/ai_workflow/tui/agentic_loop/prompts_make_agent_knowledge_test.zig` (new) — 6 tests.

- [ ] **Step 10.1:** Write tests — 6 tests:
  - `makeAgentKnowledge: returns empty slice for non-agent items`
  - `makeAgentKnowledge: returns empty slice when agent has no rows in agent_knowledge`
  - `makeAgentKnowledge: returns empty slice when file_path doesn't exist` (logged + skipped)
  - `makeAgentKnowledge: returns ## Agent Knowledge section with file contents for valid entries`
  - `makeAgentKnowledge: respects position DESC ordering`
  - `makeAgentKnowledge: skips files > 100 MiB with logged warning`
- [ ] **Step 10.2:** Run tests — confirm FAIL.
- [ ] **Step 10.3:** Implement:
  ```zig
  pub const MAX_FILE_BYTES_OOM_SAFETY: usize = 100 * 1024 * 1024;  // 100 MiB

  pub fn makeAgentKnowledge(allocator, db, session_id) ![]const u8 {
      // 1. SELECT workspace_item_id FROM workspace_item_tasks WHERE id = ? (returns '' if no session)
      // 2. SELECT item_type FROM workspace_items WHERE id = workspace_item_id. If not 'agent', return ''.
      // 3. SELECT * FROM agent_knowledge WHERE agent_id = workspace_item_id ORDER BY position DESC
      // 4. For each row:
      //    std.fs.openFile(file_path) → on fail, std.log.warn + skip
      //    contents = file.readToEndAlloc(allocator, MAX_FILE_BYTES_OOM_SAFETY)
      //      on StreamTooLong, std.log.warn + skip
      //    Append `\n### <label or basename>\n<file: absolute_path>\n\n<content>\n`
      // 5. Prepend `\n\n## Agent Knowledge\n\n` + disclaimer
      // 6. Return assembled string
  }
  ```
- [ ] **Step 10.4:** Run tests — confirm PASS.
- [ ] **Step 10.5:** Commit: `agent: add makeAgentKnowledge() prompt section builder`

---

### Task 11 — Wire `makeAgentKnowledge` into prompt assembly

**File:** find the call site of `prompts_make_workspace_context.zig` (it's wired via `prompts_assemble.zig` or similar per the spec — search for the function that builds the system prompt and appends workspace context).

- [ ] **Step 11.1:** Locate the call site:
  ```bash
  grep -rn "makeWorkspaceContext" /home/ginwa/ginwaaitoolbox/src/ai_workflow/tui
  ```
- [ ] **Step 11.2:** Read the file and identify where to add the agent knowledge section. The wiring is one of:
  - Append `makeAgentKnowledge` output after `makeWorkspaceContext` output.
  - OR pass both into a wrapper function.
- [ ] **Step 11.3:** Make the surgical edit. No new test (this is integration glue; the unit test on `makeAgentKnowledge` covers the function itself; an end-to-end chat test would be the next layer, deferred).
- [ ] **Step 11.4:** Verify `zig build test --summary all` is still green.
- [ ] **Step 11.5:** Commit: `agent: wire makeAgentKnowledge into system-prompt assembly pipeline`

---

### Task 12 — Runtime tool filter integration

**Files:**
- `src/ai_workflow/tui/agentic_loop/workflow.zig` (edit — single conditional at the `runAgenticMultiStepnew` entry, where `allowed_tools` is computed).
- `src/ai_workflow/tui/agentic_loop/workflow_test.zig` (edit — add 1 agent-filter integration test).

- [ ] **Step 12.1:** Read `workflow.zig` around lines 420–460 (where `WorkflowArgs.allowed_tools` is set from `params.allowed_tools`). Identify the entry point.
- [ ] **Step 12.2:** Write the failing integration test in `workflow_test.zig`:
  ```zig
  test "runAgenticMultiStepnew: agent session with empty allowlist registers zero tools" { ... }
  test "runAgenticMultiStepnew: agent session with allowlist registers only allowlisted tools" { ... }
  test "runAgenticMultiStepnew: non-agent session is unchanged (full tool registry)" { ... }
  ```
  Each test:
  - Sets up a session bound to a workspace_item with item_type='agent' (or 'kanban' for the negative test).
  - Mocks an LLM response (or short-circuits before the LLM call).
  - Asserts the resulting `merged_tools.len` matches the expected count.
  - For the allowlist test, asserts specific tool names are present.
- [ ] **Step 12.3:** Run tests — confirm FAIL.
- [ ] **Step 12.4:** Make the surgical edit in `workflow.zig`. At the top of the section that resolves `allowed_tools` from `params.allowed_tools`, add:
  ```zig
  // AGENT MODE: if session is bound to an agent, override allowed_tools
  // with the comma-separated allowlist from agent_tools (D1, D2).
  // Non-agent sessions pass through unchanged.
  if (params.is_sub_agent == false) {  // only filter top-level sessions
      if (try isAgentItem(db, workspace_item_id_from_session)) {
          const allowed = try agent_tools_allowed.agentToolsAllowed(allocator, db, workspace_item_id_from_session);
          defer allocator.free(allowed);
          if (allowed.len == 0) {
              copy_allowed_tools = "";  // secure-by-default: no tools
          } else {
              // Join with commas
              copy_allowed_tools = try std.mem.join(allocator, ",", allowed);
              defer allocator.free(copy_allowed_tools);
          }
      }
  }
  ```
  Note: this reuses `filterAndMergeTools`'s existing semantics (`""` = no tools, comma-separated = specific).
- [ ] **Step 12.5:** Run tests — confirm PASS. Verify `zig build test --summary all` is green (no regressions to existing sub-agent tests).
- [ ] **Step 12.6:** Commit: `agent: integrate agent_tools_allowed into workflow runtime filter`

---

### Task 13 — Frontend: TS types + API wrappers + store actions

**Files:**
- `src/apps/desktop/src/api/index.ts` (edit — 13 new typed wrappers).
- `src/apps/desktop/src/stores/workspaces.ts` (edit — 6 new actions).

- [ ] **Step 13.1:** Add TS types for `Agent`, `AgentKnowledgeRow`, `AgentToolRow`, `AgentRegistryEntry` in `api/index.ts` (around the existing `KanbanColumnInfo` / similar).
- [ ] **Step 13.2:** Add 13 typed wrappers:
  ```ts
  export async function createAgent(workspaceId: string, name: string, path: string): Promise<{ item: WorkspaceItem; agent: Agent }>
  export async function getAgent(workspaceId: string, itemId: string): Promise<{ agent: Agent; knowledge: AgentKnowledgeRow[]; tools: string[] }>
  export async function updateAgent(workspaceId: string, itemId: string, description: string): Promise<{ agent: Agent }>
  export async function addAgentKnowledge(agentId: string, filePath: string, label?: string, position?: number): Promise<AgentKnowledgeRow>
  export async function updateAgentKnowledge(agentId: string, knowledgeId: string, updates: { file_path?: string; label?: string; position?: number }): Promise<AgentKnowledgeRow>
  export async function deleteAgentKnowledge(agentId: string, knowledgeId: string): Promise<{ ok: true }>
  export async function reorderAgentKnowledge(agentId: string, orderedIds: string[]): Promise<{ ok: true }>
  export async function getAgentToolsRegistry(): Promise<{ tools: AgentRegistryEntry[] }>
  export async function getAgentTools(agentId: string): Promise<{ tools: string[] }>
  export async function addAgentTool(agentId: string, toolName: string): Promise<AgentToolRow>
  export async function deleteAgentTool(agentId: string, toolId: string): Promise<{ ok: true }>
  ```
  Each is a thin wrapper around `apiFetch()` using the existing pattern from `api/index.ts` lines 1519–1620 (`createWorkspaceItem`, `createKanban`).
- [ ] **Step 13.3:** Add 6 new actions to `workspaces.ts` store (mirror `addKanbanItem` pattern):
  ```ts
  async function addAgentItem(workspaceId, name, path) { /* POST /items/agent, push to store */ }
  async function fetchAgent(workspaceId, itemId) { /* GET, push knowledge + tools to local state */ }
  async function addKnowledgeEntry(agentId, filePath, label) { /* POST, append to local state */ }
  async function removeKnowledgeEntry(agentId, knowledgeId) { /* DELETE, remove from local state */ }
  async function updateKnowledgeEntry(agentId, knowledgeId, updates) { /* PATCH, update local state */ }
  async function reorderKnowledge(agentId, orderedIds) { /* PATCH, reorder local state */ }
  async function enableTool(agentId, toolName) { /* POST, add to local state */ }
  async function disableTool(agentId, toolId) { /* DELETE, remove from local state */ }
  ```
  Also add 2 tool actions in the same file (or a separate file — decide based on locality).
- [ ] **Step 13.4:** Verify `bun run build` is green (TS type-check).
- [ ] **Step 13.5:** Commit: `agent(frontend): add TS types + 13 API wrappers + 8 store actions`

---

### Task 14 — `agentTools` Pinia store + tests

**Files:**
- `src/apps/desktop/src/stores/agentTools.ts` (new) — registry fetch + caching.
- `src/apps/desktop/src/__tests__/agentToolsStore.spec.ts` (new) — 4 tests.

- [ ] **Step 14.1:** Write `agentToolsStore.spec.ts` — 4 tests:
  - `agentTools store: fetches registry on first call`
  - `agentTools store: caches registry across calls (1 fetch total)`
  - `agentTools store: exposes error ref when fetch fails`
  - `agentTools store: isToolEnabled(name) helper returns true when name is in enabled list`
- [ ] **Step 14.2:** Run tests — confirm FAIL.
- [ ] **Step 14.3:** Implement the Pinia store:
  ```ts
  export const useAgentToolsStore = defineStore('agentTools', () => {
    const registry = ref<AgentRegistryEntry[]>([])
    const error = ref<string | null>(null)
    let fetched = false

    async function fetchRegistry(force = false) {
      if (fetched && !force) return
      try {
        const data = await api.getAgentToolsRegistry()
        registry.value = data.tools
        error.value = null
        fetched = true
      } catch (e) {
        error.value = String(e)
      }
    }

    function isToolEnabled(enabledList: string[], name: string): boolean {
      return enabledList.includes(name)
    }

    return { registry, error, fetchRegistry, isToolEnabled }
  })
  ```
- [ ] **Step 14.4:** Run tests — confirm PASS.
- [ ] **Step 14.5:** Commit: `agent(frontend): add agentTools Pinia store with registry fetch`

---

### Task 15 — `AddAgentDialog.vue` + tests

**Files:**
- `src/apps/desktop/src/components/dialogs/AddAgentDialog.vue` (new)
- `src/apps/desktop/src/__tests__/AddAgentDialog.spec.ts` (new) — 3 tests.

- [ ] **Step 15.1:** Write `AddAgentDialog.spec.ts` — 3 tests (mirror `AddKanbanDialog.spec.ts`):
  - `AddAgentDialog: shows "Add Agent" title and a name input when show=true`
  - `AddAgentDialog: name is required (Add button disabled when empty)`
  - `AddAgentDialog: emits 'create' with (name, path) when Add is clicked`
- [ ] **Step 15.2:** Run tests — confirm FAIL.
- [ ] **Step 15.3:** Implement `AddAgentDialog.vue`. Mirror `AddKanbanDialog.vue`:
  - `<Teleport to="body">` wrapper.
  - Name input + folder picker (reuse `FilePickerDialog` in folder mode).
  - Emit `create(name, path)` on submit.
  - Title: "Add Agent". Description: "Select a folder to add as an Agent".
- [ ] **Step 15.4:** Run tests — confirm PASS.
- [ ] **Step 15.5:** Verify `bun run build` is green.
- [ ] **Step 15.6:** Commit: `agent(frontend): add AddAgentDialog component`

---

### Task 16 — `AgentKnowledgeDialog.vue` + tests

**Files:**
- `src/apps/desktop/src/components/dialogs/AgentKnowledgeDialog.vue` (new)
- `src/apps/desktop/src/__tests__/AgentKnowledgeDialog.spec.ts` (new) — 4 tests.

- [ ] **Step 16.1:** Write `AgentKnowledgeDialog.spec.ts` — 4 tests:
  - `AgentKnowledgeDialog: shows "Add Knowledge" title when show=true`
  - `AgentKnowledgeDialog: file_path is required (Add button disabled when empty)`
  - `AgentKnowledgeDialog: client-side validates path is absolute (error shown for relative)`
  - `AgentKnowledgeDialog: emits 'create' with (file_path, label) when Add clicked`
- [ ] **Step 16.2:** Run tests — confirm FAIL.
- [ ] **Step 16.3:** Implement `AgentKnowledgeDialog.vue`:
  - `<Teleport to="body">` wrapper.
  - Path input + optional "Browse" button (opens `FilePickerDialog` in `mode='file'`).
  - Optional label input.
  - Client-side absolute path validation (`path.startsWith('/')`).
  - Emit `create(file_path, label)`.
- [ ] **Step 16.4:** Run tests — confirm PASS.
- [ ] **Step 15.5:** Verify `bun run build` is green.
- [ ] **Step 16.6:** Commit: `agent(frontend): add AgentKnowledgeDialog component`

---

### Task 17 — `AgentView.vue` + tests

**Files:**
- `src/apps/desktop/src/components/views/AgentView.vue` (new)
- `src/apps/desktop/src/__tests__/AgentView.spec.ts` (new) — 6 tests.

- [ ] **Step 17.1:** Write `AgentView.spec.ts` — 6 tests:
  - `AgentView: renders Knowledge panel with entries from props.knowledge`
  - `AgentView: emits 'add-knowledge' when + Add Knowledge clicked`
  - `AgentView: emits 'remove-knowledge' when remove clicked`
  - `AgentView: renders Tools panel with checkboxes from registry, checked state matches props.tools`
  - `AgentView: emits 'toggle-tool' with (name, enabled) when checkbox toggled`
  - `AgentView: emits 'new-chat' when New Chat button clicked`
- [ ] **Step 17.2:** Run tests — confirm FAIL.
- [ ] **Step 17.3:** Implement `AgentView.vue` (D11). Layout:
  - **Top section** — Knowledge panel: list of entries with path + label + remove button + "Add Knowledge" button. Empty state: "No knowledge files yet — click + Add Knowledge to attach a markdown file."
  - **Middle section** — Tools panel: checkbox list rendered from `agentToolsStore.registry`. Each checkbox's `checked` state = `props.tools.includes(name)`. Empty state (registry error): "Tool registry unavailable." Tip line at top: "Toggle to give this Agent capabilities. Empty = pure chat (no tools)."
  - **Right section** — Chat list: existing chat tasks under this Agent (filtered by workspace_item_id). "New Chat" button at top.
- [ ] **Step 17.4:** Run tests — confirm PASS.
- [ ] **Step 17.5:** Verify `bun run build` is green.
- [ ] **Step 17.6:** Commit: `agent(frontend): add AgentView with Knowledge + Tools + Chat sections`

---

### Task 18 — `AgentChatDialog.vue` + tests

**Files:**
- `src/apps/desktop/src/components/dialogs/AgentChatDialog.vue` (new)
- `src/apps/desktop/src/__tests__/AgentChatDialog.spec.ts` (new) — 3 tests.

- [ ] **Step 18.1:** Write `AgentChatDialog.spec.ts` — 3 tests:
  - `AgentChatDialog: shows the existing ChatView when show=true and task is set`
  - `AgentChatDialog: emits 'close' when close button clicked`
  - `AgentChatDialog: passes cwd + itemId to ChatView`
- [ ] **Step 18.2:** Run tests — confirm FAIL.
- [ ] **Step 18.3:** Implement `AgentChatDialog.vue`. Mirror `KanbanChatDialog.vue`:
  - `<Teleport to="body">` wrapper.
  - Renders the existing `<ChatView>` with `:task`, `:workspace-id`, `:item-id`, `:cwd` props.
  - `v-model:show` drives visibility.
  - `@close` emits to parent.
- [ ] **Step 18.4:** Run tests — confirm PASS.
- [ ] **Step 18.5:** Verify `bun run build` is green.
- [ ] **Step 18.6:** Commit: `agent(frontend): add AgentChatDialog wrapping ChatView`

---

### Task 19 — Frontend wiring (WorkspaceList + Sidebar + AppLayout)

**Files:**
- `src/apps/desktop/src/components/workspace/WorkspaceList.vue` (edit — add "Add Agent" dropdown option).
- `src/apps/desktop/src/components/shell/Sidebar.vue` (edit — handleAddItem routing + handleCreateAgent).
- `src/apps/desktop/src/components/AppLayout.vue` (edit — AgentView + AgentChatDialog mounts).
- `src/apps/desktop/src/__tests__/workspacesStore.spec.ts` (edit — add 2 tests for the new actions).

- [ ] **Step 19.1:** Edit `WorkspaceList.vue` lines 645–660 to add a 4th `<li>` after "Add Design":
  ```html
  <li>
    <button @click="handleAddItem(workspace.id, 'agent')"
            class="w-full px-3 py-2 text-left text-sm hover:opacity-80 transition-opacity"
            style="color: var(--semantic-text);"
            data-testid="workspace-add-agent-option">
      Add Agent
    </button>
  </li>
  ```
- [ ] **Step 19.2:** Edit `Sidebar.vue` `handleAddItem` (line 475):
  ```ts
  if (itemType === 'agent') showAddAgentDialog.value = true
  ```
  Add `showAddAgentDialog` ref + `handleCreateAgent(name, path)` mirror of `handleCreateKanban` + import + mount `AddAgentDialog` in the template.
- [ ] **Step 19.3:** Edit `AppLayout.vue` — add a new `v-else-if` branch after the DesignView branch (line 2053):
  ```html
  <AgentView v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'agent'"
             :key="'agent-' + activeWorkspaceItem.id"
             :item="activeWorkspaceItem"
             :workspace-id="activeWorkspace?.id ?? ''"
             :item-id="activeWorkspaceItem.id"
             :knowledge="agentKnowledge"
             :tools="agentTools"
             @add-knowledge="handleAgentAddKnowledge"
             @remove-knowledge="handleAgentRemoveKnowledge"
             @update-knowledge="handleAgentUpdateKnowledge"
             @toggle-tool="handleAgentToggleTool"
             @new-chat="handleAgentNewChat"
             @select-task="handleAgentSelectTask" />
  <AgentChatDialog v-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'agent' && activeTask && activeTaskWorkspaceItemId === activeWorkspaceItem.id"
                   v-model:show="agentChatDialogOpen"
                   :task="activeTask"
                   :workspace-id="activeWorkspace?.id ?? ''"
                   :item-id="activeWorkspaceItem.id"
                   :cwd="activeWorkspaceItem.path ?? ''"
                   @close="handleCloseTaskView" />
  ```
  Implement the 6 `handleAgent*` methods (mirror the existing kanban handlers).
- [ ] **Step 19.4:** Add 2 tests to `workspacesStore.spec.ts`:
  - `workspacesStore.addAgentItem: calls api.createAgent and pushes to state`
  - `workspacesStore.enableTool: calls api.addAgentTool and updates local enabled list`
- [ ] **Step 19.5:** Verify `bun run build` is green.
- [ ] **Step 19.6:** Verify `bunx vitest run src/apps/desktop/src/__tests__` passes.
- [ ] **Step 19.7:** Commit: `agent(frontend): wire Agent into sidebar dropdown + Sidebar + AppLayout`

---

### Task 20 — Final verification

- [ ] **Step 20.1:** Full Zig test suite green.
  ```bash
  cd /home/ginwa/ginwaaitoolbox/.worktrees/agent-mode
  timeout 600 zig build test --summary all 2>&1 | tail -5
  ```
  Expected: `All N tests passed` (N > baseline by ~30 new tests).
- [ ] **Step 20.2:** Full frontend build + test green.
  ```bash
  timeout 120 bun run build 2>&1 | tail -5
  timeout 180 bunx vitest run 2>&1 | tail -10
  ```
- [ ] **Step 20.3:** Delete any `vue-tsc --build` emitted `.js` files:
  ```bash
  find src/apps/desktop/src -name "*.js" -newer src/apps/desktop/src/main.ts -delete
  git status --short  # should NOT show .js files
  ```
- [ ] **Step 20.4:** Manual smoke test (the 5-step checklist from the spec):
  1. Add an Agent via the sidebar (data-testid `workspace-add-agent-option`).
  2. Confirm the Tools panel renders an unchecked checkbox per available tool (registry count = N).
  3. Confirm a chat opened under the Agent with no tools toggled has zero tools (ask the LLM "what tools do you have?" — expect "I have no tools").
  4. Enable `bash` + `read_file`, start a new chat, confirm the LLM can call them (and not others — ask for a Kanban operation, expect failure).
  5. Add 2-3 markdown files to the Knowledge panel. Confirm the agent references the file contents in its first response. Delete one entry, start a new chat — confirm the deleted file is no longer referenced.
- [ ] **Step 20.5:** Use port 8080 for any manual HTTP smoke (per "No port 8081" constraint).
- [ ] **Step 20.6:** Move kanban card to `in_review_task` via `kanban_move_task` to `col_1826ecca367f0000`.
- [ ] **Step 20.7:** Commit (if any cleanup needed): `agent: final verification + cleanup`. Else no commit.
- [ ] **Step 20.8:** Push branch + open PR for user review.

---

## Verification

- [ ] All tasks completed.
- [ ] `zig build test --summary all` passes (≥ 30 new tests added, no regressions).
- [ ] `bun run build` passes (no TS errors).
- [ ] `bunx vitest run` passes (no frontend regressions).
- [ ] No `.js` files in `git status`.
- [ ] Manual smoke (Task 20.4) confirms end-to-end behavior.
- [ ] Kanban card in `in_review_task`.

## Out of scope (deferred)

- System-prompt override (`agents.system_prompt_override TEXT`)
- Per-chat knowledge override
- In-app markdown editor for knowledge files
- Embedding / vector search / RAG
- Knowledge file watching (re-reads only on session start)
- Per-entry toggle (`agent_knowledge.enabled`)
- Drag-reorder for tools (unordered allowlist)