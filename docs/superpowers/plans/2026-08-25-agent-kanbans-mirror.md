# Agent Kanbans Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror the agent menu feature (agents / agent_knowledge / agent_system_prompt / agent_tools) onto kanban boards — `agent_kanbans` (1-1 with `workspace_item_id` where `item_type='kanban'`) plus `agent_kanban_knowledges`, `agent_kanban_system_prompt`, `agent_kanban_tools` children, with full CRUD HTTP routes, prompt injection, tool allowlist wiring, and a frontend settings panel on the kanban view.

**Architecture:** A straight structural mirror of the existing agent-menu stack. One migration (081) creates all 4 tables. The handler family (`agent_kanbans_*.zig`, 11 files) clones the `agents_*`/`agent_knowledge_*`/`agent_system_prompt_*`/`agent_tools_*` pattern (useCase + thin Handler split, two-switch error mapping, no SSE). Prompt injection adds two new block builders (`makeAgentKanbanKnowledge`, `makeAgentKanbanSystemPrompt`) appended in `buildMessages` alongside the agent blocks, and the tool allowlist gets a `maybeOverrideAllowedToolsForKanban` mirror in `workflow.zig`. Frontend reuses the AgentView panel components via props so there is one implementation of each panel.

**Tech Stack:** Zig backend (SQLite migrations, custom HTTP server), Vue 3 + TypeScript + Pinia frontend, pytest functional harness for wire tests.

## Global Constraints

- **Next free migration version = 81.** Highest registered is 80 (`Migration080AddAgentSystemPrompt`). Trust the `version: u32` field, NOT the struct name (struct names diverge from versions).
- **DONT KILL THE PORT 8081 SERVER.** Functional tests use the harness at `tests/functional/harness.py` which picks a free port in 8080..8199.
- **Never spin up a live server + curl for verification** — use the python functional harness (isolated tmpdir HOME per test) and/or Zig static-contract tests.
- **Empty-slice-as-NULL rule:** `SqliteBackend.exec` binds `""` as SQL NULL → every INSERT of a nullable-default TEXT column must use `COALESCE(?, '')`; SELECTs must wrap timestamps in `IFNULL(..., '')`.
- **Route-order shadowing:** literal segments (`reorder`, `registry`) MUST be registered BEFORE `:param` routes — `matchRoute` walks registration order.
- **Per-request arena:** handlers allocate from `ctx.allocator` (arena) → NO `defer allocator.free` inside handlers.
- **Tests live INLINE at the bottom of impl files** (`test "..." { }` blocks) except HTTP-handler test files which need explicit `_ = @import(...)` lines in `src/ai_workflow/tui/test_runner.zig`.
- **Test DBs must use `migration.registerAllMigrations` + `manager.runMigrations()`**, never hand-rolled CREATE TABLE.
- **SSE:** the entire agent_* handler family emits NO SSE events; the kanban mirror stays silent too. Frontend re-fetches after mutations.
- Naming: user asked for `agent_kanbans` / `agent_kanban_knowledges` / `agent_kanban_system_prompt` / `agent_kanban_tools` — keep these exact table names even though they're verbose.
- Secure-by-default preserved: empty `agent_kanban_tools` allowlist = zero tools for kanban sessions that opt in (see Task 6 note on default behavior).

---

## Design Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | `agent_kanbans.id == workspace_item_id` (same string), `workspace_item_id TEXT NOT NULL UNIQUE` | Mirrors spec D3 of agent mode (`agents.id == workspace_item_id`). Makes prompt-injection identity chain trivially reusable. |
| D2 | Four separate tables, not polymorphic | User explicitly requested this shape; mirrors agent tables exactly; FK CASCADE gives cleanup for free. |
| D3 | Routes under `/api/agent-kanbans/:kanban_id/knowledge|system_prompt|tools` + bundle `GET /api/workspaces/:ws/items/:item_id/agent_kanban` | Mirrors `/api/agents/:agent_id/...` shape exactly. |
| D4 | Prompt blocks named `## Kanban System Prompt` and `## Kanban Knowledge`, injected ONLY when the session's item is a kanban WITH an `agent_kanbans` row | Non-configured kanbans are completely unaffected — zero behavior change unless the user configures the board. |
| D5 | Tool override only fires when an `agent_kanbans` row exists AND it has ≥1 enabled `agent_kanban_tools` row... **with one exception**: if the row exists but has ZERO enabled tools rows, we treat it as "not configured" and leave defaults (see Task 6 discussion). | Avoids bricking every unconfigured kanban. The strict secure-by-default variant is offered as an alternative in Task 6. |
| D6 | Frontend: new `KanbanAgentPanel.vue` section inside `KanbanView.vue` header area (⚙ button opens a slide-over/dialog), reusing `AgentKnowledgeDialog.vue`, `AgentKnowledgeDetailDialog.vue`, `AgentSystemPromptDialog.vue` unchanged | Dialogs are already generic (props/emits); avoids duplicating 700+ lines of UI. |

---

## File Structure

### New files (backend)

```
src/migrations/migration.zig                          # EDIT — Migration081 + inline tests
src/ai_workflow/tui/http_handlers/
  agent_kanbans_get.zig                               # GET bundle {agent_kanban, knowledges, tools, system_prompts}
  agent_kanbans_update.zig                            # PATCH description
  agent_kanban_knowledge_create.zig
  agent_kanban_knowledge_update.zig
  agent_kanban_knowledge_reorder.zig
  agent_kanban_knowledge_delete.zig
  agent_kanban_system_prompt_create.zig
  agent_kanban_system_prompt_update.zig
  agent_kanban_system_prompt_reorder.zig
  agent_kanban_system_prompt_delete.zig
  agent_kanban_tools_list.zig
  agent_kanban_tools_create.zig
  agent_kanban_tools_delete.zig
src/ai_workflow/tui/agentic_loop/
  prompts_make_agent_kanban_knowledge.zig             # makeAgentKanbanKnowledge()
  prompts_make_agent_kanban_system_prompt.zig         # makeAgentKanbanSystemPrompt()
  agent_kanban_tools_allowed.zig                      # agentKanbanToolsAllowed()
```

### Edited files (backend)

```
src/main.zig                                          # route registrations (~line 432, after agent block)
src/ai_workflow/tui/http_handlers/mod.zig             # re-exports (~line 70)
src/ai_workflow/tui/test_runner.zig                   # _ = @import(...) lines for new handler test files
src/root.zig                                          # re-export new agentic_loop modules (check how agent_* ones are wired)
src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig   # append 2 new blocks (~line 213)
src/ai_workflow/tui/agentic_loop/mod.zig              # re-export new prompt helpers (mirrors prompts_mod wiring)
src/ai_workflow/tui/workflow.zig                      # maybeOverrideAllowedToolsForKanban (~line 1957) + call site (~line 440)
```

### New files (frontend)

```
src/apps/desktop/src/components/kanban/KanbanAgentSettings.vue   # settings dialog hosting the 3 panels
```

### Edited files (frontend)

```
src/apps/desktop/src/api/index.ts                     # types + ~14 wrapper functions (after line 3940)
src/apps/desktop/src/components/kanban/KanbanView.vue # ⚙ button + mount settings dialog
src/apps/desktop/src/components/AppLayout.vue         # state refs + handlers OR keep wiring local to KanbanView (Task 9 decides)
```

---

## Tasks

### Task 1 — Migration 081: create the 4 tables

**Files:** `src/migrations/migration.zig`

- [ ] Write failing inline tests FIRST (below where Migration081 will sit):
  - `Migration081 creates agent_kanbans with UNIQUE workspace_item_id` — assert column shape via `columnsOf` helper.
  - `Migration081 creates agent_kanban_knowledges with content column` (include `content TEXT NOT NULL DEFAULT ''` from day one — no repeat of the 078→079 add-column dance).
  - `Migration081 creates agent_kanban_system_prompt and agent_kanban_tools`.
  - `Migration081 is registered in allMigrations` — iterate `allMigrations`, assert `m.version == 81`.
  - `Deleting workspace_item cascades to agent_kanbans and children` — wire a real `workspace_items` row, delete it, assert all 4 tables empty (copy Migration080's cascade test at migration.zig:4364).
  - `UNIQUE workspace_item_id rejects second agent_kanbans row`.
- [ ] Run `zig build test --summary all` — new tests FAIL (tables don't exist).
- [ ] Implement `pub const Migration081CreateAgentKanbans = struct { ... }`:
  ```sql
  CREATE TABLE IF NOT EXISTS agent_kanbans (
      id TEXT PRIMARY KEY,
      workspace_item_id TEXT NOT NULL UNIQUE,
      description TEXT NOT NULL DEFAULT '',
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
  );
  CREATE INDEX IF NOT EXISTS idx_agent_kanbans_workspace_item_id ON agent_kanban_knowledges(workspace_item_id);
  -- (fix table name in index: ON agent_kanbans(workspace_item_id))

  CREATE TABLE IF NOT EXISTS agent_kanban_knowledges (
      id TEXT PRIMARY KEY,
      kanban_id TEXT NOT NULL,
      file_path TEXT NOT NULL DEFAULT '',
      label TEXT NOT NULL DEFAULT '',
      content TEXT NOT NULL DEFAULT '',
      position INTEGER NOT NULL DEFAULT 0,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (kanban_id) REFERENCES agent_kanbans(id) ON DELETE CASCADE
  );
  CREATE INDEX IF NOT EXISTS idx_agent_kanban_knowledges_kanban_id ON agent_kanban_knowledges(kanban_id);
  CREATE INDEX IF NOT EXISTS idx_agent_kanban_knowledges_kanban_position ON agent_kanban_knowledges(kanban_id, position DESC);

  CREATE TABLE IF NOT EXISTS agent_kanban_system_prompt (
      id TEXT PRIMARY KEY,
      kanban_id TEXT NOT NULL,
      title TEXT NOT NULL DEFAULT '',
      content TEXT NOT NULL DEFAULT '',
      position INTEGER NOT NULL DEFAULT 0,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (kanban_id) REFERENCES agent_kanbans(id) ON DELETE CASCADE
  );
  CREATE INDEX IF NOT EXISTS idx_agent_kanban_system_prompt_kanban_id ON agent_kanban_system_prompt(kanban_id);
  CREATE INDEX IF NOT EXISTS idx_agent_kanban_system_prompt_kanban_position ON agent_kanban_system_prompt(kanban_id, position DESC);

  CREATE TABLE IF NOT EXISTS agent_kanban_tools (
      id TEXT PRIMARY KEY,
      kanban_id TEXT NOT NULL,
      tool_name TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (kanban_id) REFERENCES agent_kanbans(id) ON DELETE CASCADE
  );
  CREATE INDEX IF NOT EXISTS idx_agent_kanban_tools_kanban_id ON agent_kanban_tools(kanban_id);
  CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_kanban_tools_kanban_tool ON agent_kanban_tools(kanban_id, tool_name);
  ```
  - `version: u32 = 81`, `name = "create_agent_kanbans_mirror"`, register in `allMigrations` after Migration080's entry (~line 1955).
  - NOTE vs agent tables: `file_path` here is `NOT NULL DEFAULT ''` (NOT plain `NOT NULL`) because knowledge supports file XOR text mode from day one — avoids a follow-up migration like 079.
- [ ] Run `zig build test --summary all` — new tests PASS, full suite green.
- [ ] Commit: `migration 081: agent_kanbans + knowledges + system_prompt + tools tables`

### Task 2 — Bundle + update handlers (`agent_kanbans_get.zig`, `agent_kanbans_update.zig`)

**Files:** `src/ai_workflow/tui/http_handlers/agent_kanbans_get.zig`, `agent_kanbans_update.zig`, `mod.zig`, `test_runner.zig`, `src/main.zig`

Mirror `agents_get.zig` / `agents_update.zig` exactly, substituting:

| agent world | kanban world |
|---|---|
| `GET /api/workspaces/:ws/items/:item/agent` | `GET /api/workspaces/:ws/items/:item/agent_kanban` |
| validate `item_type == 'agent'` | validate `item_type == 'kanban'` |
| `SELECT ... FROM agents WHERE workspace_item_id = ?` | `SELECT ... FROM agent_kanbans WHERE workspace_item_id = ?` |
| children keyed `agent_id` | children keyed `kanban_id` |

- [ ] Write failing static-contract tests in `agent_kanbans_get_test.zig`: route strings present in main.zig AFTER the agent block; response JSON keys `{agent_kanban, knowledges, tools, system_prompts}`; `IFNULL` guards present; error switches exhaustive.
- [ ] Implement `agentKanbansGetHandler`: 400 empty ids → 404 item missing → 400 `ItemNotKanban` if `item_type != 'kanban'` → 404 `NotConfigured` if no `agent_kanbans` row (frontend treats 404 NotConfigured as "empty settings", unlike agents where the row always exists).
- [ ] Implement `agentKanbansUpdateHandler` (PATCH description only, same two-switch error mapping).
- [ ] Register routes in `main.zig` directly below the agent block (~line 432): 
  ```zig
  // Agent-Kanbans mirror CRUD (Migration 081). Same ordering rules as the agent block above.
  try router.addRoute("GET", "/api/workspaces/:workspace_id/items/:item_id/agent_kanban", agentKanbansGetHandler);
  try router.addRoute("PATCH", "/api/workspaces/:workspace_id/items/:item_id/agent_kanban", agentKanbansUpdateHandler);
  ```
  ⚠️ Register BEFORE any future literal-segment routes under the same prefix.
- [ ] Add `pub const` re-exports in `http_handlers/mod.zig`; add `_ = @import("agent_kanbans_get_test.zig");` etc. in `test_runner.zig`.
- [ ] Run `zig build test --summary all` — green.
- [ ] Commit: `agent-kanbans: bundle GET + PATCH handlers`

### Task 3 — Knowledge child handlers (4 files)

**Files:** `agent_kanban_knowledge_{create,update,reorder,delete}.zig`, `mod.zig`, `test_runner.zig`, `main.zig`

Clone `agent_knowledge_{create,update,reorder,delete}.zig` with substitutions: table `agent_kanban_knowledges`, parent col `kanban_id`, parent validation = `workspace_items.item_type == 'kanban'` AND `agent_kanbans` row exists (404 `NotConfigured` otherwise).

- [ ] Failing tests first (static-contract: route order — `/knowledge/reorder` BEFORE `/knowledge/:knowledge_id`; COALESCE guards; XOR file_path/content validation in create; `isAbsolute` check when file_path non-empty).
- [ ] Implement 4 handlers. Create returns 201 + row; reorder takes `{ordered_ids: []}` and UPDATEs positions in a transaction; delete returns `{ok: true}`.
- [ ] Routes in `main.zig` (ORDER MATTERS — copy the comment style from lines 414-417):
  ```zig
  try router.addRoute("POST", "/api/agent-kanbans/:kanban_id/knowledge", agentKanbanKnowledgeCreateHandler);
  try router.addRoute("PATCH", "/api/agent-kanbans/:kanban_id/knowledge/reorder", agentKanbanKnowledgeReorderHandler); // BEFORE :knowledge_id
  try router.addRoute("PATCH", "/api/agent-kanbans/:kanban_id/knowledge/:knowledge_id", agentKanbanKnowledgeUpdateHandler);
  try router.addRoute("DELETE", "/api/agent-kanbans/:kanban_id/knowledge/:knowledge_id", agentKanbanKnowledgeDeleteHandler);
  ```
- [ ] `zig build test --summary all` green → commit: `agent-kanbans: knowledge CRUD handlers`

### Task 4 — System-prompt child handlers (4 files)

Same clone pattern from `agent_system_prompt_{create,update,reorder,delete}.zig`.

- [ ] Failing tests first (reorder-before-param shadowing guard again).
- [ ] Implement 4 handlers under `/api/agent-kanbans/:kanban_id/system_prompt`.
- [ ] Register routes with the same ORDER MATTERS comment convention.
- [ ] `zig build test --summary all` green → commit: `agent-kanbans: system_prompt CRUD handlers`

### Task 5 — Tools child handlers (3 files)

Clone `agent_tools_{list,create,delete}.zig`. Include the `isKnownTool` registry guard (linear scan of `tools_equipped.UNIFIED_TOOL_REGISTRY()`, unknown → 400).

- [ ] Failing tests first (unique `(kanban_id, tool_name)` violation → 409; unknown tool → 400).
- [ ] Implement list (enabled=1 only, `ORDER BY tool_name ASC`, return string array), create (INSERT OR detect unique violation), delete by `:tool_name`.
- [ ] Routes:
  ```zig
  try router.addRoute("GET", "/api/agent-kanbans/:kanban_id/tools", agentKanbanToolsListHandler);
  try router.addRoute("POST", "/api/agent-kanbans/:kanban_id/tools", agentKanbanToolsCreateHandler);
  try router.addRoute("DELETE", "/api/agent-kanbans/:kanban_id/tools/:tool_name", agentKanbanToolsDeleteHandler);
  ```
- [ ] `zig build test --summary all` green → commit: `agent-kanbans: tools handlers`

### Task 6 — Tool allowlist runtime wiring (`agent_kanban_tools_allowed.zig` + `workflow.zig`)

**Files:** `src/ai_workflow/tui/agentic_loop/agent_kanban_tools_allowed.zig` (new), `workflow.zig` (edit), `root.zig`/`mod.zig` re-exports

- [ ] Failing inline tests in `agent_kanban_tools_allowed.zig` (setupDb via registerAllMigrations):
  - returns empty slice when workspace_item missing / not kanban / no `agent_kanbans` row / zero enabled tools rows.
  - returns sorted names when configured.
- [ ] Implement `agentKanbanToolsAllowed(allocator, db, workspace_item_id) []const []const u8` mirroring `agent_tools_allowed.zig:35-76` but probing `agent_kanbans` instead of `agents`.
- [ ] In `workflow.zig`, add `maybeOverrideAllowedToolsForKanban` next to `maybeOverrideAllowedToolsForAgent` (~line 1899-1957): resolve session → workspace_item_id (reuse the existing hop), then `SELECT id FROM agent_kanbans WHERE id = ?`; if found AND ≥1 enabled tool row → comma-join into `out_allowed_tools`; else leave caller default untouched.
- [ ] Call site: extend the existing call site (~line 427-440) — after the agent override misses, try the kanban override (still gated on `!params.is_sub_agent`). Keep them mutually exclusive by construction (an item can't be both 'agent' and 'kanban').
- [ ] **DESIGN NOTE (flag to user in review):** D5 says "row exists but zero enabled tools" = NOT configured → defaults apply. This differs from the agent world's secure-by-default ("no tools allowed if not set"). If the user wants strict parity instead, change the condition to "row exists → override, even when empty". One-line change either way; tests pin whichever is chosen.
- [ ] `zig build test --summary all` green → commit: `agent-kanbans: tool allowlist override in workflow`

### Task 7 — Prompt injection (`prompts_make_agent_kanban_*.zig` + buildMessages)

**Files:** `prompts_make_agent_kanban_knowledge.zig` (new), `prompts_make_agent_kanban_system_prompt.zig` (new), `prompts_build_messages_for_agent_prompt.zig` (edit), `mod.zig` re-exports

- [ ] Failing inline tests first:
  - `makeAgentKanbanKnowledge returns "" for empty session_id`
  - `returns "" when item_type != 'kanban'`
  - `returns "" when no agent_kanbans row` (unconfigured kanban → no block)
  - `renders file-backed knowledge with basename header` / `skips unreadable file paths` (contract from prompts_make_agent_knowledge tests)
  - `renders inline content rows`
  - same set for `makeAgentKanbanSystemPrompt`
- [ ] Implement both builders cloning their agent counterparts, with `isKanbanItem` (checks `item_type == 'kanban'`) replacing `isAgentItem`, plus the extra `agent_kanbans` existence probe before querying children.
- [ ] Wire into `prompts_build_messages_for_agent_prompt.zig`: fetch both contents near lines 142-151, append after the agent blocks (~line 215) guarded by `if (content.len > 0)`:
  ```
  systemContent → ## Agent System Prompt → ## Agent Knowledge
                → ## Kanban System Prompt → ## Kanban Knowledge
                → inherited_md → ## Current Plan
  ```
  (Only ONE of the agent/kanban pairs can be non-empty per session since item_type is exclusive, so effective order is unchanged.)
- [ ] Re-export in `agentic_loop/mod.zig` alongside the agent prompt helpers.
- [ ] `zig build test --summary all` green → commit: `agent-kanbans: prompt injection blocks`

### Task 8 — API wrappers (frontend TS)

**File:** `src/apps/desktop/src/api/index.ts` (append after line 3940, new "Agent-Kanbans Mirror" block)

- [ ] Types: `AgentKanbanRow`, `AgentKanbanKnowledgeRow`, `AgentKanbanSystemPromptRow` (mirror the Agent* types at 3688-3835).
- [ ] Wrappers (14): `getAgentKanban(wsId, itemId)` (returns null on 404 `NotConfigured` — silent catch like `getTask`), `updateAgentKanban`, `addAgentKanbanKnowledge`, `updateAgentKanbanKnowledge`, `deleteAgentKanbanKnowledge`, `reorderAgentKanbanKnowledge`, `addAgentKanbanSystemPrompt`, `updateAgentKanbanSystemPrompt`, `deleteAgentKanbanSystemPrompt`, `reorderAgentKanbanSystemPrompts`, `getAgentKanbanTools`, `enableAgentKanbanTool`, `disableAgentKanbanTool`.
- [ ] `npm run type-check` clean → commit: `agent-kanbans: api wrappers`

### Task 9 — Frontend settings UI

**Files:** `KanbanAgentSettings.vue` (new), `KanbanView.vue` (edit), optionally `AppLayout.vue`

- [ ] `KanbanAgentSettings.vue`: modal (Teleport to body, same backdrop pattern as dialogs) hosting three sections that REUSE `AgentKnowledgeDialog.vue`, `AgentKnowledgeDetailDialog.vue`, `AgentSystemPromptDialog.vue` verbatim (they're prop-driven and generic) plus an inline tools checkbox list cloned from AgentView's tools panel (extract to a small `AgentToolsPicker.vue`? — decide during implementation; prefer extraction over copy-paste if >100 lines).
- [ ] Mount point: ⚙ "Agent config" button in `KanbanView.vue` toolbar area. On open: `getAgentKanban()` → populate; mutations optimistic + revert-on-failure (copy AppLayout handler patterns at lines 1122-1402).
- [ ] Wiring decision: keep ALL state/handlers LOCAL to KanbanView (it's self-contained today) rather than threading through AppLayout — deviates from AgentView's AppLayout-wiring but avoids bloating a 2765-line file further. Flag in review.
- [ ] Tests: component spec for open/close/load/mutations (mock global.fetch, setActivePinia — see gotchas in memory `agent-knowledge-manual-text-plan`).
- [ ] `npm run test:unit` + `npm run type-check` + `npm run build` green → commit: `agent-kanbans: settings UI on kanban view`

### Task 10 — Functional wire tests + final verification

**Files:** `tests/functional/agent_kanbans_test.py` (new)

- [ ] Functional tests replaying EXACT frontend bodies against a fresh binary (harness picks port 8080..8199, NEVER 8081):
  1. happy path: create kanban item → PATCH agent_kanban config → GET bundle shows children
  2. GET on unconfigured kanban → 404 `NotConfigured`
  3. GET on agent-type item → 400 `ItemNotKanban`
  4. POST knowledge with `file_path:""` + content → row persisted with empty file_path (empty-slice-as-NULL regression)
  5. PATCH `/knowledge/reorder` NOT captured by `:knowledge_id` (route-order regression)
  6. DELETE tool then GET tools reflects removal
- [ ] Full verification sweep:
  ```bash
  zig build test --summary all
  PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/agent_kanbans_test.py -v
  cd src/apps/desktop && npm run test:unit && npm run type-check && npm run build
  ```
- [ ] Delete any stray `.js` files emitted by vue-tsc before committing (skill: vue-tsc-build-emits-js-files).
- [ ] Final commit + push branch `worktree/agent-kanbans-mirror`, open PR.

---

## Pitfalls

- **Struct-name/version divergence:** name the struct `Migration081CreateAgentKanbans` with `version = 81` — but ALWAYS reference via a `const Migration081 = ...` alias in tests, matching house style.
- **Index SQL typo risk:** the plan's first draft had `idx_agent_kanbans_workspace_item_id ON agent_kanban_knowledges(...)` — implementer must double-check every index targets its own table.
- **`COALESCE(?, '')` everywhere on INSERT** for label/title/content/file_path/description — empty string binds as NULL otherwise.
- **Reorder routes:** register the literal `/reorder` path BEFORE the `:id` param path in BOTH knowledge and system_prompt families.
- **Don't emit SSE** from any new handler — matches the silent agent family; frontend refetches.
- **Watch `filterAndMergeTools` semantics:** research flagged a doc/code contradiction around `allowed_tools=""` (docs say zero-tools, code at workflow.zig:1653 skips filtering on empty). Task 6's override deliberately never passes `""` — it either passes a non-empty list or doesn't fire at all — sidestepping the ambiguity. Do not "fix" filterAndMergeTools in this PR.
- **Vue watch immediate:** dialogs populated from a `row` prop need `{ immediate: true }` watchers (gotcha from PR #294).

## Verification

- [ ] All tasks committed individually on branch `worktree/agent-kanbans-mirror`
- [ ] `zig build test --summary all` green with new inline + static-contract tests counted
- [ ] Functional suite `tests/functional/agent_kanbans_test.py` 6/6 passing
- [ ] Frontend unit + type-check + build green
- [ ] PR opened for human review; kanban card moved to `in_review_task`
