# Design Mode Redesign — Design Document

**Date:** 2026-07-08
**Status:** Approved (user confirmed decisions 1, 2, 3 on 2026-07-08)
**Branch:** `worktree/design-mode-redesign` (worktree at `.worktrees/design-mode-redesign`)
**Supersedes:** `docs/plans/2026-07-05-design-mode-design.md`, `docs/superpowers/plans/2026-07-06-design-fs-rewrite.md`
**Companion implementation plan:** `docs/superpowers/plans/2026-07-08-design-mode-redesign.md`

---

## 1. Goal

Replace the v5 design-mode implementation (panzoom canvas, 5 LLM tools, file-backed HTML with fragile file-sync) with a **Figma-lite design mode** that fixes two specific failures:

- **B. Canvas UX** — panzoom drag/resize is clunky, no layers panel, no properties panel.
- **C. LLM tool surface** — 5 granular tools are over-engineered; the LLM misuses them.

The redesign keeps the file-backed HTML model (the user explicitly wants `design_page_elements.file_path` to stay) but fixes the v5 file-backed risks (orphan files, partial-write corruption, path traversal). The new model adds Figma-lite canvas features (drag/resize + layers panel + properties panel) and collapses the LLM tools from 5 to 3.

---

## 2. Non-goals (explicitly out of scope)

- Real-time multiplayer / CRDT collaboration
- WebGL renderer (Vue 3 DOM is sufficient for ≤100 elements/frame)
- Vector pen tool, auto-layout (flexbox for nodes), components with variants
- Plugin system
- Multi-page export (zip)
- HTML sanitizer (DOMPurify) — revisit if sandbox proves insufficient
- iframe→parent `postMessage` runtime error channel
- Page-level permissions
- Page templates (blank / tailwind / bootstrap)

These remain on the deferred-items list from the original design doc. None of them block the redesign.

---

## 3. Background — why the redesign

The v5 ship on `feature/design-mode` (`11e44746`) has **40+ files**, **all 8 implementation chunks**, and **2 post-merge bug fixes**. Despite the scope, two specific failures make it not production-ready:

### B. Canvas UX is broken
- **panzoom** for canvas pan/zoom has visual jitter (especially on Chrome)
- **drag handles** on every element's 4 corners + rotation handle conflict with iframe scroll
- **no layers panel** — users with >5 elements can't find anything
- **no properties panel** — to change `fill` or `width` you must edit SQL via a script

### C. LLM tool surface is broken
- 5 tools (`set_design_page`, `set_design_element`, `move_design_element`, `list_design_elements`, `delete_design_element`) is too granular
- The LLM picks the wrong tool (e.g. uses `set_design_element` to "rename" instead of `set_design_page`)
- No single tool returns the FULL element state — the LLM must chain 2-3 calls to learn what's on a page

### v5 file-backed risks (carried into v6, but fixed)
- Orphan files when an element row is deleted (the file stays)
- Partial-write corruption on crash (`writeStreamingAll` doesn't fsync)
- Page rename leaves the old folder dangling (no atomic rename)
- `workspace_item.path = NULL` crashes the file logic
- No path-traversal protection (a malicious `name` could `..` out of the design folder)

---

## 4. User experience

### What the user does

1. **Create a design item** via `AddDesignDialog` (name + project-root path picker, mirroring kanban). The path is required so design elements can be stored as files on disk relative to a stable root.

2. **Open the design** from the sidebar → main content area renders `<DesignView>`.

3. **See the page tabs** at the top of the canvas (e.g. `Home | Login | Dashboard`). Click a tab to switch.

4. **See the elements** in the active page rendered as positioned rectangles (each containing a sandboxed `<iframe>` rendering its HTML body).

5. **Click an element** → it gets a violet outline (selection state), and the right sidebar populates with:
   - **Layers panel** at top — tree of all elements on the page (drag to reorder z-index, click to select)
   - **Properties panel** below — form fields for: name, type, x/y/width/height/rotation, fill, stroke, corner_radius, opacity, text_content (if text), text_style (if text), image_url (if image), HTML content (Monaco editor in a collapsed accordion)

6. **Drag an element** (on the body, not the corner handles) to move it. Live update of x/y in the properties panel.

7. **Drag a corner/edge handle** to resize. Live update of width/height.

8. **Edit HTML** in two ways:
   - **Inline** — the element's iframe has `contenteditable=true` on its body; user types directly. On blur, the HTML is read back and saved to the file atomically.
   - **Source** — the properties panel has a "Content" tab with a Monaco editor showing the full HTML. Changes save on Cmd+S or auto-save (1s debounce).

9. **Change fill/stroke/radius/opacity/rotation** in the properties panel. Live update on the element.

10. **Reorder z-index** by dragging in the layers panel or using ↑/↓ buttons.

11. **Delete** an element via the properties panel's "Delete" button or right-click context menu (with confirm).

12. **Add a new element** via the canvas header's `+` button → opens a small dialog (`type`, `name`, `initial HTML`) → creates the row + writes the file.

13. **Ask the LLM** to design something via chat (e.g. "add a login card to the home page"). The LLM calls the design tools.

### What the LLM does

The LLM has 3 tools (see §6) to manage a design:

```
1. set_design_page(item_id, page_name, width?, height?)
   → Creates or updates a page; returns page metadata + ALL existing elements
     on that page (with all property summaries, NOT the full HTML).

2. add_element(page_id, name, type, html, x?, y?, width?, height?,
               fill?, rotation?, corner_radius?, opacity?)
   → Creates a new element with initial HTML; returns full element state.

3. update_element(element_id, name?, type?, html?, x?, y?, width?,
                  height?, rotation?, fill?, stroke?, stroke_width?,
                  corner_radius?, opacity?, text_content?, text_style?,
                  image_url?)
   → Updates any subset of fields; returns full updated element.
   → If `html` is provided, also rewrites the file atomically
     (write-temp + fsync + rename to file_path).
```

For deletion, the LLM guides the user to use the UI (no `delete_element` tool in the 3-tool surface). If a 4th delete tool is needed, we can add it as a follow-up — it's not blocking.

---

## 5. Data model

### 5.1 Schema (v6)

**`design_pages` — UNCHANGED from v5 (Migration 056)**

```sql
CREATE TABLE design_pages (
    id TEXT PRIMARY KEY,
    workspace_item_id TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    width INTEGER NOT NULL DEFAULT 1440,
    height INTEGER NOT NULL DEFAULT 1024,
    x INTEGER NOT NULL DEFAULT 0,
    y INTEGER NOT NULL DEFAULT 0,
    position INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
);
```

**`design_page_elements` — v5 columns KEPT + new columns ADDED (Migration 057)**

```sql
-- Migration 057 — additive, idempotent (safe for users on v5 already)
ALTER TABLE design_page_elements
    ADD COLUMN type TEXT NOT NULL DEFAULT 'rectangle',
    ADD COLUMN rotation REAL NOT NULL DEFAULT 0,
    ADD COLUMN fill TEXT NOT NULL DEFAULT '',
    ADD COLUMN stroke TEXT NOT NULL DEFAULT '',
    ADD COLUMN stroke_width INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN corner_radius INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN opacity REAL NOT NULL DEFAULT 1.0,
    ADD COLUMN text_content TEXT NOT NULL DEFAULT '',
    ADD COLUMN text_style TEXT NOT NULL DEFAULT '',
    ADD COLUMN image_url TEXT NOT NULL DEFAULT '',
    ADD COLUMN parent_id TEXT,
    ADD FOREIGN KEY (parent_id) REFERENCES design_page_elements(id) ON DELETE SET NULL;
```

The `file_path` column from v5 **stays** — the user wants file-backed HTML. v5 risks are fixed in v6 code, not by dropping the column.

### 5.2 Element types

| `type` | Rendered as | Special fields |
|---|---|---|
| `rectangle` | `<div>` with `background-color: fill` | `corner_radius`, `fill`, `stroke`, `opacity`, `rotation` |
| `ellipse` | `<div>` with `border-radius: 50%` | `fill`, `stroke`, `opacity`, `rotation` |
| `text` | `<div contenteditable>` with `text_content` | `text_style` (JSON: font, size, weight, color, align) |
| `image` | `<img>` | `image_url`, `corner_radius` |
| `frame` | `<div>` (group container, can contain other elements via `parent_id`) | `fill`, `corner_radius` |
| `group` | `<div>` (logical group, no visual chrome) | (none) |

### 5.3 File layout on disk

For each design item with `path = /home/user/projects/foo`:
```
/home/user/projects/foo/.nalar/design/
└── <page-name-sanitized>/
    └── <element-name-sanitized>.html
```

- Page folder is created on page create.
- Element HTML file is created on element create.
- File contains the element's `html` body (just the HTML, not a full document).
- Filenames are sanitized (`/` → `_`, `..` → `_`, etc.) via the existing `sanitizeFilename` helper.
- On element delete: `unlink(file_path)` AFTER the SQL DELETE succeeds (defer-pattern).
- On page rename: `renameat2` old folder to new (atomic).
- On page delete: `rm -rf <folder>` AFTER SQL CASCADE completes.

### 5.4 v5 → v6 data migration (Migration 057)

For users already on v5 (which has 0-3 pages, 0-1 element per page):
- All v5 columns stay (Migration 057 only adds).
- New columns get sensible defaults: `type='rectangle'`, `rotation=0`, `fill=''`, etc.
- The one existing v5 element (`elem_1783529985659722756`) auto-classifies as `type='rectangle'` with empty fill (the iframe renders the HTML body).
- No data loss.

---

## 6. LLM tool surface (3 tools)

All three return XML (matching the project convention; cf. `kanban_list` tool).

### 6.1 `set_design_page`

```json
{
  "item_id": "item_xxx (required, design workspace item)",
  "page_name": "Login (required)",
  "width": 1440 (optional, default 1440),
  "height": 1024 (optional, default 1024)
}
```

Behavior:
- `INSERT INTO design_pages (...) VALUES (...) ON CONFLICT(workspace_item_id, name) DO UPDATE SET width=excluded.width, height=excluded.height, updated_at=datetime('now')`.
- On insert/update, create the page folder if it doesn't exist (`<workspace_item.path>/.nalar/design/<sanitized_page_name>/`).
- Return: `<page>...all elements on this page (no html)...</page>` for LLM to discover existing state.

```xml
<page id="page_xxx" name="Login" width="1440" height="1024" position="2">
  <element id="elem_yyy" name="login-card" type="rectangle" x="100" y="200" width="400" height="300" fill="..." rotation="0" />
  <element id="elem_zzz" name="login-button" type="rectangle" x="120" y="520" width="120" height="40" fill="#22c55e" />
</page>
```

Errors:
- `<error>design item has no path; set one via AddDesignDialog</error>` if `workspace_items.path IS NULL`.
- `<error>page name must not contain '/' or null bytes</error>` for bad names.

### 6.2 `add_element`

```json
{
  "page_id": "page_xxx (required)",
  "name": "login-card (required, must be unique within page)",
  "type": "rectangle (required: rectangle|ellipse|text|image|frame|group)",
  "html": "<div>...</div> (required)",
  "x": 0 (optional, default 0),
  "y": 0 (optional, default 0),
  "width": 200 (optional, default 200),
  "height": 100 (optional, default 100),
  "fill": "#ffffff (optional, default '')",
  "rotation": 0 (optional, default 0),
  "corner_radius": 0 (optional, default 0),
  "opacity": 1.0 (optional, default 1.0),
  "text_content": "Login (optional, for type=text)",
  "text_style": "{\"font\":\"Inter\",\"size\":14} (optional, JSON)",
  "image_url": "https://... (optional, for type=image)"
}
```

Behavior:
- INSERT a new row.
- Write `html` to `<workspace_item.path>/.nalar/design/<sanitized_page_name>/<sanitized_element_name>.html` atomically (write to `.tmp` file, fsync, rename).
- Store the absolute path in `file_path` column.
- Emit SSE `design_element_created`.

```xml
<element id="elem_xxx" page_id="page_xxx" name="login-card" type="rectangle"
         x="0" y="0" width="200" height="100" fill="#ffffff" rotation="0"
         corner_radius="0" opacity="1.0" file_path="/abs/path/to/.html"
         created_at="..." updated_at="..." />
```

Errors:
- `<error>name must be unique within page; 'login-card' already exists</error>` for duplicates.
- `<error>type must be one of: rectangle, ellipse, text, image, frame, group</error>` for bad type.
- `<error>name must not contain '/' or null bytes</error>` for bad name.

### 6.3 `update_element`

```json
{
  "element_id": "elem_xxx (required)",
  "name": "new-name (optional)",
  "type": "rectangle (optional)",
  "html": "<div>...</div> (optional, triggers atomic file rewrite)",
  "x": 100 (optional), "y": 200 (optional),
  "width": 400 (optional), "height": 300 (optional),
  "rotation": 15 (optional), "fill": "#22c55e" (optional),
  "stroke": "#000000" (optional), "stroke_width": 1 (optional),
  "corner_radius": 8 (optional), "opacity": 0.8 (optional),
  "text_content": "Hello (optional)",
  "text_style": "{\"font\":\"Inter\",\"size\":14}" (optional),
  "image_url": "https://..." (optional)
}
```

Behavior:
- UPDATE the row with the provided fields (UPDATE...SET...WHERE id=?). Only changed fields are SET.
- If `html` is provided, rewrite the file at `file_path` atomically. If the file doesn't exist (orphan), recreate it.
- If `name` changes AND the new name would produce a different sanitized filename, also rename the file.
- Emit SSE `design_element_updated`.

Returns the full updated element (same shape as `add_element`).

### 6.4 No `list_elements` tool

The LLM discovers elements by calling `set_design_page(item_id, page_name)` — it returns the page with all elements. This keeps the surface at 3 tools. Trade-off: `set_design_page` has dual semantics (create/update + list) — the description text must make this clear.

### 6.5 No `delete_element` tool

The LLM guides the user to delete via the UI. If needed as a follow-up, add a 4th tool `delete_element(element_id)`. Not blocking v6.

---

## 7. HTTP API surface

### 7.1 REST endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/workspaces/:wid/items/:iid/design/pages` | List all pages on a design item (summaries) |
| `POST` | `/api/workspaces/:wid/items/:iid/design/pages` | Create a page (delegates to LLM tool's idempotent insert) |
| `GET` | `/api/workspaces/:wid/items/:iid/design/pages/:pid` | Get a page (with all elements, excluding HTML) |
| `POST` | `/api/workspaces/:wid/items/:iid/design/pages/:pid/elements` | Add an element (matches `add_element` tool) |
| `PUT` | `/api/workspaces/:wid/items/:iid/design/pages/:pid/elements/:eid` | Update an element (matches `update_element` tool) |
| `DELETE` | `/api/workspaces/:wid/items/:iid/design/pages/:pid/elements/:eid` | Delete an element (UI only — no LLM tool calls this) |
| `GET` | `/api/workspaces/:wid/items/:iid/design/pages/:pid/elements/:eid/html` | Get the element's full HTML (lazy-loaded) |
| `PATCH` | `/api/workspaces/:wid/items/:iid/design/pages/:pid/elements/:eid/html` | Update the element's HTML atomically (used by iframe contenteditable + Monaco) |
| `PATCH` | `/api/workspaces/:wid/items/:iid/design/pages/:pid/elements/:eid/geometry` | Update x/y/width/height/rotation (used by drag/resize) |

(Reuses the existing `POST /items/design` from v5 — that handler stays unchanged.)

### 7.2 Wire format conventions

- Request body: `std.json.parseFromSliceLeaky(MyBody, allocator, body, .{})` (per project memory).
- Response body: `std.json.Stringify.valueAlloc(allocator, MyResponse{...}, .{})` (per project memory).
- Error: `http_response.makeErrorResponse(allocator, .{ .@"error" = "..." })` returns `{"error":"..."}`.

### 7.3 Handler pattern (mirrors kanban)

```zig
pub fn designElementsCreateHandler(ctx, req, res) !HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const db = di.db;

    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) return res.jsonResponse(.{ .status_code = 400, ... });

    const parsed = std.json.parseFromSliceLeaky(CreateElementBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }) });
    };

    const result = design_model.addElement(allocator, db, .{...}) catch |err| {
        const (status, message) = switch (err) {
            error.DuplicateName => .{ 409, "name must be unique within page" },
            error.InvalidType => .{ 400, "type must be one of..." },
            error.ItemPathMissing => .{ 400, "design item must have a path" },
            else => .{ 500, @errorName(err) },
        };
        return res.jsonResponse(.{ .status_code = status, ... });
    };

    return res.jsonResponse(.{ .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(allocator,
            http_response.makeDesignElementResponse(result.element), .{}) });
}
```

---

## 8. SSE events

Three event names (matching the v5 set, kept):

| Wire event name | Routing key | Payload type | Emitted by |
|---|---|---|---|
| `design_element_created` | `design_element` | `DesignElementCreatedData` | `addElement` |
| `design_element_updated` | `design_element` | `DesignElementUpdatedData` | `updateElement`, contenteditable/Monaco save |
| `design_element_deleted` | `design_element` | `DesignElementDeletedData` | `deleteElement` (UI only) |

Payload shape (matches v5):
```zig
pub const DesignElementCreatedData = struct {
    action: []const u8,    // "created"
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
};
```

Frontend listener (in `DesignView.vue`):
```ts
bus.on('design_element', (event) => {
    if (event.workspace_id !== activeWorkspaceId.value) return
    if (event.item_id !== activeItemId.value) return
    void workspacesStore.fetchDesignElements(event.workspace_id, event.item_id, event.page_id)
})
```

(Re-register on every bus reconnect; mirrors the v5 `kanbanSse.ts` pattern.)

---

## 9. Frontend architecture

### 9.1 New Vue components

| Component | Lines (est) | Purpose |
|---|---|---|
| `DesignView.vue` (rewrite) | ~600 | Top-level: page tabs, canvas, layers+properties panel split |
| `DesignElement.vue` (new) | ~250 | Single element renderer: position, drag handles, resize handles, click-to-select |
| `DesignPageTabs.vue` (new) | ~100 | Tab strip at top of canvas, `+` button to add page |
| `LayersPanel.vue` (new) | ~200 | Right sidebar top: tree of elements, drag to reorder z-index, click to select |
| `PropertiesPanel.vue` (new) | ~400 | Right sidebar bottom: form for selected element's properties |
| `DesignElementPreview.vue` (new) | ~80 | Sandboxed iframe that renders an element's HTML body |
| `DesignElementEditor.vue` (new) | ~150 | Monaco editor for the HTML source (collapsed accordion in properties panel) |

### 9.2 Existing components (kept unchanged from v5)

- `AddDesignDialog.vue` — same shape, same props
- `AppLayout.vue` — minor edit: add `v-else-if="activeWorkspaceItem.item_type === 'design'"` branch (mirrors kanban's existing branch)
- `WorkspaceItem.vue` — add `v-else-if="item.item_type !== 'design'"` discriminator in template (mirrors the kanban exclusion)

### 9.3 Stores (rewrite)

- `workspaces.ts`:
  - Add `design_elements?: DesignElement[]` field to `WorkspaceItem` (OPTIONAL — required for backwards compat with 8+ test files)
  - Replace `addDesignItem` (no change to signature), add `fetchDesignElements`, `addDesignElement`, `updateDesignElement`, `deleteDesignElement`
- `designSse.ts` (new file, ~150 lines): mirror `kanbanSse.ts` — subscribes to `design_element` events on the bus, dispatches to `workspacesStore.fetchDesignElements`

### 9.4 API layer (rewrite)

- Add 9 new API functions in `src/api/index.ts`:
  - `listDesignPages(workspaceId, itemId)`
  - `createDesignPage(workspaceId, itemId, name)`
  - `getDesignPage(workspaceId, itemId, pageId)`
  - `addDesignElement(workspaceId, itemId, pageId, body)`
  - `updateDesignElement(workspaceId, itemId, pageId, elementId, patch)`
  - `deleteDesignElement(workspaceId, itemId, pageId, elementId)`
  - `getDesignElementHtml(workspaceId, itemId, pageId, elementId)`
  - `updateDesignElementHtml(workspaceId, itemId, pageId, elementId, html)`
  - `updateDesignElementGeometry(workspaceId, itemId, pageId, elementId, geometry)`
- Add `DesignPage`, `DesignElement`, `DesignElementEvent` interfaces
- Add `'design_element'` to `additionalEventTypes` in `createUnifiedSseConnection`
- Add `design?: (event) => void` channel to `UnifiedChannels`

### 9.5 Bus updates

- `src/helpers/sseBus.ts`:
  - Add `design: DesignElementEvent | DesignPageEvent` to `SseEventMap`
  - Add `design: new Set<Listener<'design'>>()` to listeners map
  - Add `design: (e) => dispatch('design', e)` to global client channels

### 9.6 Visual conventions (from kanban)

- All colors via CSS variables (`var(--semantic-*)`, `var(--color-*)`)
- Fixed-width sidebar (280px) for layers+properties; main canvas takes the rest
- Drag affordances: `outline: 2px solid var(--color-violet); outline-offset: -2px`
- Element selection: same violet outline
- Empty states: centered text in `var(--semantic-text-dim)`
- `data-testid="design-{purpose}-..."` everywhere

---

## 10. What we're keeping from v5 (don't rewrite)

- **Migration 055 + 056** — both stay. Migration 057 is purely additive.
- **`workspace_items.item_type = 'design'`** — already wired.
- **`isTaskDesign` helper** in `llm_history.zig` — used by `workflow.zig` to skip session-name generator.
- **`BuildDesignCanvasPrompt`** in `build_messages_for_agent_prompt.zig` — extend to mention the 3 tools.
- **`AddDesignDialog.vue`** — unchanged.
- **`POST /items/design`** HTTP handler — unchanged.
- **`scripts/design-mode-smoke.sh`** — extend with element CRUD assertions.
- **SSE bus infrastructure** — `sseClient.ts`, `sseBus.ts` — extend with `design` channel only.

---

## 11. What we're deleting from v5 (full rewrite)

- `src/ai_workflow/tui/design_model.zig` — replace with v6 (focused on page + element CRUD; drop `addElementOfType` etc. helpers, use the 3-tool's actual needs)
- `src/ai_workflow/tui/design_model_test.zig` — replace with v6 tests
- `src/ai_workflow/tui/on_event_design.zig` — replace (drop `design_page_updated/deleted`, keep only the 3 element events)
- `src/ai_workflow/tui/on_event_sent_design.zig` — replace
- `src/ai_workflow/tui/on_event_sent_design_test.zig` — replace
- 12 HTTP handlers + 12 tests (v5 had 5 page + 7 element handlers) — replace with the 9 v6 endpoints
- 5 LLM tools + 5 tests (`design_pages.zig`, `design_page_elements.zig`, `design_page_elements_move.zig`, `design_page_elements_list.zig`, `design_page_elements_delete.zig`) — replace with 3 tools + 3 tests
- `src/apps/desktop/src/components/DesignView.vue` — full rewrite (was panzoom-based; now Figma-lite)
- `src/apps/desktop/src/__tests__/DesignView.spec.ts` — replace
- `src/apps/desktop/src/__tests__/stubs/panzoom.ts` — DELETE (panzoom no longer used)
- `vitest.config.ts` reference to panzoom stub — DELETE
- `src/apps/desktop/src/__tests__/apiDesign.spec.ts` — replace (new API surface)

Total: **~35 files deleted**, **~22 files created/modified**, **net +200-400 LOC** in production code, **+800-1200 LOC** in tests.

---

## 12. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `workspace_item.path = NULL` blocks element creation | High (user can clear path) | Handler returns 400 with explicit error message |
| Atomic file write fails on power loss | Low | Write to `.tmp`, `fsync(2)`, `renameat2(2)` — per the project memory `zig-0.16-file-append-must-use-writePositionalAll.md` |
| Path traversal (`name="../../etc/passwd"`) | Medium (LLM could generate it) | `sanitizeFilename` strips `/`, `\`, `..`, leading dots; reject if result differs from input |
| Orphan files after element delete | Medium (if delete fails mid-flight) | Defer file unlink AFTER SQL DELETE succeeds; log unlink failures |
| Page rename leaves dangling folder | Medium | Atomic `renameat2(2)` of the entire folder after SQL UPDATE |
| contenteditable iframe quirks (browser diffs) | Medium | Acceptable for v6; revisit in Tier 3 |
| Monaco bundle size (~5 MB) | Low | Lazy-load Monaco only when the "Content" tab is expanded |
| LLM creates 100 elements on a page | Medium | No limit in v6 — relies on the user's discretion. Tier 2 limit: 100 elements/page (soft warning, not enforced). |

---

## 13. Open questions (none blocking)

1. **Should we add a 4th LLM tool for deletion?** — Pro: full LLM automation. Con: increases surface. Decision: defer; UI delete is sufficient for v6.
2. **What's the soft cap on elements per page?** — No cap for v6. Revisit when users hit performance issues.
3. **Should `set_design_page` be split into `create_page` + `get_page`?** — No, keeping it idempotent is more useful for the LLM.
4. **Should the iframe sandbox allow scripts?** — Yes, but only `sandbox="allow-scripts"` (not `allow-same-origin`). Revise if a use case demands it.

---

## 14. Out-of-scope follow-ups (for future plans)

1. Multi-page export (zip)
2. HTML sanitizer (DOMPurify)
3. iframe→parent `postMessage` for runtime error reporting
4. Page-level permissions
5. Page templates
6. Visual edit mode (contenteditable overlay) — *partially in scope for v6 via the iframe contenteditable; full WYSIWYG overlay is still Tier 3*
7. Real-time multiplayer / CRDT
8. WebGL renderer
9. Vector pen tool
10. Auto-layout (flexbox for nodes)
11. Component system with variants
12. Plugin system

---

## 15. Decision log (the 3 confirmed decisions)

1. **File-backed HTML**: Keep `design_page_elements.file_path` (the user explicitly confirmed). HTML lives in a file at `<workspace_item.path>/.nalar/design/<page_name>/<element_name>.html`. v5 file-backed risks fixed in v6 (atomic writes, orphan cleanup, path-traversal CHECK, atomic page-rename).

2. **Canvas interaction model = Tier 2 (Figma-lite)**: drag/resize + layers panel + properties panel. NO panzoom. NO multi-select (Tier 3). NO auto-layout (Tier 3). NO vector pen (Tier 3).

3. **LLM tool surface = 3 tools**: `set_design_page`, `add_element`, `update_element`. The 3rd tool returns the FULL element state so the LLM can verify its changes. No `delete_element` tool (UI-only deletion).

---

**End of design doc.** Next step: write the implementation plan to `docs/superpowers/plans/2026-07-08-design-mode-redesign.md`.
