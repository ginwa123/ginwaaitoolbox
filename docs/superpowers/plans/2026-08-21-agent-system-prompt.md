# Agent System Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `agent_system_prompt` table (N-1 with `agents`, same relationship shape as `agent_knowledge`) plus full CRUD HTTP handlers, and a System Prompt editor section in the Agent view's main content area (right side, per the screenshot), injected into the LLM system prompt at chat time.

**Architecture:** Mirror the existing `agent_knowledge` feature end-to-end: one new migration (080) creating the table, four new HTTP handlers under the flat `/api/agents/:agent_id/system_prompt` route family, a new `makeAgentSystemPrompt` prompt-context builder injected into `buildMessages` immediately BEFORE the knowledge block, and a new presentational section + dialog in `AgentView.vue` wired through `AppLayout.vue` with optimistic updates — exactly like knowledge.

**Tech Stack:** Zig 0.16 backend (SQLite via `SqliteBackend`, custom HTTP router), Vue 3 + TypeScript + Pinia frontend, Vitest + Vue Test Utils, Python functional test harness (`tests/functional/`).

## Global Constraints

- **Migration number:** `80` is the next free slot (highest registered is 079). Struct name `Migration080AddAgentSystemPrompt`, `version: u32 = 80`, `name = "add_agent_system_prompt"`. Trust `version: u32`, not struct names (struct names and versions have diverged before).
- **ID convention:** every `id` column is `TEXT PRIMARY KEY`, generated in Zig as a timestamp string — never `INTEGER AUTOINCREMENT` (project convention).
- **Empty-slice-binds-as-NULL:** `SqliteBackend.exec` binds `""` as SQL NULL. All text columns are `NOT NULL DEFAULT ''` in DDL, and all INSERT/UPDATE binds use `COALESCE(?, '')` in SQL.
- **Arena allocator:** HTTP handlers get a per-request arena via `ctx.allocator` — NEVER `defer allocator.free(...)` on arena-backed allocations in handlers. (Test code using `testing.allocator` DOES free.)
- **Route order:** literal path segments MUST be registered before `:param` captures on the same prefix (router walks registration order). No literal-vs-param conflict exists in the planned routes, but keep new registrations grouped right after line 411 of `src/main.zig`.
- **No SSE events** for this domain — knowledge CRUD handlers emit none; system prompt handlers stay silent too (frontend re-fetches / optimistic-updates).
- **Never kill port 8081.** Functional tests use the harness (free port 8080–8199, isolated tmpdir HOME). Never `nohup` a live server + curl for verification.
- **Tests use the migrations module** (`registerAllMigrations` + `runMigrations`) or explicit `MigrationXXX.up()` calls — never hand-rolled CREATE TABLE fixtures.
- **Frontend dark theme:** semantic CSS vars only (`--semantic-text`, `--semantic-sidebar-bg`, `--color-border`, `--color-violet`, …) — no raw hex.
- **Language:** UI copy in English; code comments in English.

## Design Decisions

- **D1 — Table shape (N-1, like agent_knowledge):** multiple named prompt blocks per agent, ordered by `position`. This matches the user's "relationship same like agent_knowledge" instruction and the screenshot's list+add UI pattern.

```sql
CREATE TABLE IF NOT EXISTS agent_system_prompt (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL DEFAULT '',
    position INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_agent_system_prompt_agent_id ON agent_system_prompt(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_system_prompt_agent_id_position ON agent_system_prompt(agent_id, position DESC);
```

- **D2 — Injection position:** the agent's system prompt block is appended into the final system message immediately BEFORE the `## Agent Knowledge` block (persona instructions precede reference data). Header inside the prompt: `## Agent System Prompt`.
- **D3 — agent_id == workspace_item_id** (existing spec D3 from Agent Mode): the resolution chain is `session_id → workspace_item_tasks.workspace_item_id → workspace_items.item_type == 'agent'`.
- **D4 — GET bundle:** extend the existing `GET /api/workspaces/:ws/items/:item_id/agent` response with a `system_prompts` array (sorted `position DESC`) so the view loads in one round-trip, same as knowledge/tools today.
- **D5 — UI:** a "System Prompt" section in the Agent view's RIGHT (main content) column, between the heading/+ New Chat row and the description text. List of prompt rows (title + preview, ✎ edit, ✕ delete) + `+ Add` button opening a dialog with Title + Content textarea. Mirrors knowledge row/dialog patterns.

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `src/migrations/migration.zig` | EDIT | Migration080 struct + registration + inline tests |
| `src/ai_workflow/tui/http_handlers/agent_system_prompt_create.zig` | NEW | POST `/api/agents/:agent_id/system_prompt` |
| `src/ai_workflow/tui/http_handlers/agent_system_prompt_update.zig` | NEW | PATCH `/api/agents/:agent_id/system_prompt/:prompt_id` |
| `src/ai_workflow/tui/http_handlers/agent_system_prompt_delete.zig` | NEW | DELETE `/api/agents/:agent_id/system_prompt/:prompt_id` |
| `src/ai_workflow/tui/http_handlers/agent_system_prompt_reorder.zig` | NEW | PATCH `/api/agents/:agent_id/system_prompt/reorder` |
| `src/ai_workflow/tui/http_handlers/agents_get.zig` | EDIT | include `system_prompts` array in GET bundle |
| `src/ai_workflow/tui/http_handlers/mod.zig` | EDIT | re-export 4 new handlers |
| `src/main.zig` | EDIT | register 4 routes after line 411 |
| `src/ai_workflow/tui/agentic_loop/prompts_make_agent_system_prompt.zig` | NEW | `makeAgentSystemPrompt(allocator, io, db, session_id) ![]const u8` + inline tests |
| `src/ai_workflow/tui/agentic_loop/prompts.zig` | EDIT | re-export `makeAgentSystemPrompt` |
| `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig` | EDIT | call + append before knowledge block |
| `src/apps/desktop/src/api/index.ts` | EDIT | `AgentSystemPromptRow` interface + 5 wrappers |
| `src/apps/desktop/src/components/views/AgentView.vue` | EDIT | System Prompt section in right column |
| `src/apps/desktop/src/components/dialogs/AgentSystemPromptDialog.vue` | NEW | add/edit dialog (title + content textarea) |
| `src/apps/desktop/src/components/AppLayout.vue` | EDIT | state refs, load, 3-4 handlers, dialog mount |
| `tests/functional/agent_system_prompt_test.py` | NEW | wire-level functional tests |

---

## Task 1 — Migration 080: create `agent_system_prompt` table

**Files:** `src/migrations/migration.zig` (edit)

- [ ] 1.1 Write failing inline tests at the bottom of `migration.zig` (alongside the existing Migration078/079 inline tests, reusing the existing `setupDb`/`columnsOf`/`expectColumnsEqual` helpers):
  - `test "Migration080 creates agent_system_prompt table with correct columns"` — expect ordered columns: `id, agent_id, title, content, position, created_at, updated_at`
  - `test "Migration080 is idempotent on a re-run"`
  - `test "Migration080 is registered in allMigrations"`
  - `test "Migration080 ON DELETE CASCADE removes prompts when agent is deleted"` (enable `PRAGMA foreign_keys = ON` in the test)
- [ ] 1.2 Run `zig build test --summary all` — confirm the 4 new tests FAIL (table doesn't exist yet).
- [ ] 1.3 Implement `pub const Migration080AddAgentSystemPrompt = struct { pub const version: u32 = 80; pub const name = "add_agent_system_prompt"; pub fn up(...) ... }` with the DDL from Design Decision D1 (two `db.exec` calls — one per statement; `sqlite3_prepare_v2` only compiles the first statement). Doc comment cites this plan + task id.
- [ ] 1.4 Register in `allMigrations` (end of the slice, before closing `};`): `.{ .version = Migration080AddAgentSystemPrompt.version, .name = Migration080AddAgentSystemPrompt.name, .up = Migration080AddAgentSystemPrompt.up },`
- [ ] 1.5 Run `zig build test --summary all` — all 4 new tests PASS, zero regressions (baseline ~2560 pass / 6 skip).
- [ ] 1.6 Commit: `git commit -m "Migration 080: agent_system_prompt table (N-1 with agents)"`

## Task 2 — CRUD HTTP handlers (4 files) + route registration

**Files:** 4 NEW under `src/ai_workflow/tui/http_handlers/`, plus `mod.zig` + `src/main.zig` (edit)

Model each handler 1:1 on its `agent_knowledge_*` sibling (same error-set + two exhaustive switch blocks + `COALESCE(?, '')` binds + ownership check `SELECT 1 FROM workspace_items WHERE id=? AND item_type='agent'`).

- [ ] 2.1 Write `agent_system_prompt_create.zig`: POST, body `{title, content}` (both default `""`), validate `content` non-empty after trim (error `ContentRequired`), `agent_id` non-empty (`AgentIdRequired`), ownership check, INSERT with `id` generated via timestamp string, `position = COALESCE(MAX(position), -1) + 1`, refetch and return the row (201).
- [ ] 2.2 Write `agent_system_prompt_update.zig`: PATCH, body `{title?, content?}` (both optional), dynamic SET clause via `std.ArrayList.appendSlice` (Zig 0.16 pattern from `agent_knowledge_update.zig`), `WHERE id=? AND agent_id=?`, refetch and return the row (200), 404 if no row.
- [ ] 2.3 Write `agent_system_prompt_delete.zig`: DELETE, `WHERE id=? AND agent_id=?`, return `{ok: true}` (no SELECT-before-DELETE; no-op on missing row).
- [ ] 2.4 Write `agent_system_prompt_reorder.zig`: PATCH, body `{ordered_ids: []const []const u8}`, BEGIN/COMMIT transaction, `UPDATE ... SET position = ? WHERE id = ? AND agent_id = ?` per id (use `len - 1 - i` like knowledge reorder so first id lands at highest position), return `{ok: true}`.
- [ ] 2.5 Re-export all 4 handlers in `src/ai_workflow/tui/http_handlers/mod.zig` (follow the existing `agent_knowledge_*` re-export lines 54-65 pattern).
- [ ] 2.6 Register routes in `src/main.zig` immediately after line 411 (after the knowledge reorder registration):
  ```zig
  try gs.router.post(  "/api/agents/:agent_id/system_prompt",                     ai_mod.http_handlers.agentSystemPromptCreateHandler);
  try gs.router.patch( "/api/agents/:agent_id/system_prompt/reorder",             ai_mod.http_handlers.agentSystemPromptReorderHandler);   // literal BEFORE :prompt_id
  try gs.router.patch( "/api/agents/:agent_id/system_prompt/:prompt_id",          ai_mod.http_handlers.agentSystemPromptUpdateHandler);
  try gs.router.delete("/api/agents/:agent_id/system_prompt/:prompt_id",          ai_mod.http_handlers.agentSystemPromptDeleteHandler);
  ```
  ⚠️ `reorder` MUST be registered BEFORE `:prompt_id` (route-order shadowing — same trap as knowledge reorder at line 411 vs 409).
- [ ] 2.7 `zig build` compiles clean.
- [ ] 2.8 Write `tests/functional/agent_system_prompt_test.py` using `tests/functional/harness.py` (isolated tmpdir HOME, free port 8080–8199, NEVER 8081). Replay the exact JSON bodies the frontend will send:
  - create → 201, row echoed with `id`, `position`
  - create with empty content → 400
  - create against unknown agent_id → 404
  - update title+content → 200, fields changed
  - update with `content: ""` → 200 (empty string is a legal value here, NOT NULL — asserts the COALESCE mitigation; this is the empty-slice-binds-as-NULL regression)
  - delete → `{ok: true}`, GET bundle no longer lists it
  - reorder `[b, a]` → GET bundle returns positions reflecting the new order
  - GET bundle includes `system_prompts: []` for a fresh agent
- [ ] 2.9 Run `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/agent_system_prompt_test.py -v` — all PASS.
- [ ] 2.10 Commit: `git commit -m "agent_system_prompt CRUD handlers + routes + functional tests"`

## Task 3 — Prompt injection: `makeAgentSystemPrompt`

**Files:** 1 NEW + 2 EDIT under `src/ai_workflow/tui/agentic_loop/`

- [ ] 3.1 Write failing inline tests in NEW file `prompts_make_agent_system_prompt.zig` (mirror `prompts_make_agent_knowledge.zig:194-453` test block; `setupDb` runs `Migration076.up` + `Migration080.up`):
  - returns `""` when session_id empty
  - returns `""` when session not found
  - returns `""` when workspace_item is not an agent
  - returns `""` when agent has no system prompt rows
  - returns block containing `## Agent System Prompt` + all row contents when rows exist
  - multiple rows render in `position DESC` order with titles
- [ ] 3.2 Run `zig build test --summary all` — new tests FAIL (function unimplemented).
- [ ] 3.3 Implement `pub fn makeAgentSystemPrompt(allocator, io, db, session_id) ![]const u8`:
  - Resolution chain copied from `prompts_make_agent_knowledge.zig:29-92`: `resolveWorkspaceItemId` (session → `workspace_item_tasks.workspace_item_id`) → `isAgentItem` (`workspace_items.item_type == 'agent'`).
  - Query: `SELECT title, content FROM agent_system_prompt WHERE agent_id = ? ORDER BY position DESC`
  - Emit `## Agent System Prompt` header + each row as `### {title}\n{content}\n` (skip rows whose content trims to empty).
  - Return `""` (not an error) in every "nothing to inject" case.
- [ ] 3.4 Re-export in `src/ai_workflow/tui/agentic_loop/prompts.zig`: `pub const makeAgentSystemPrompt = @import("prompts_make_agent_system_prompt.zig").makeAgentSystemPrompt;`
- [ ] 3.5 Wire into `prompts_build_messages_for_agent_prompt.zig`: fetch after the `makeAgentKnowledge` call (~line 134), and in the final_system assembly append it BEFORE the knowledge block (~line 190):
  ```zig
  if (agentSystemPromptContent.len > 0) {
      try final_system.appendSlice(allocator, agentSystemPromptContent);
  }
  if (agentKnowledgeContent.len > 0) { ... }   // existing line 191
  ```
- [ ] 3.6 Run `zig build test --summary all` — all PASS (new tests + existing `prompts_build_messages_for_agent_prompt` tests if any).
- [ ] 3.7 Commit: `git commit -m "inject agent_system_prompt into system prompt before knowledge block"`

## Task 4 — Frontend: API wrappers + AgentView section + dialog + AppLayout wiring

**Files:** `api/index.ts` + `AgentView.vue` (edit), `AgentSystemPromptDialog.vue` (new), `AppLayout.vue` (edit)

- [ ] 4.1 `api/index.ts` — add interface + wrappers (mirror knowledge block at lines 3690-3735):
  ```ts
  export interface AgentSystemPromptRow { id: string; agent_id: string; title: string; content: string; position: number; created_at: string; updated_at: string }
  addAgentSystemPrompt(agentId, title, content)                    → POST   /api/agents/{agentId}/system_prompt
  updateAgentSystemPrompt(agentId, promptId, {title?, content?})   → PATCH  /api/agents/{agentId}/system_prompt/{promptId}
  deleteAgentSystemPrompt(agentId, promptId)                       → DELETE /api/agents/{agentId}/system_prompt/{promptId}
  reorderAgentSystemPrompts(agentId, orderedIds: string[])         → PATCH  /api/agents/{agentId}/system_prompt/reorder
  ```
  Extend the `getAgent` response type with `system_prompts: AgentSystemPromptRow[]`.
- [ ] 4.2 Write failing component tests `src/__tests__/AgentSystemPromptDialog.spec.ts` (mount + assert title input, content textarea, canSubmit gating, create/save emits) and extend `AgentView.spec.ts` (section renders rows from `systemPrompts` prop; `+ Add` emits `addSystemPrompt`; ✎ emits `editSystemPrompt`; ✕ emits `removeSystemPrompt`). Run `npx vitest run src/__tests__/AgentSystemPromptDialog.spec.ts` — FAIL (component missing).
- [ ] 4.3 Create `components/dialogs/AgentSystemPromptDialog.vue`: copy the shell of `AgentKnowledgeDialog.vue` (Teleport-to-body + Transition + backdrop + panel, `props: {show, busy?, error?}`, emits `close` + `create`/`save`). Form: Title text input + Content `<textarea rows="10" class="w-full px-3 py-2 rounded-lg text-sm outline-none resize-y" style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);">`. Validation: content non-empty after trim gates `canSubmit`. Used for BOTH add and edit (pass optional `prompt` prop; when set, button says Save and emits `save(promptId, {title, content})`).
- [ ] 4.4 `AgentView.vue` — add the System Prompt section in the RIGHT column between the heading/+ New Chat row (~line 554) and the description text (~line 555):
  - New prop `systemPrompts: api.AgentSystemPromptRow[]`; new emits `addSystemPrompt`, `editSystemPrompt(row)`, `removeSystemPrompt(promptId)`.
  - Section: heading `System Prompt` + count chip + `+ Add` button (violet CTA styling per conventions).
  - Rows: `data-testid="agent-system-prompt-item"`, title (or "Untitled prompt"), 60-char content preview, ✎ / ✕ buttons, expandable `<pre>` preview like knowledge rows.
  - Update the hardcoded description text to also mention the system prompt ("The system prompt is injected before knowledge at chat time.").
- [ ] 4.5 `AppLayout.vue` — mirror the knowledge wiring:
  - `const agentSystemPrompts = ref<api.AgentSystemPromptRow[]>([])`; reset in the same places `agentKnowledge` resets.
  - `loadAgentData()` — read `system_prompts` from the `getAgent` response into the ref.
  - Handlers `handleAgentSystemPromptCreate` (optimistic append), `handleAgentSystemPromptSave` (optimistic replace-in-place), `handleAgentRemoveSystemPrompt` (optimistic filter + restore on failure) — copy the knowledge handler bodies (lines ~1115-1205) swapping the API calls.
  - Mount `AgentSystemPromptDialog` next to the knowledge dialogs (~lines 2420-2442) with the same `:show/:busy/:error` + `@create/@save/@close` pattern.
  - Pass `:system-prompts="agentSystemPrompts"` to `AgentView` and wire the 3 new events.
- [ ] 4.6 Run the full frontend suite: `cd src/apps/desktop && npx vitest run` — all PASS; `npm run type-check` (or `vue-tsc`) clean; `npm run build` succeeds.
- [ ] 4.7 Commit: `git commit -m "Agent view: System Prompt section + add/edit dialog + AppLayout wiring"`

## Task 5 — End-to-end verification + docs

- [ ] 5.1 Full backend suite: `zig build test --summary all` — 0 fail, 0 leaks.
- [ ] 5.2 Full functional suite: `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/ -v` — no regressions (new file passes, existing files untouched).
- [ ] 5.3 Frontend: `npx vitest run` + type-check + build — all green.
- [ ] 5.4 Manual smoke (optional, only if the user wants it): run the desktop app, open an Agent, add a system prompt, start a New Chat, ask the model to echo its persona — confirm the prompt content appears. (Do NOT touch port 8081.)
- [ ] 5.5 Update this plan's checkboxes; final commit if any fixups; push branch + open PR for human review.

## Notes / Gotchas (from research)

- **Struct-name vs version divergence:** `Migration076AddAgents...` actually has `version: u32 = 78`. Always pick the next number from the highest `version: u32` in `migration.zig` (currently 079 → new is 080).
- **One statement per `db.exec`** — `sqlite3_prepare_v2` compiles only the first statement; split the CREATE TABLE and the two CREATE INDEX calls.
- **`COALESCE(?, '')` on every text bind** in INSERT/UPDATE — empty JS/Zig strings bind as SQL NULL otherwise (regression covered in functional test 2.8).
- **Route shadowing:** `/system_prompt/reorder` before `/system_prompt/:prompt_id`.
- **No SSE** — consistent with knowledge handlers; frontend uses optimistic updates + GET bundle.
- **`agents.id == workspace_item_id`** (spec D3) — the prompt builder keys the SELECT on the workspace_item_id string.
- **Vitest + Teleport:** dialog tests need `attachTo: document.body` + `document.querySelector` assertions (see `.nalar/skills/vue-teleport-vitest-document-queryselector`).
- **Fresh worktree:** `bun install --frozen-lockfile` in `src/apps/desktop` before vitest.
