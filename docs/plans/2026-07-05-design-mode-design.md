# Design Mode — Design

**Status:** Approved (brainstorming complete 2026-07-05)
**Owner:** Workspace features
**Branch prefix:** `feature/design-mode`

## Goal

Add a new workspace item type — `design` — that hosts a chat-driven HTML canvas. The LLM produces HTML through three new tools; the user sees the result render live in an iframe filling the main content area. No source editor, no WYSIWYG overlay, no diagram-specifics — just HTML rendered in a sandbox.

The "design" item sits alongside `folder` and `kanban` items in the workspace sidebar dropdown. Users add a design via `+ Add Item → Add Design`, then chat with the agent to populate the canvas.

## Decisions locked during brainstorming

1. **Use case.** AI-driven HTML canvas. The LLM is the primary author; the user iterates through chat.
2. **Editing mode.** Pure preview (iframe only, no source pane).
3. **Pages per item.** Multiple named pages per design item. The item acts as a mini-Figma — tab strip across the top.
4. **Tool surface.** Three tools: `set_design_page`, `delete_design_page`, `list_design_pages`.

## Data model

### New table `design_pages` (Migration 055)

```sql
CREATE TABLE design_pages (
    id TEXT PRIMARY KEY,
    workspace_item_id TEXT NOT NULL,
    name TEXT NOT NULL,                   -- user-facing label, e.g. "Login"
    html TEXT NOT NULL DEFAULT '',       -- full HTML document (incl. inline <style>, <script>)
    position INTEGER NOT NULL DEFAULT 0, -- tab-strip order
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX idx_design_pages_item_name
    ON design_pages(workspace_item_id, name);
CREATE INDEX idx_design_pages_item_position
    ON design_pages(workspace_item_id, position);
```

`item_type='design'` is a new value on the existing free-form `workspace_items.item_type` TEXT column. No other schema change.

The unique `(workspace_item_id, name)` index makes the LLM's idempotent `set_design_page(item_id, page_name, html)` clean: `INSERT ... ON CONFLICT(workspace_item_id, name) DO UPDATE SET html = excluded.html, updated_at = datetime('now')`.

`html` is unbounded TEXT — practical pages will be a few hundred KB. A future iteration can add a hard size limit (5 MB) at the application layer; SQLite handles multi-MB text columns fine.

## API surface (5 new endpoints)

All endpoints under the existing `/api/workspaces/:workspace_id/items` prefix. Use the established `parseFromSliceLeaky` + `std.json.Stringify.valueAlloc` patterns.

| Method | Path | Purpose | Body / returns |
|---|---|---|---|
| `POST` | `/api/workspaces/:workspace_id/items/design` | Create a design item | Body: `{name}`. Returns `{id, workspace_id, item_type:"design", name, position, pages:[]}` (201) |
| `GET` | `/api/workspaces/:workspace_id/items/:item_id/design/pages` | List all pages in a design | Returns `[{id, name, position, created_at, updated_at}, ...]` ordered by `position`. Excludes `html` — lazy-load the active page only. |
| `GET` | `/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id` | Fetch one page (with HTML) | Returns `{id, name, html, position, created_at, updated_at}` (200) or 404. |
| `PUT` | `/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id` | Replace a page's HTML | Body: `{html}`. Returns the updated page row. Emits `design_page_updated` SSE. |
| `DELETE` | `/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id` | Delete a page | Returns `{deleted: true, page_id}`. Emits `design_page_deleted` SSE. |

The existing `GET/PUT/DELETE /items/:item_id` endpoints cover rename, delete-item, etc.

`POST /design/pages` is intentionally absent — the LLM tool `set_design_page` is idempotent and implemented via `INSERT ... ON CONFLICT ... DO UPDATE`, so there's no separate "create" handler. The frontend's "+ Add Page" button calls the API directly (not via a chat roundtrip).

## LLM tool surface (3 tools)

All three tools are registered in `src/ai_workflow/tui/tool_registry.zig` next to the existing `kanban_*` entries. Each gets a static test verifying its description is present (per the project convention).

| Tool | Input | Behavior | SSE event on success |
|---|---|---|---|
| `set_design_page` | `{item_id, page_name, html}` | Idempotent: replace if exists, create if not. New pages get `position = MAX(position)+1`. | `design_page_updated` with full page row |
| `delete_design_page` | `{item_id, page_name}` | Removes the row matching `(item_id, name)`. Returns `{deleted: bool, page_name}`. | `design_page_deleted` |
| `list_design_pages` | `{item_id}` | Returns `[{name, position, has_html, updated_at}, ...]`. Read-only. | (none) |

`page_name` (not `page_id`) in the tool input because the LLM thinks in names; the agent looks up `id` from `(item_id, name)` internally. Idempotency on `name` works because the unique index enforces it.

Tool descriptions live in `src/modules/agent/tools/design_tools.zig` (new file), following the `ToolExecFunc` pattern.

## Frontend architecture

### A. Sidebar dropdown

- `src/apps/desktop/src/components/WorkspaceList.vue:613-628` — add a third `<li><button>` after "Add Kanban" in the existing dropdown. Click handler calls `handleAddItem(workspace.id, 'design')`.
- `src/apps/desktop/src/components/Sidebar.vue:374-382` — extend `handleAddItem` to set `showAddDesignDialog.value = true` when `itemType === 'design'`.
- New `src/apps/desktop/src/components/AddDesignDialog.vue` — minimal modal with just a name input. No folder picker (design items don't bind to disk). Emits `create(name)`.
- `src/apps/desktop/src/stores/workspaces.ts` — add `addDesignItem(workspaceId, name)` next to `addKanbanItem`. Calls `api.createDesign(workspaceId, name)`.
- `src/apps/desktop/src/api/index.ts` — add `createDesign`, `listDesignPages`, `getDesignPage`, `updateDesignPage`, `deleteDesignPage`. Use `apiFetch` (with text() and Pinia in tests).

### B. New `DesignView.vue` component

`src/apps/desktop/src/components/DesignView.vue` — new file, ~250 lines.

Layout (flex column, full-screen):
- **Tab strip** at top — horizontal scrollable row of page tabs (one per page in the item's `design_pages`). Each tab shows `name` + a small `×` close button that dispatches a delete. Active tab is highlighted.
- **"+ Add Page" button** at the end of the tab strip — opens a small inline prompt for a name, then calls `api.updateDesignPage(item_id, '<empty>', name)` directly (or `api.setDesignPage` if the route is renamed later — see API naming note below).
- **Iframe** filling the rest of the area — `srcDoc` bound to `activePageHtml`. Sandbox attribute: `sandbox="allow-scripts"` (no `allow-same-origin`). Use `srcdoc` (not `src`) so no server roundtrip is needed.

State: `pages: Ref<PageSummary[]>`, `activePageId: Ref<string|null>`, `activePageHtml: Ref<string>`. When `activePageId` changes, fetch the page via `GET .../design/pages/:page_id` and set `activePageHtml`.

Listen for `design_page_updated` — if it matches `activePageId`, refetch the HTML. If it matches a different page in this item, just refresh the tabs (don't auto-switch active). Listen for `design_page_deleted` — remove the tab; if it was active, switch to first remaining page or show empty state.

### C. Routing

`src/apps/desktop/src/components/AppLayout.vue:1188-1326` — add a new `v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'design'"` branch mounting `<DesignView>` alongside `<ChatView>` in a side-by-side layout (same pattern as the kanban + chat layout). When no chat/task exists for the item yet, show `<DesignView>` full-width with a "Start designing" button that creates a new task with `task_type='standard'` and navigates to it.

### D. Type additions

- `src/apps/desktop/src/stores/workspaces.ts:26-49` — add `'design'` to the `WorkspaceItem.item_type` literal type, add optional `design_pages?: PageSummary[]` (mirrors `kanban_columns`).
- `src/apps/desktop/src/api/index.ts` — add `DesignPageSummary` interface and `DesignPageFull` (adds `html`).

## SSE event protocol

3 new event types (matching the established `kanban_column_*` prefix style). All routed through `on_event_sent_design.zig`.

### `design_page_updated`

```json
{
  "event": "design_page_updated",
  "data": {
    "action": "created" | "updated",
    "workspace_id": "ws_...",
    "item_id": "item_...",
    "page": { "id": "page_...", "name": "Login", "position": 0, "html": "<!doctype html>...", "updated_at": "..." }
  }
}
```

Emitted by `set_design_page` tool handler. `page.html` is included so the frontend can apply without a follow-up GET.

### `design_page_deleted`

```json
{
  "event": "design_page_deleted",
  "data": {
    "action": "deleted",
    "workspace_id": "ws_...",
    "item_id": "item_...",
    "page_id": "page_...",
    "page_name": "Login"
  }
}
```

Emitted by `delete_design_page` tool handler.

Implementation: new `src/ai_workflow/tui/on_event_sent_design.zig` (mirrors `on_event_sent_kanban.zig`). Payload structs in `src/ai_workflow/tui/on_event_design.zig`. Re-export from `src/ai_workflow/tui/mod.zig`. Frontend subscribes via the existing SSE plumbing.

## Error handling

HTTP status codes for the 5 handlers (mirrors the kanban handler pattern):

| Error | HTTP | Message |
|---|---|---|
| Empty `name` | 400 | `name is required` |
| Item is wrong type (not `design`) | 409 | `item is not a design` |
| Item id not found | 404 | `item not found` |
| Page name contains `/` or null byte | 400 | `page name must be a valid identifier` |
| Page html exceeds 5 MB | 413 | `html exceeds maximum size of 5 MB` |
| DB error | 500 | `database error` |
| Out of memory | 500 | `out of memory` |

LLM tool errors: wrap HTTP errors back into tool-result XML following `kanban_model.zig`'s convention. 4xx → self-correcting hint for the LLM. 5xx → raw error name, agent retry loop handles.

Iframe is sandboxed with `sandbox="allow-scripts"` only (no `allow-same-origin`). This blocks access to parent storage, cookies, DOM. The HTML the LLM produces cannot exfiltrate session data. **No HTML sanitization in v1** — the sandbox is the security boundary.

Iframe runtime errors (uncaught JS, CSP violations) surface only in DevTools — they don't propagate to the parent. Acceptable for v1; a future iteration could add a `postMessage` channel.

## Testing strategy

Three layers, matching project conventions.

### Zig unit tests (`src/ai_workflow/tui/design_model_test.zig`)

~150 lines, ~10 tests covering:
- `addPage` creates row, returns id, position = `MAX(position)+1`.
- `addPage` on existing `(item_id, name)` updates in place (idempotent).
- `addPage` on empty item gets position 0.
- `listPages` returns rows in `position ASC`, excludes `html`.
- `getPage(id)` returns full row including `html`.
- `getPage(id)` on missing id returns `error.PageNotFound`.
- `deletePage(id)` removes row, returns `true`. On missing id, returns `false`.
- `updatePageHtml(id, html)` replaces html, bumps `updated_at`.
- `reorderPages(ordered_ids)` rewrites positions.
- `renamePage(id, new_name)` updates name; rejects duplicate with `error.DuplicatePageName`.

Plus `src/ai_workflow/tui/migration_055_test.zig`:
- Schema check: `pragma_table_info('design_pages')` shows 7 expected columns.
- Forward migration replays cleanly on fresh in-memory DB.

### Zig static-contract handler tests (`src/ai_workflow/tui/http_handlers/design_*_test.zig`)

5 small files, ~50 lines each, grepping handler source for required substrings:
- `design_items_create_test.zig`
- `design_pages_list_test.zig`
- `design_pages_get_test.zig`
- `design_pages_update_test.zig`
- `design_pages_delete_test.zig`

Each follows the pattern in `src/ai_workflow/tui/http_handlers/kanban_columns_*_test.zig` (test name = contract, error name = violation, registered in `test_runner.zig`).

### Frontend unit tests (`src/apps/desktop/src/__tests__/design*.spec.ts`)

3 small files, Vitest:
- `apiDesign.spec.ts` — `api.createDesign`, `api.listDesignPages`, etc. Uses `apiFetch-mock-must-include-text-and-pinia` pattern (text() + Pinia setup).
- `addDesignDialog.spec.ts` — modal open/close, name validation, emits `create(name)`.
- `designViewIframe.spec.ts` — tab strip render, `srcDoc` binding, sandbox attribute `"allow-scripts"`, active-page switching.

### End-to-end smoke test (`scripts/design-mode-smoke.sh`)

Bash script that:
1. Boots `nalar` on port 8089 against an isolated `HOME`.
2. POSTs `/api/workspaces/<ws>/items/design`, asserts 201 + `item_id`.
3. PUTs a page with `{html:"<!doctype html><h1>Hi</h1>"}` to `.../design/pages/<page_id>`, asserts 200.
4. GETs the page list, asserts the page appears.
5. GETs the single page, asserts HTML matches.
6. DELETEs the page, asserts `{deleted:true}`.
7. GETs the page list again, asserts empty.

Wired into `scripts/ci-smoke-test.sh` as Step 6 (after existing 5 steps).

## Implementation order (chunks)

This is the order in which the writing-plans skill should produce the chunked implementation plan. Each chunk is independently testable and reviewable.

1. **Migration + model layer** — Migration 055 + `design_model.zig` + `design_model_test.zig` + `migration_055_test.zig`. Zig-only, no HTTP, no UI.
2. **HTTP handlers + SSE events** — 5 handlers + `on_event_sent_design.zig` + `on_event_design.zig` + their static-contract tests. Backend-complete.
3. **LLM tools** — `src/modules/agent/tools/design_tools.zig` + registry wiring + tool static tests.
4. **Frontend API + types** — `src/apps/desktop/src/api/index.ts` (5 new endpoints) + `src/apps/desktop/src/stores/workspaces.ts` (`addDesignItem`, type additions).
5. **AddDesignDialog + sidebar wiring** — new `AddDesignDialog.vue` + Sidebar/WorkspaceList dropdown wiring + tests.
6. **DesignView component** — new `DesignView.vue` + tab strip + iframe + SSE subscriptions + tests.
7. **AppLayout routing** — mount `<DesignView>` next to `<ChatView>` for design items.
8. **Smoke test** — `scripts/design-mode-smoke.sh` wired into `ci-smoke-test.sh`.

Each chunk ends with: `zig build test --summary all` passing, frontend `bun run build` clean, no regressions vs the baseline.

## Open questions (deferred)

These were considered and parked for future iterations:

- **Multi-page export** — download a design as a static site (zip of HTML files). Out of scope for v1.
- **HTML sanitizer** — DOMPurify integration if sandbox is insufficient. Not needed yet.
- **iframe → parent postMessage channel** — runtime error reporting. v1: DevTools is enough.
- **Page-level permissions** — share a single design page with a teammate. Out of scope.
- **Page templates** — start from a "blank" / "tailwind" / "bootstrap" template. The "+ Add Page" UX could grow this in v2.
- **Visual edit mode** — WYSIWYG contenteditable overlay (option C in Q2). Architecture keeps the door open.