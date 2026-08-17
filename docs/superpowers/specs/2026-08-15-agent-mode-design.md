# Agent Mode — Design Spec

**Date:** 2026-08-15
**Branch:** `worktree/agent-mode`
**Task:** `task_1786962724740_0` ("new feature AgentMode")
**Author:** brainstorming session with user (decided iteratively: agent = chatbot + markdown knowledge files)

## TL;DR

Add a fourth workspace-item type — `agent` — sitting alongside `folder`/`kanban`/`design`. Each Agent item is a persistent chatbot configuration: it has its own `path` (cwd for its chats, like Kanban/Design), a list of **markdown knowledge files on disk**, and a **tool allowlist** that restricts which agent tools the LLM can call. When a chat session is opened under an Agent, the backend reads every knowledge file's contents and injects them into the system prompt as a new `## Agent Knowledge` section; it also filters the tool registry so the LLM only sees tools explicitly enabled for that Agent. Three new tables (`agents` 1-1 with `workspace_items`, `agent_knowledge` N-1 with `agents`, `agent_tools` N-1 with `agents`). No change to existing `agent_memories` (which stays a global tool-driven note store, separate concept).

**Secure-by-default tool semantics:** a brand-new Agent with an empty `agent_tools` allowlist gets **zero tools** — it is a pure chat. The user must explicitly add tools via the Tools panel to give the agent any capabilities. This is intentional and matches the user's framing ("we need to limit the tool that's used").

## User intent (captured during brainstorming)

> "new feature AgentMode ... add a menu name Agent ... just like standard chatbot, but we can add knowledge ... new table name agent ... relation: workspaces → workspace_item_id 1-to-1 with new table agent → many workspace_item_tasks ... memory is like markdown but we need add the table ... `agent_knowledge` is different from `agent_memories` (memories is a tool) ... `agent_knowledge` is read markdown file path ... absolute paths ... also we need to limit the tool that used, that mean, we have to add agent_tool table ... No tools allowed, if not set."

Decisions locked in before drafting:
- **Knowledge = absolute file paths to markdown** (no embeddings, no upload UI, no DB-stored content)
- **Agent has a `path` (cwd)** — parity with Kanban/Design
- **`agent_knowledge` is a new table**, distinct from `agent_memories`
- **Tool allowlist via new `agent_tools` table** — empty allowlist = zero tools (secure by default)
- **Sidebar UX:** new "Add Agent" item in the existing `+ Add Item` dropdown

## Goal

After this feature ships:
1. A user can click `+ Add Item → Add Agent`, enter a name + folder path, and a new Agent appears in the sidebar tree.
2. Clicking the Agent opens a new `AgentView` with: a **Knowledge panel** (list of markdown paths with add/remove/edit), a **Tools panel** (checkbox list of every available agent tool, with add/remove), and a list of chat sessions under the Agent (existing `workspace_item_tasks` rows scoped to this Agent's item_id).
3. Adding a knowledge entry = pick an absolute markdown file path on disk (text input + optional Browse dialog). The label is optional.
4. Opening/starting a chat under the Agent auto-injects the contents of every knowledge file into the system prompt as `## Agent Knowledge`. **No content-size cap** — the full contents of every file are read and injected. The backend re-reads files every session and never caches the file contents.
5. If a knowledge file path is missing or unreadable at session start, it's logged and skipped — the chat still works with whatever files were readable.
6. Editing the markdown file on disk (in any external editor) reflects on the next chat start — the backend re-reads files every session, never caches.
7. **Single engineering-hygiene bound:** each file is read with a `readToEndAlloc`-style upper bound of **100 MiB** purely to prevent the server from OOM-ing on a misconfigured path like `/dev/zero` or a multi-GB binary. This is NOT a content budget — it's a single-file OOM safety. Files larger than 100 MiB are logged + skipped with a clear error message naming the path; they don't break the chat.
8. **Tool allowlist filters the runtime tool registry:** when the agent loop builds the tool list for a session bound to an Agent, it queries `agent_tools WHERE agent_id = ? AND enabled = 1` and only registers tools whose `tool_name` is in the returned set. The LLM never sees tools outside the allowlist in its function-call schema. A brand-new Agent with an empty allowlist gets **zero tools** — pure chat, no tool use at all. The user must opt in via the Tools panel.

## Why a dedicated `agents` table (and not just columns on `workspace_items`)

The user's diagram specifies a 1-1 table (`workspaces` → `workspace_items` → `agents`). Keeping it separate:
- Future agent-specific fields (system-prompt override, default model, allowed-tools allowlist, embedding-config toggle) become additive columns on `agents`, NOT new columns on `workspace_items` (which would affect kanban / design / folder rows too).
- Enforces the 1-1 invariant via `UNIQUE(workspace_item_id)` at the schema level, not just at the application layer.
- Mirrors the `kanban_columns`/`design_pages` pattern of "type-specific data lives in a sibling table keyed by item_id".

## Why a new `agent_knowledge` table (and not storing content in the `agents` row)

- One Agent has N knowledge files. A TEXT column can't model N rows.
- The backend re-reads file contents from disk every chat — no content is ever duplicated into SQLite. Storage stays small (just paths).
- A separate table also enables per-entry metadata (label, position, created_at) and future per-entry behaviour (e.g. a per-file "always include" toggle) without a migration.

## Why a separate `agent_tools` table (and not a column on `agents`)

- One Agent has N tools enabled. A TEXT column (`allowed_tools` comma-separated) can't model N rows cleanly — duplicating strings, no per-tool metadata.
- A separate table gives us per-row `enabled` toggle for v1 + room for future per-tool columns (e.g. per-tool rate limit, per-tool system-prompt override) without yet another migration.
- The runtime filter is a single SQL query (`SELECT tool_name FROM agent_tools WHERE agent_id = ? AND enabled = 1`), no string parsing.
- The schema (`tool_name TEXT NOT NULL` + `UNIQUE(agent_id, tool_name)`) prevents duplicate rows for the same tool.

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

#### `agent_tools` (NEW — Migration 076)

```sql
CREATE TABLE IF NOT EXISTS agent_tools (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_agent_tools_agent_id ON agent_tools(agent_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_tools_agent_tool ON agent_tools(agent_id, tool_name);
```

Notes:
- `tool_name` matches the existing agent tool registry (e.g. `"bash"`, `"read_file"`, `"edit_file"`, `"kanban_list"`, `"save_memory"`, `"load_memory"`, `"generate_image"`, `"spawn_sub_agent"`, `"update_design_element"`, etc.). The full list is enumerated at runtime from the registry; we don't ship a hard-coded list in the schema or in the spec.
- `enabled` defaults to 1. The frontend always sends 1 on create (the v1 UI never offers a "disabled" toggle). The column exists so future UX (e.g. "temporarily disable a tool without removing it") doesn't need a migration.
- `UNIQUE(agent_id, tool_name)` prevents the same tool being added twice — the POST endpoint relies on this constraint for clean error semantics (the handler maps the SQLite UNIQUE violation to a 409 with a clear message).
- `ON DELETE CASCADE` mirrors `agent_knowledge` — deleting the parent agent drops its tool rows.
- **Empty allowlist = zero tools (secure-by-default).** When the agent loop builds the tool registry for an Agent session, it queries this table; if the result is empty, the session gets no tools. This is intentional and is the central UX choice of the Tools panel.

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
| GET | `/api/agents/:agentId/tools` | List enabled tool names | — | `200 {tools: string[]}` |
| POST | `/api/agents/:agentId/tools` | Enable a tool for this agent | `{tool_name}` | `201 {tool: AgentToolRow}` |
| DELETE | `/api/agents/:agentId/tools/:toolId` | Disable + remove a tool | — | `200 {ok: true}` |

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

`AgentToolRow`:
```zig
{
    id: []const u8,
    agent_id: []const u8,
    tool_name: []const u8,
    enabled: u8, // 0 or 1
    created_at: []const u8,
}
```

### Frontend surface

| File | Change |
|---|---|
| `src/apps/desktop/src/components/workspace/WorkspaceList.vue` | Add a 4th `<li>` in the `+ Add Item` dropdown: `<button @click="handleAddItem(workspace.id, 'agent')">Add Agent</button>` |
| `src/apps/desktop/src/components/shell/Sidebar.vue` | `handleAddItem` adds `if (itemType === 'agent') showAddAgentDialog.value = true`. New `handleCreateAgent` mirrors `handleCreateKanban`. |
| `src/apps/desktop/src/components/dialogs/AddAgentDialog.vue` (NEW) | Mirrors `AddKanbanDialog.vue` (name + folder picker via `FilePickerDialog`). |
| `src/apps/desktop/src/views/AgentView.vue` (NEW) | Mounted by AppLayout when `activeWorkspaceItem.item_type === 'agent'`. Layout: left column = Knowledge panel (list of entries with add/remove/reorder) + Tools panel (checkbox list of every available tool, with add/remove); right column = recent chat sessions (`workspace_item_tasks` filtered by `workspace_item_id`) with a "New Chat" button. |
| `src/apps/desktop/src/components/dialogs/AgentKnowledgeDialog.vue` (NEW) | Modal for adding a single knowledge entry. Path input + optional "Browse" (opens `FilePickerDialog` in `mode='file'` + `.md` filter). |
| `src/apps/desktop/src/stores/agentTools.ts` (NEW) | Pinia store holding the **canonical tool registry** (the list of all available agent tools, fetched once from a new `/api/agent-tools/registry` endpoint OR enumerated client-side from a static list). The Tools panel reads this to render checkboxes. |
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
   - Read the file's full contents via `readToEndAlloc(allocator, MAX_FILE_BYTES_OOM_SAFETY)` where `MAX_FILE_BYTES_OOM_SAFETY = 100 * 1024 * 1024` (100 MiB). If `error.StreamTooLong` fires (file > 100 MiB), log + skip — don't break the chat.
   - Wrap in `\n### <label-or-basename>\n<file: absolute_path>\n\n<content>\n`.
5. Prepend `\n\n## Agent Knowledge\n\n` and the user-facing disclaimer `"The following markdown files are part of this Agent's knowledge. Treat them as authoritative reference for any user question that touches their topics; do not invent details that contradict them."\n\n`.
6. If `agent_knowledge` is empty, return `""`.

Wired into the existing prompt-assembly pipeline alongside `prompts_make_workspace_context.zig`:
```zig
const workspace_ctx = try makeWorkspaceContext(alloc, db, session_id);
const agent_knowledge = try makeAgentKnowledge(alloc, db, session_id);
defer { alloc.free(workspace_ctx); alloc.free(agent_knowledge); }
return try std.fmt.allocPrint(alloc, "{s}{s}", .{ workspace_ctx, agent_knowledge });
```

### Runtime tool filtering

The tool allowlist is enforced at **tool-construction time**, not at the system-prompt level. This is intentional: a tool removed from the LLM's function-call schema cannot be called at all, even by a clever prompt.

New helper: `src/ai_workflow/tui/agentic_loop/agent_tools_allowed.zig`:
```zig
pub fn agentToolsAllowed(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]const []const u8 {
    // Returns the list of tool names enabled for the agent bound to this
    // workspace_item. Returns empty slice when:
    //   - the workspace_item doesn't exist
    //   - the workspace_item's item_type is NOT 'agent' (caller's job to skip)
    //   - the agent has no rows in agent_tools (SECURE-BY-DEFAULT)
    // Caller MUST treat an empty slice as "no tools" — NOT as "all tools".
    ...
}
```

Integration point: wherever the agent loop currently constructs its tool list for a session (the existing `tools.zig` or wherever `makeToolsForSession` lives), add a single conditional at the top:

```zig
const allowed_tools = agentToolsAllowed(alloc, db, workspace_item_id);
defer alloc.free(allowed_tools);

const all_tools = try makeAllTools(alloc, ...);
defer all_tools.deinit(alloc);

if (is_agent_item and allowed_tools.len == 0) {
    // Agent with empty allowlist → register zero tools.
    return &[_]Tool{};
}

if (is_agent_item) {
    // Filter to the allowlist.
    var filtered = std.ArrayList(Tool).empty;
    for (all_tools) |tool| {
        for (allowed_tools) |name| {
            if (std.mem.eql(u8, tool.name, name)) {
                try filtered.append(alloc, tool);
                break;
            }
        }
    }
    return filtered.items; // may still be empty if no names matched
}

return all_tools; // non-agent items: unchanged
```

The `is_agent_item` check is a single SELECT against `workspace_items.item_type`. It is computed once per session-start, not per LLM call.

**Important semantic:** a non-Agent item (kanban/design/folder) gets the **existing behaviour** — no filtering. Only sessions bound to `item_type='agent'` see the allowlist filter. This matches the user's intent ("we need to limit the tool that's used" applies only to Agents).

### Tool registry enumeration

For the frontend's Tools panel to render a checkbox list, it needs to know the canonical list of all available agent tools. We expose this via a new read-only endpoint:

```
GET /api/agent-tools/registry → 200 {tools: [{name, description}]}
```

The handler walks the same registry the runtime uses (the `tools/*.zig` files), producing `{name, description}` pairs. The handler is the single source of truth — the frontend never hard-codes a tool name.

**v1 simplification:** the registry can be a static constant list maintained alongside the spec (so the runtime and the registry endpoint never drift). If the list ever needs to be dynamic, we extend the registry endpoint — the schema and the runtime filter don't change.

### Migration safety

- Both tables use `CREATE TABLE IF NOT EXISTS` — re-running the migration on a DB that already has them is a no-op.
- `idx_*` indexes use `CREATE INDEX IF NOT EXISTS`.
- `UNIQUE(workspace_item_id)` on `agents` is part of the CREATE TABLE statement — a partial re-run where the table exists without the constraint would NOT add the constraint. To handle this, probe `pragma_index_list` + `pragma_table_info` before CREATE; if either check fails, log and continue (mirrors the pattern in `Migration072ExtractKanbanTable`).
- No data migration — `agents` and `agent_knowledge` start empty. Pre-existing workspaces have no Agents.

## Files touched

| File | Change |
|---|---|
| `src/migrations/migration.zig` | Add `Migration076AddAgentsAndAgentKnowledgeAndAgentTools`. Creates 3 tables: `agents`, `agent_knowledge`, `agent_tools`. Register in `allMigrations`. |
| `src/migrations/migration_076_test.zig` (NEW) | 9 tests: 3 tables exist with correct columns, `agents.workspace_item_id` is UNIQUE, FK CASCADE works for all 3, `agent_knowledge.position` index exists, `agent_tools(agent_id, tool_name)` UNIQUE index exists, idempotency on re-run. |
| `src/migrations/test_runner.zig` | Register the new test file. |
| `src/models/agent.zig` (NEW) | `Agent` row struct mirroring the `workspace_item` row + `description`. `init/deinit/clone`. |
| `src/models/agent_knowledge.zig` (NEW) | `AgentKnowledge` row struct. `init/deinit/clone`. |
| `src/models/agent_tool.zig` (NEW) | `AgentTool` row struct. `init/deinit/clone`. |
| `src/ai_workflow/tui/http_handlers/workspace_items_create_agent.zig` (NEW) | Mirrors `workspace_items_create_kanban.zig`. POST handler that creates the workspace_item + agents row in one transaction (no extra seed data — the agent starts with empty knowledge list AND empty tool allowlist, which means zero tools by default). |
| `src/ai_workflow/tui/http_handlers/agents_get.zig` (NEW) | GET handler for `/api/workspaces/:wsId/items/:itemId/agent` returning `{agent, knowledge, tools}`. |
| `src/ai_workflow/tui/http_handlers/agents_update.zig` (NEW) | PATCH handler for description. |
| `src/ai_workflow/tui/http_handlers/agent_knowledge_*.zig` (NEW, 5 files) | GET / POST / PATCH / DELETE / PATCH-reorder handlers. |
| `src/ai_workflow/tui/http_handlers/agent_tools_*.zig` (NEW, 3 files) | GET / POST / DELETE handlers. POST validates `tool_name` against the registry (400 if unknown). DELETE maps the SQLite UNIQUE violation to a 409 on duplicates (defensive — handler also checks first). |
| `src/ai_workflow/tui/http_handlers/agent_tools_registry.zig` (NEW) | GET `/api/agent-tools/registry` — returns `{tools: [{name, description}]}` enumerated from the static registry constant. |
| `src/ai_workflow/tui/http_handlers/router.zig` (or equivalent) | Register the 12 new routes (8 prior + 4 tool routes: list/add/remove/registry). |
| `src/ai_workflow/tui/agentic_loop/prompts_make_agent_knowledge.zig` (NEW) | The new prompt section. |
| `src/ai_workflow/tui/agentic_loop/agent_tools_allowed.zig` (NEW) | `agentToolsAllowed` helper — returns the enabled tool names for an agent (empty when allowlist is empty or item is not an agent). |
| `src/ai_workflow/tui/agentic_loop/tools.zig` (or wherever `makeAllTools` lives) | One-call conditional filter at tool-construction time. Only filters for agent items; non-agent items get the existing behaviour unchanged. |
| `src/ai_workflow/tui/agentic_loop/prompts_assemble.zig` (or wherever the workspace-context prompt is currently assembled) | Wire `makeAgentKnowledge` into the pipeline. |
| `src/apps/desktop/src/api/index.ts` | 13 new typed wrappers (9 prior + 4 tool wrappers: list/add/remove/registry). |
| `src/apps/desktop/src/stores/workspaces.ts` | 6 new actions (4 prior + 2 tool actions). |
| `src/apps/desktop/src/stores/agentTools.ts` (NEW) | Pinia store holding the canonical tool registry (fetched once on app startup, cached). Tools panel reads this to render checkboxes. |
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
| Open / start a chat under the Agent (no tools added) | n/a | Session runs as pure chat — LLM has **zero tools** registered, can only respond with text |
| Open / start a chat under the Agent (tools enabled) | n/a | Session runs with **only the enabled tools** in the function-call schema |
| Toggle a tool's checkbox in the Tools panel | n/a | POST/DELETE on `/api/agents/:agentId/tools`; new chats see the updated allowlist |
| Open / start a chat under a Kanban / Design item | unchanged | unchanged — no allowlist filter applied to non-Agent items |
| Click remove on a knowledge entry | n/a | Entry deleted from DB + panel re-renders |
| Drag-reorder knowledge entries | n/a | Positions updated via PATCH /reorder |
| Edit a knowledge `.md` file externally, start a new chat | n/a | Next chat reflects the new contents (backend re-reads every session) |
| Knowledge path is missing / unreadable | n/a | Logged + skipped; chat continues with remaining files |
| Knowledge file > 100 MiB | n/a | Logged + skipped with a clear error; chat continues with remaining files |
| POST a duplicate `tool_name` to `/api/agents/:agentId/tools` | n/a | 409 Conflict (UNIQUE constraint hit) |
| POST an unknown `tool_name` to `/api/agents/:agentId/tools` | n/a | 400 (not in the static registry) |

## Global Constraints

- **Backward compatible.** Existing `workspace_items` rows (folder/kanban/design) are untouched. The new `agents` / `agent_knowledge` / `agent_tools` tables start empty. No new system-prompt content is added for non-Agent items.
- **Tool-filter behaviour change is scoped to `item_type='agent'`.** Non-Agent sessions (kanban/design/folder/standalone chat) get the existing full tool registry — no filtering. This is a single-call conditional at tool-construction time, not a global hook.
- **No wire-shape change to existing endpoints.** All 12 new endpoints are additive. The `workspace_items.item_type` column continues to accept any string — `'agent'` is just one more valid value.
- **No new global error variants.** HTTP handlers reuse existing `400` / `500` mapping + add `409` for duplicate tool names (mirrors the pattern used by Kanban column renames). The frontend surfaces validation errors via existing error-rendering patterns.
- **Idempotent migration.** Migration 076 is safe to re-run.
- **Pure-Zig backend, Vue/TS frontend.** All three platforms (Linux/macOS/Windows) compile + test green.
- **YAGNI.** No system-prompt-override column, no model-preference column, no per-chat knowledge override, no embed/RAG columns. All deferred — the `agents` table is the additive home for any of these as future migrations.
- **TDD.** Every backend change has a failing test written before the implementation patch. Every new frontend component has a `*.spec.ts` test that mounts the dialog and asserts the expected wiring.

## Verification

Before claiming done:
1. `zig build test --summary all` — all green, including the 9 new migration tests + handler tests + prompt-injection tests + tool-filter tests.
2. New backend tests cover:
   - Migration 076: 3 tables exist with correct columns, idempotency, UNIQUE constraint on `agents.workspace_item_id`, UNIQUE constraint on `agent_tools(agent_id, tool_name)`, CASCADE delete from `workspace_items → agents → {agent_knowledge, agent_tools}`.
   - `workspace_items_create_agent`: returns 201 with `{item, agent}`, both rows exist in DB. Agent's `agent_tools` table is empty (no tools by default).
   - `agents_get`: returns agent + knowledge list + tools list, knowledge ordered by position DESC, tools ordered by tool_name.
   - `agents_update`: updates description, 404 if item not found, 400 if not an agent.
   - `agent_knowledge_create`: validates absolute path (rejects relative), assigns position.
   - `agent_knowledge_update`, `_delete`, `_reorder`: standard CRUD.
   - `agent_tools_list`: returns enabled tool names for the agent.
   - `agent_tools_create`: validates `tool_name` against the registry (400 if unknown), returns 409 on duplicate.
   - `agent_tools_delete`: removes the tool row.
   - `agent_tools_registry`: returns the full static registry.
   - `agentToolsAllowed`: returns empty for non-agent items, empty for agent items with empty allowlist, returns the allowlist contents otherwise.
   - `prompts_make_agent_knowledge`: empty for non-agent items; reads 1 file for 1-row agent; reads the full contents (no truncation); skips unreadable file with logged warning; skips files > 100 MiB with logged warning; respects position DESC ordering.
   - **Tool filter integration:** with the existing `makeAllTools` returning 5 tools (e.g. bash, read_file, kanban_list, save_memory, load_memory), a chat on a non-Agent item sees all 5; a chat on an Agent with empty allowlist sees 0; a chat on an Agent with `["bash", "read_file"]` enabled sees exactly those 2.
3. New frontend tests cover:
   - `AddAgentDialog.spec.ts`: shows "Add Agent" title, name input is required, folder picker integration.
   - `AgentKnowledgeDialog.spec.ts`: path required + absolute validation, label optional, Browse opens picker.
   - `AgentView.spec.ts`: renders knowledge list, add button opens dialog, remove button calls store, drag-reorder emits correct event, **renders Tools panel with checkboxes from registry**, toggle calls `enableTool` / `disableTool` store actions, New Chat button opens dialog, empty state shown when no entries.
4. Manual smoke:
   - Add an Agent via the sidebar.
   - Confirm the Tools panel renders an unchecked checkbox per available tool (registry count = N).
   - Confirm a chat opened under the Agent with no tools toggled has zero tools (LLM responds with text-only when asked "what tools do you have?").
   - Enable `bash` + `read_file`, start a new chat, confirm the LLM can call them (and not the others — e.g. asking for a Kanban operation fails with "tool not available").
   - Add 2-3 markdown files to the Knowledge panel.
   - Confirm the agent references the file contents in its first response.
   - Delete one knowledge entry, start a new chat — confirm the deleted file is no longer referenced.
   - Edit a knowledge file externally, start a new chat — confirm the new content is in the system prompt.

## Out of scope (confirmed by user — ship as follow-up)

- **System-prompt override** (`agents.system_prompt_override TEXT`). User did not request; defer until needed.
- **Per-chat knowledge override.** A single chat within an Agent can either use ALL knowledge or none; no per-chat subset UI.
- **In-app markdown editor.** User edits knowledge files in their external editor (VS Code, Obsidian, etc.). The frontend just stores the path.
- **Embedding / vector search / RAG.** Out of scope — knowledge is read in full every chat (no content cap, per user choice). If context-window pressure becomes a real problem, RAG is the obvious follow-up, but not now.
- **Knowledge file watching.** No `inotify` / `fs.watch` — backend re-reads files at session start. Edits to a file mid-chat won't reflect until the next chat.
- **Per-entry toggle ("include this file?").** All entries are always included. If a future use case wants optional entries, add an `enabled` boolean column to a future migration.
- **Knowledge search / autocomplete** in the path input. Browse dialog covers most cases; a free-form text input is enough for v1.

## Risks

- **Path validation is best-effort.** We check `std.fs.path.isAbsolute` and that we can `openFile`. We do NOT check that the file is a markdown file (`.md` extension), the file encoding, or the file size (beyond the 100 MiB per-file OOM safety). If users point at huge or binary files, the file is read in full and the LLM receives whatever bytes were there. The 100 MiB safety prevents the server from OOM-ing on pathological paths like `/dev/zero`.
- **System prompt bloat (no cap, by user choice).** Each Agent chat carries the full contents of every knowledge file. With OpenAI's GPT-4 (8K-128K context) this can crowd out the actual conversation when the corpus is large; the user opted out of an automatic cap. If the LLM starts refusing long prompts or losing quality, the follow-up is to add either a per-file cap, a per-agent cap, or a smart truncation strategy. For now, this is the user's explicit call.
- **Secure-by-default means new Agents are zero-capability until configured.** A user who creates an Agent and immediately starts a chat expecting tool behaviour will get pure text-only responses. The AgentView's empty-state message must make it clear: "No tools enabled — open the Tools panel to enable some." Without that nudge, users will think the feature is broken. Mitigation: explicit empty-state copy in the Tools panel + a "Tip: enable at least one tool to give this Agent any actions" hint when a chat starts with zero tools.
- **Race between file edit and chat start.** If the user edits the file in the 5 ms between the backend reading it and the LLM responding, the response references the old content. Mitigation: not a real-world problem (LLM responses take seconds; user edits take seconds; humans don't notice 5ms windows).
- **Sidebar dropdown grows from 3 to 4 options.** Still fits, but the visual spacing may need a tweak. Mitigation: keep the dropdown text-only (no icons); if it grows past 6, refactor to a sub-menu.
- **`agents.id` == `workspace_item_id`** creates a subtle invariant — if the workspace_item row gets its `id` changed (it can't today, but a future migration might), the agent id drifts. Mitigation: enforce FK at the DB level; add an `id` column to `agents` if a future migration needs a separate id space.