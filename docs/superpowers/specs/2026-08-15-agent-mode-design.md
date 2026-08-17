# Agent Mode — Design Spec

**Date:** 2026-08-15
**Branch:** `worktree/agent-mode`
**Task:** `task_1786962724740_0` ("new feature AgentMode")
**Author:** brainstorming session with user (decided iteratively: agent = chatbot + markdown knowledge files)

## TL;DR

Add a fourth workspace-item type — `agent` — sitting alongside `folder`/`kanban`/`design`. Each Agent item is a persistent chatbot configuration: it has its own `path` (cwd for its chats, like Kanban/Design) and a list of **markdown knowledge files on disk**. When a chat session is opened under an Agent, the backend reads every knowledge file's contents and injects them into the system prompt as a new `## Agent Knowledge` section. Two new tables (`agents` 1-1 with `workspace_items`, `agent_knowledge` N-1 with `agents`) — no change to existing `agent_memories` (which stays a global tool-driven note store, separate concept).

## User intent (captured during brainstorming)

> "new feature AgentMode ... add a menu name Agent ... just like standard chatbot, but we can add knowledge ... new table name agent ... relation: workspaces → workspace_item_id 1-to-1 with new table agent → many workspace_item_tasks ... memory is like markdown but we need add the table ... `agent_knowledge` is different from `agent_memories` (memories is a tool) ... `agent_knowledge` is read markdown file path ... absolute paths."

Decisions locked in before drafting:
- **Knowledge = absolute file paths to markdown** (no embeddings, no upload UI, no DB-stored content)
- **Agent has a `path` (cwd)** — parity with Kanban/Design
- **`agent_knowledge` is a new table**, distinct from `agent_memories`
- **Sidebar UX:** new "Add Agent" item in the existing `+ Add Item` dropdown

## Goal

After this feature ships:
1. A user can click `+ Add Item → Add Agent`, enter a name + folder path, and a new Agent appears in the sidebar tree.
2. Clicking the Agent opens a new `AgentView` with: a Knowledge panel (list of markdown paths with add/remove/edit), and a list of chat sessions under the Agent (existing `workspace_item_tasks` rows scoped to this Agent's item_id).
3. Adding a knowledge entry = pick an absolute markdown file path on disk (text input + optional Browse dialog). The label is optional.
4. Opening/starting a chat under the Agent auto-injects the contents of every knowledge file into the system prompt as `## Agent Knowledge`. The injection is capped at **64 KiB total** to protect the context window; if the cap is exceeded, the section is truncated and a warning is logged.
5. If a knowledge file path is missing or unreadable at session start, it's logged and skipped — the chat still works with whatever files were readable.
6. Editing the markdown file on disk (in any external editor) reflects on the next chat start — the backend re-reads files every session, never caches.

## Why a dedicated `agents` table (and not just columns on `workspace_items`)

The user's diagram specifies a 1-1 table (`workspaces` → `workspace_items` → `agents`). Keeping it separate:
- Future agent-specific fields (system-prompt override, default model, allowed-tools allowlist, embedding-config toggle) become additive columns on `agents`, NOT new columns on `workspace_items` (which would affect kanban / design / folder rows too).
- Enforces the 1-1 invariant via `UNIQUE(workspace_item_id)` at the schema level, not just at the application layer.
- Mirrors the `kanban_columns`/`design_pages` pattern of "type-specific data lives in a sibling table keyed by item_id".

## Why a new `agent_knowledge` table (and not storing content in the `agents` row)

- One Agent has N knowledge files. A TEXT column can't model N rows.
- The backend re-reads file contents from disk every chat — no content is ever duplicated into SQLite. Storage stays small (just paths).
- A separate table also enables per-entry metadata (label, position, created_at) and future per-entry behaviour (e.g. a per-file "always include" toggle) without a migration.

## Architecture

### Data model

#### `agents` (NEW — Migration 076)

```sql
CREATE TABLE IF NOT EXISTS agents (
    id TEXT PRIMARY KEY,
    workspace_item_id TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_agents_workspace_item_id ON agents(workspace_item_id);
```

Notes:
- `id` is the same value as `workspace_item_id` — there's no separate primary key. The agent's identity IS its workspace_item_id (Kanban already does this with `kanban_columns.id` mirroring `workspace_items.id`). This simplifies the "1-1" semantic and avoids a redundant lookup.
- Wait — the `agents` table needs its own id-style so HTTP routes like `/api/agents/:agentId/knowledge` have a clean id. Decision: **`id` == `workspace_item_id`** (so the URL becomes `/api/agents/<item_id>/knowledge`). Same string flows through both tables.
- `UNIQUE(workspace_item_id)` enforces 1-1 at the DB layer — INSERT-then-UPDATE pattern fails loudly if someone tries to create a second agent for the same item.
- `ON DELETE CASCADE` — deleting the workspace_item drops the agent row + (via cascade below) the knowledge rows.
- `description` is optional. Empty slice is the canonical "no description" sentinel.

#### `agent_knowledge` (NEW — Migration 076)

```sql
CREATE TABLE IF NOT EXISTS agent_knowledge (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    label TEXT NOT NULL DEFAULT '',
    position INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_agent_knowledge_agent_id ON agent_knowledge(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_knowledge_agent_id_position ON agent_knowledge(agent_id, position DESC);
```

Notes:
- `file_path` is REQUIRED and ABSOLUTE. The backend validates `std.fs.path.isAbsolute` on insert; non-absolute paths return 400.
- `label` is optional — when empty, the UI shows `basename(file_path)` (or just the full path).
- `position` mirrors Kanban's drag-reorder pattern: higher = higher in the list. Drag-reorder endpoint reassigns these.
- `ON DELETE CASCADE` ensures deleting the parent agent (via deleting its workspace_item) drops its knowledge rows in the same transaction.

### Wire format / API surface

| Method | Route | Purpose | Body | Response |
|---|---|---|---|---|
| POST | `/api/workspaces/:wsId/items/agent` | Create new Agent | `{name, path}` | `201 {item: {...}, agent: {id, workspace_item_id, description, ...}}` |
| GET | `/api/workspaces/:wsId/items/:itemId/agent` | Fetch Agent + knowledge list | — | `200 {agent, knowledge: AgentKnowledgeRow[]}` |
| PATCH | `/api/workspaces/:wsId/items/:itemId/agent` | Update description | `{description}` | `200 {agent}` |
| GET | `/api/agents/:agentId/knowledge` | List knowledge rows | — | `200 AgentKnowledgeRow[]` |
| POST | `/api/agents/:agentId/knowledge` | Add a knowledge entry | `{file_path, label?, position?}` | `201 AgentKnowledgeRow` |
| PATCH | `/api/agents/:agentId/knowledge/:knowledgeId` | Edit path or label | `{file_path?, label?, position?}` | `200 AgentKnowledgeRow` |
| DELETE | `/api/agents/:agentId/knowledge/:knowledgeId` | Remove entry | — | `200 {ok: true}` |
| PATCH | `/api/agents/:agentId/knowledge/reorder` | Drag-reorder | `{ordered_ids: string[]}` | `200 {ok: true}` |

`AgentKnowledgeRow`:
```zig
{
    id: []const u8,
    agent_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
}
```

### Frontend surface

| File | Change |
|---|---|
| `src/apps/desktop/src/components/workspace/WorkspaceList.vue` | Add a 4th `<li>` in the `+ Add Item` dropdown: `<button @click="handleAddItem(workspace.id, 'agent')">Add Agent</button>` |
| `src/apps/desktop/src/components/shell/Sidebar.vue` | `handleAddItem` adds `if (itemType === 'agent') showAddAgentDialog.value = true`. New `handleCreateAgent` mirrors `handleCreateKanban`. |
| `src/apps/desktop/src/components/dialogs/AddAgentDialog.vue` (NEW) | Mirrors `AddKanbanDialog.vue` (name + folder picker via `FilePickerDialog`). |
| `src/apps/desktop/src/views/AgentView.vue` (NEW) | Mounted by AppLayout when `activeWorkspaceItem.item_type === 'agent'`. Layout: left column = Knowledge panel (list of entries with add/remove/reorder); right column = recent chat sessions (`workspace_item_tasks` filtered by `workspace_item_id`) with a "New Chat" button. |
| `src/apps/desktop/src/components/dialogs/AgentKnowledgeDialog.vue` (NEW) | Modal for adding a single knowledge entry. Path input + optional "Browse" (opens `FilePickerDialog` in `mode='file'` + `.md` filter). |
| `src/apps/desktop/src/components/dialogs/AgentChatDialog.vue` (NEW) | Mirrors `KanbanChatDialog.vue` — modal chat overlay when a chat task under an Agent is selected. |
| `src/apps/desktop/src/components/AppLayout.vue` | New `v-else-if` branch renders `<AgentView>` for `item_type === 'agent'`. Mount `<AgentChatDialog>` for the chat overlay (same gating pattern as `KanbanChatDialog` / `DesignChatDialog`). |
| `src/apps/desktop/src/stores/workspaces.ts` | New actions `addAgentItem`, `fetchAgent`, `addKnowledgeEntry`, `removeKnowledgeEntry`, `updateKnowledgeEntry`, `reorderKnowledgeEntries`. |
| `src/apps/desktop/src/api/index.ts` | New typed wrappers `api.createAgent`, `api.getAgent`, `api.updateAgent`, `api.listAgentKnowledge`, `api.createAgentKnowledge`, `api.updateAgentKnowledge`, `api.deleteAgentKnowledge`, `api.reorderAgentKnowledge`. |

### System prompt injection

A new prompt section file: `src/ai_workflow/tui/agentic_loop/prompts_make_agent_knowledge.zig`.

`pub fn makeAgentKnowledge(allocator, db, session_id) ![]const u8`

1. Resolve `session_id` → `workspace_item_id` (via existing `workspace_item_tasks` lookup).
2. SELECT item_type from `workspace_items WHERE id = ?`. If not `'agent'`, return `""` (no-op).
3. SELECT all rows from `agent_knowledge WHERE agent_id = ? ORDER BY position DESC`.
4. For each row:
   - `std.fs.openFile(absolute_path, .{})` — on failure, `std.log.warn` and skip.
   - Read up to `MAX_FILE_BYTES` (16 KiB per file). Truncate at that point.
   - Wrap in `\n### <label-or-basename>\n<file: absolute_path>\n\n<content>\n`.
5. Prepend `\n\n## Agent Knowledge\n\n` and the user-facing disclaimer `"The following markdown files are part of this Agent's knowledge. Treat them as authoritative reference for any user question that touches their topics; do not invent details that contradict them."\n\n`.
6. If accumulated bytes > `MAX_TOTAL_BYTES` (64 KiB), truncate the section and append `"\n\n[truncated — additional knowledge files were not included to stay within context budget]\n"`. Log a warning naming the dropped files.
7. If `agent_knowledge` is empty, return `""`.

Wired into the existing prompt-assembly pipeline alongside `prompts_make_workspace_context.zig`:
```zig
const workspace_ctx = try makeWorkspaceContext(alloc, db, session_id);
const agent_knowledge = try makeAgentKnowledge(alloc, db, session_id);
defer { alloc.free(workspace_ctx); alloc.free(agent_knowledge); }
return try std.fmt.allocPrint(alloc, "{s}{s}", .{ workspace_ctx, agent_knowledge });
```

### Migration safety

- Both tables use `CREATE TABLE IF NOT EXISTS` — re-running the migration on a DB that already has them is a no-op.
- `idx_*` indexes use `CREATE INDEX IF NOT EXISTS`.
- `UNIQUE(workspace_item_id)` on `agents` is part of the CREATE TABLE statement — a partial re-run where the table exists without the constraint would NOT add the constraint. To handle this, probe `pragma_index_list` + `pragma_table_info` before CREATE; if either check fails, log and continue (mirrors the pattern in `Migration072ExtractKanbanTable`).
- No data migration — `agents` and `agent_knowledge` start empty. Pre-existing workspaces have no Agents.

## Files touched

| File | Change |
|---|---|
| `src/migrations/migration.zig` | Add `Migration076AddAgentsAndAgentKnowledge`. Register in `allMigrations`. |
| `src/migrations/migration_076_test.zig` (NEW) | 6 tests: both tables exist, both have correct columns, `agents.workspace_item_id` is UNIQUE, FK CASCADE works, `agent_knowledge.position` index exists, idempotency on re-run. |
| `src/migrations/test_runner.zig` | Register the new test file. |
| `src/models/agent.zig` (NEW) | `Agent` row struct mirroring the `workspace_item` row + `description`. `init/deinit/clone`. |
| `src/models/agent_knowledge.zig` (NEW) | `AgentKnowledge` row struct. `init/deinit/clone`. |
| `src/ai_workflow/tui/http_handlers/workspace_items_create_agent.zig` (NEW) | Mirrors `workspace_items_create_kanban.zig`. POST handler that creates the workspace_item + agents row in one transaction (no extra seed data — the agent starts with empty knowledge list). |
| `src/ai_workflow/tui/http_handlers/agents_get.zig` (NEW) | GET handler for `/api/workspaces/:wsId/items/:itemId/agent` returning `{agent, knowledge}`. |
| `src/ai_workflow/tui/http_handlers/agents_update.zig` (NEW) | PATCH handler for description. |
| `src/ai_workflow/tui/http_handlers/agent_knowledge_*.zig` (NEW, 5 files) | GET / POST / PATCH / DELETE / PATCH-reorder handlers. |
| `src/ai_workflow/tui/http_handlers/router.zig` (or equivalent) | Register the 8 new routes. |
| `src/ai_workflow/tui/agentic_loop/prompts_make_agent_knowledge.zig` (NEW) | The new prompt section. |
| `src/ai_workflow/tui/agentic_loop/prompts_assemble.zig` (or wherever the workspace-context prompt is currently assembled) | Wire `makeAgentKnowledge` into the pipeline. |
| `src/apps/desktop/src/api/index.ts` | 9 new typed wrappers. |
| `src/apps/desktop/src/stores/workspaces.ts` | 6 new actions. |
| `src/apps/desktop/src/components/workspace/WorkspaceList.vue` | New "Add Agent" `<li>` in the dropdown. |
| `src/apps/desktop/src/components/shell/Sidebar.vue` | New `handleAddItem` branch + `handleCreateAgent` handler. |
| `src/apps/desktop/src/components/dialogs/AddAgentDialog.vue` (NEW) | Add-agent dialog. |
| `src/apps/desktop/src/components/dialogs/AgentKnowledgeDialog.vue` (NEW) | Add-knowledge dialog. |
| `src/apps/desktop/src/views/AgentView.vue` (NEW) | Main view. |
| `src/apps/desktop/src/components/dialogs/AgentChatDialog.vue` (NEW) | Chat overlay. |
| `src/apps/desktop/src/components/AppLayout.vue` | New `v-else-if` mount + dialog mount. |
| `src/apps/desktop/src/__tests__/AddAgentDialog.spec.ts` (NEW) | 3 tests mirroring `AddKanbanDialog.spec.ts`. |
| `src/apps/desktop/src/__tests__/AgentKnowledgeDialog.spec.ts` (NEW) | 4 tests: required path, optional label, Browse opens picker, validation errors. |
| `src/apps/desktop/src/__tests__/AgentView.spec.ts` (NEW) | 6 tests: renders knowledge list, add button opens dialog, remove button calls store, drag-reorder calls store, New Chat button opens dialog, empty state shows when no knowledge/chats. |

## Files NOT touched (explicitly out of scope)

- `src/apps/desktop/src/components/workspace/WorkspaceList.vue` chat/task interaction handlers — Agent items reuse the same `handleAddTask` / `handleSelectTask` pattern as Kanban; no special-casing needed.
- `src/models/agent_memory.zig` and `src/migrations/migration.zig` Migration 070 (`add_agent_memories`) — completely separate feature. The user explicitly distinguished `agent_knowledge` (markdown paths) from `agent_memories` (tool-driven notes).
- The system-prompt assembly for non-Agent item types — `prompts_make_agent_knowledge` is a no-op for those (returns `""`).
- The Kanban / Design views, their SSE channels, their CRUD endpoints.
- The `workspace_items.item_type` column has no CHECK constraint today — we don't add one (mirrors existing convention: "the column accepts any string the caller wrote").
- Frontend route table (`src/apps/desktop/src/router/index.ts`) — AppLayout's `v-else-if` chain handles routing for Agent items; no new top-level route needed.

## Behavioural matrix

| Action | Before | After |
|---|---|---|
| Click `+ Add Item → Add Agent` | No option in dropdown | Opens `AddAgentDialog` |
| Fill name + folder, click Add | n/a | New Agent appears in sidebar (auto-selected → `AgentView` mounts) |
| Click `+ Add Knowledge` in AgentView | n/a | Opens `AgentKnowledgeDialog` |
| Pick `.md` file via Browse, click Add | n/a | Entry appears in Knowledge panel (label optional) |
| Open / start a chat under the Agent | n/a | System prompt gets new `## Agent Knowledge` section with file contents |
| Edit a knowledge `.md` file externally, start a new chat | n/a | Next chat reflects the new contents (backend re-reads every session) |
| Knowledge path is missing / unreadable | n/a | Logged + skipped; chat continues with remaining files |
| Knowledge section > 64 KiB | n/a | Truncated with explicit `[truncated]` marker + dropped-file warning |
| Click remove on a knowledge entry | n/a | Entry deleted from DB + panel re-renders |
| Drag-reorder entries | n/a | Positions updated via PATCH /reorder |

## Global Constraints

- **Backward compatible.** Existing `workspace_items` rows (folder/kanban/design) are untouched. The new `agents` / `agent_knowledge` tables start empty. No new system-prompt content is added for non-Agent items.
- **No wire-shape change to existing endpoints.** All 8 new endpoints are additive. The `workspace_items.item_type` column continues to accept any string — `'agent'` is just one more valid value.
- **No new global error variants.** HTTP handlers reuse existing `400` / `500` mapping. The frontend surfaces validation errors via existing error-rendering patterns.
- **Idempotent migration.** Migration 076 is safe to re-run.
- **Pure-Zig backend, Vue/TS frontend.** All three platforms (Linux/macOS/Windows) compile + test green.
- **YAGNI.** No system-prompt-override column, no model-preference column, no per-chat knowledge override, no embed/RAG columns. All deferred — the `agents` table is the additive home for any of these as future migrations.
- **TDD.** Every backend change has a failing test written before the implementation patch. Every new frontend component has a `*.spec.ts` test that mounts the dialog and asserts the expected wiring.

## Verification

Before claiming done:
1. `zig build test --summary all` — all green, including the 6 new migration tests + handler tests + prompt-injection tests.
2. New backend tests cover:
   - Migration 076: tables exist, idempotency, UNIQUE constraint on `agents.workspace_item_id`, CASCADE delete from `workspace_items → agents → agent_knowledge`.
   - `workspace_items_create_agent`: returns 201 with `{item, agent}`, both rows exist in DB.
   - `agents_get`: returns agent + knowledge list, ordered by position DESC.
   - `agents_update`: updates description, 404 if item not found, 400 if not an agent.
   - `agent_knowledge_create`: validates absolute path (rejects relative), validates file exists (warning only, doesn't 400), assigns position.
   - `agent_knowledge_update`, `_delete`, `_reorder`: standard CRUD.
   - `prompts_make_agent_knowledge`: empty for non-agent items; reads 1 file for 1-row agent; truncates at 64 KiB; skips unreadable file with logged warning; respects position DESC ordering.
3. New frontend tests cover:
   - `AddAgentDialog.spec.ts`: shows "Add Agent" title, name input is required, folder picker integration.
   - `AgentKnowledgeDialog.spec.ts`: path required + absolute validation, label optional, Browse opens picker.
   - `AgentView.spec.ts`: renders knowledge list, add button opens dialog, remove button calls store action, drag-reorder emits correct event, New Chat button opens dialog, empty state shown when no entries.
4. Manual smoke:
   - Add an Agent via the sidebar.
   - Add 2-3 markdown files to its Knowledge panel.
   - Open a chat under the Agent.
   - Confirm the agent references the file contents in its first response.
   - Delete one knowledge entry, start a new chat — confirm the deleted file is no longer referenced.
   - Edit a knowledge file externally, start a new chat — confirm the new content is in the system prompt.

## Out of scope (confirmed by user — ship as follow-up)

- **System-prompt override** (`agents.system_prompt_override TEXT`). User did not request; defer until needed.
- **Per-chat knowledge override.** A single chat within an Agent can either use ALL knowledge or none; no per-chat subset UI.
- **In-app markdown editor.** User edits knowledge files in their external editor (VS Code, Obsidian, etc.). The frontend just stores the path.
- **Embedding / vector search / RAG.** Out of scope — knowledge is read in full every chat. If the 64 KiB cap becomes a bottleneck, that's the next conversation.
- **Knowledge file watching.** No `inotify` / `fs.watch` — backend re-reads files at session start. Edits to a file mid-chat won't reflect until the next chat.
- **Per-entry toggle ("include this file?").** All entries are always included. If a future use case wants optional entries, add an `enabled` boolean column to a future migration.
- **Knowledge search / autocomplete** in the path input. Browse dialog covers most cases; a free-form text input is enough for v1.

## Risks

- **Path validation is best-effort.** We check `std.fs.path.isAbsolute` and that we can `openFile`. We do NOT check that the file is a markdown file (`.md` extension), the file size, or the file encoding. Mitigation: cap reads at 16 KiB per file + 64 KiB total. If users point at huge or binary files, the cap protects the context window; the agent gets garbage and may ignore it.
- **System prompt bloat.** Each Agent chat carries up to 64 KiB of knowledge. With OpenAI's GPT-4 (8K-128K context) this is meaningful headroom; with smaller models it can crowd out the actual conversation. Mitigation: explicit cap, future-proofing via the `MAX_TOTAL_BYTES` constant.
- **Race between file edit and chat start.** If the user edits the file in the 5 ms between the backend reading it and the LLM responding, the response references the old content. Mitigation: not a real-world problem (LLM responses take seconds; user edits take seconds; humans don't notice 5ms windows).
- **Sidebar dropdown grows from 3 to 4 options.** Still fits, but the visual spacing may need a tweak. Mitigation: keep the dropdown text-only (no icons); if it grows past 6, refactor to a sub-menu.
- **`agents.id` == `workspace_item_id`** creates a subtle invariant — if the workspace_item row gets its `id` changed (it can't today, but a future migration might), the agent id drifts. Mitigation: enforce FK at the DB level; add an `id` column to `agents` if a future migration needs a separate id space.