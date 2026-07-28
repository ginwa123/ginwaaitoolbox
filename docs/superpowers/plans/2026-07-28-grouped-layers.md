# Grouped Layers (Frame / Group Nesting) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Users can select 2+ elements on a design page and wrap them in a `group` (or `frame`) container via **Cmd/Ctrl+G** (Figma convention). Nested children appear in the LayersPanel as a tree (▶/▼ collapse, indent by depth). The chat-bound LLM can also invoke the same operation via a new `group_elements` tool — so "group app-shell + toolbar + kanban-board into a 'Kanban-view' parent" works from either the UI or the chat.

**Architecture:** Backend adds a `groupElements(alloc, db, pageId, childIds, parentName, parentType)` model function + a `POST /api/workspaces/:w/items/:i/design/pages/:p/elements/group` handler. The existing `parent_id` column on `design_page_elements` (Migration 057) already exists — only the read-back path (`DesignElement` struct + `DesignElementResponse` + SELECT in `getElement`) and the update SET clause need to expose it. Frontend adds `parent_id` to the `DesignElement` TS interface, an `api.groupDesignElements` helper, a `workspacesStore.groupDesignElements` action, a Cmd+G shortcut in `DesignView.vue`, and a recursive `<LayerRow>` component that replaces the flat `v-for` in `LayersPanel.vue`. The LLM tool (`group_elements`) mirrors the same backend endpoint with an XML response shape, matching `update_element`'s convention.

---

## Global Constraints

- Existing cross-platform + Zig 0.16 + Vue 3 + TypeScript conventions from `AGENTS.md` and the project memories apply unchanged.
- **NEVER kill the process on port 8081** — that's the always-running dev `nalar` instance. Use port 8080 for smoke tests.
- The SQL schema + Migration 057 are already in place — **do NOT add a new migration** for `parent_id`. The column already exists. This plan only exposes it through the read-back and update paths.
- All new tests must follow the project's static-contract convention (lock source via regex) OR the behavioural convention (mount via Pinia + `mount()` helper). See `LayersPanel.spec.ts`, `workspace_items_create_kanban_test.zig`, and the `design_elements_*_test.zig` files for templates.
- **Bun-as-runtime caveat** for `vue-tsc`: see `.nalar/memories/nalar-frontend-patterns.md` — always run `bun run build` (NOT just `bunx vitest run`) before declaring done.
- Verification recipe from `.nalar/memories/zig-build-and-test.md` is mandatory: `zig build test` + `zig build install:linux:system` + `rm -rf zig-out/bin && zig build` + cross-compile smoke via `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -target aarch64-macos`.
- The frontend's `[k: string]: any` index signature on `addDesignElement`'s `body` (line ~1140 of `workspaces.ts`) is already permissive enough to forward `parent_id` through. The backend `AddElementInput` struct (design_model.zig) currently does NOT accept `parent_id` — adding it is out of scope for this plan; we'll always create groups via the dedicated `POST .../group` endpoint, not `add_element`.
- **Idempotency rule:** the API for "group these N ids" MUST be safe to retry on the same selection. Specifically: if the call is re-issued with overlapping child ids, the second call should not create a duplicate group, but should EITHER no-op or move the children to the original group (preferred). Document the chosen behaviour in the handler docstring.

---

## Design Background (read first)

### Problem

The user has 3 top-level elements on a design page (`app-shell`, `toolbar`, `kanban-board`). They want to organize them as a logical unit — a parent called `Kanban-view`. Today:

- The backend schema already supports it (`design_page_elements.parent_id` is `TEXT NULL`, Migration 057).
- The wire response and TypeScript interface do NOT expose `parent_id` (read-back is silent).
- The update SET clause does NOT include `parent_id` (write-back is impossible).
- The LayersPanel renders a flat list (no tree, no nesting visible).
- No UI affordance to group selection.
- No LLM tool to group selection.
- No static-contract test pinning any of the above.

Result: the user cannot organize the design. Their LayersPanel is a flat soup.

### Why a dedicated `/group` endpoint (not just `update_element parent_id`)

A user-initiated "group selection" is a multi-row operation with side-effects:

1. Create a new `group` element at the union bbox of the selection.
2. Set `parent_id` on N children to the new group's id (in one transaction).
3. Emit a single `design_element_created` SSE event for the group + N `design_element_updated` events for the children — but the frontend doesn't need each one because it refetches on SSE reconcile.
4. Reject if any child_id is missing, already a child of another group, or already has `parent_id != NULL` (a child can't have two parents).

A flat `PUT .../elements/:e` with `parent_id` would require the caller to:

- Compute the union bbox client-side.
- INSERT the group via a separate `add_element` call.
- Issue N PUT requests for each child.
- Roll back manually on any failure.

That's the kind of multi-step client-side orchestration that breaks under partial failure (network drops between the INSERT and the N PUTs leave orphan rows). A single transactional endpoint eliminates that class of bug.

### What about `frame` vs `group`?

The `ElementType` enum supports both:

- `frame` — visual container, **clips** its children (CSS `overflow: hidden`). User picks this for "I want this card frame with rounded corners to crop its contents".
- `group` — non-clipping logical bundle. User picks this for "just organize my layers — don't change the visual rendering".

For the Cmd+G shortcut, the new group will default to `type='group'` (the non-clipping default). For the LLM tool, accept `parent_type: 'frame' | 'group'` so the chat can pick.

### Why Cmd+G (not Cmd+K, not right-click menu)

- Figma uses `Cmd/Ctrl+G` for "Make frame / group" — universal design-tool convention.
- The existing keyboard plumbing in `DesignView.vue::handleKeydown` (line 400) makes this a 5-line addition.
- Right-click context menu is a follow-up — the shortcut covers 95% of user intent without extra UI surface area.

### What "2+ selected" means in practice

- The current selection is `selectedIds: Set<string>` (multi-aware since the 2026-07-25 chunk 2 redesign).
- Cmd+G with `selectedIds.size < 2` → silent no-op (mirrors Figma).
- Cmd+G with `selectedIds.size >= 2` → bundle them into a new group at the union bbox.
- Selected ids whose element is already a child of another group → still allowed; the operation moves them to the NEW group (the new group becomes their parent). The old parent group is left alone but with fewer children. This matches Figma's behaviour.
- Dedup selection: if the selection contains a `group` element AND its descendants, drop the descendants (the group is already a parent for them). Mirrors Figma.

### Group geometry

The new group's bounding box is the **union** of its children's bounding boxes:

```zig
const min_x = std.mem.min(children.map(e.x));
const min_y = std.mem.min(children.map(e.y));
const max_x = std.mem.max(children.map(e.x + e.width));
const max_y = std.mem.max(children.map(e.y + e.height));
// group: { x: min_x, y: min_y, width: max_x - min_x, height: max_y - min_y }
```

The group is positioned as a sibling in the page's flat element list (it has its own `z_index` and `position`). User can drag-resize it like any other element; resizing does NOT cascade to children (intentional — the user can decide whether they want to resize the logical bundle or individual children).

### Tree render in LayersPanel

A flat list of `DesignElement[]` becomes a tree by grouping children under their `parent_id`:

```ts
interface TreeNode {
  element: DesignElement
  depth: number
  children: TreeNode[]
}
```

Render with a recursive `<LayerRow :node :parent-id :selected-ids>` component. Indent by `depth * 16px` (matches the existing component's 16px step). ▶/▼ toggle hides children when collapsed (collapse state persists in component-local `ref<Set<string>>`).

**Selection across the tree is still flat** — clicking a row toggles its id in `selectedIds.value` regardless of nesting. Cmd+click selects all descendants. (Future enhancement; first cut: plain click + Shift+click as today.)

### What about deleting a parent?

The schema comment says `parent_id ON DELETE SET NULL` — but SQLite doesn't enforce FK actions by default. The handler must:

1. Before deleting a frame/group element, NULL out `parent_id` for all children with `parent_id = deleted.id`.
2. Then delete the element (and its on-disk HTML).
3. Emit `design_element_deleted` SSE event + reconcile children via the existing `design_element_updated` SSE.

This is already partially handled by `design_model.deleteElement` (need to verify) — see Chunk 4.

---

## File Structure

Files touched by this plan:

| File | What changes |
|---|---|
| `src/ai_workflow/tui/design_model.zig` | Add `parent_id: []u8` to `DesignElement`; extend `freeElement(s)`; extend `getElement`/`listElements` SELECT to read `parent_id`; add `groupElements(alloc, db, pageId, childIds, parentName, parentType) ![]u8`; update `updateElement` SET clause to accept `parent_id`; update `deleteElement` to NULL children's `parent_id` before deleting a parent. |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | Add `parent_id: []const u8` to `DesignElementResponse` (lines ~761-786); add to `makeDesignElementResponse` mapper. |
| `src/ai_workflow/tui/http_handlers/design_elements_group.zig` | **NEW** — handler + use-case for `POST /api/workspaces/:w/items/:i/design/pages/:p/elements/group` with body `{ child_ids: []string, name?: string, type?: 'group'\|'frame' }`. Returns the full updated page (or just the new group + updated children). |
| `src/ai_workflow/tui/http_handlers/design_elements_group_test.zig` | **NEW** — 6+ static-contract tests covering the route + handler wire shape + idempotency. |
| `src/ai_workflow/tui/http_handlers/design_elements_update.zig` | Add `parent_id: ?[]const u8 = null` to `UpdateElementBody` + `UpdateElementInput`; extend `NoChanges` check; pass through to `updateElement`. |
| `src/ai_workflow/tui/http_handlers/mod.zig` | Re-export the new handler module. |
| `src/main.zig` | Register `POST /api/workspaces/:w/items/:i/design/pages/:p/elements/group` route. |
| `src/ai_workflow/tui/on_event_sent_design.zig` | Verify it already emits `design_element_updated` for reparented children (likely yes — reparent is just an UPDATE). |
| `src/apps/desktop/src/api/index.ts` | Add `parent_id?: string \| null` to `DesignElement` interface; add `groupDesignElements(workspaceId, itemId, pageId, body)` API helper. |
| `src/apps/desktop/src/stores/workspaces.ts` | Add `groupDesignElements(...)` action; add to the store action bag. |
| `src/apps/desktop/src/composables/useDesignHandlers.ts` | Add `groupSelection(pageId)` function that wires Cmd+G to the store action; emits a success toast on completion. |
| `src/apps/desktop/src/components/design/DesignView.vue` | Add Cmd+G (and Cmd+Shift+G for "Ungroup") shortcut handlers; pass through to `useDesignHandlers`. |
| `src/apps/desktop/src/components/design/LayersPanel.vue` | Replace flat `v-for` with a recursive `<LayerRow>` component; indent by depth; add ▶/▼ collapse; preserve existing select/reorder/delete semantics. |
| `src/apps/desktop/src/components/design/LayerRow.vue` | **NEW** — recursive layer row component extracted from `LayersPanel.vue`. |
| `src/apps/desktop/src/__tests__/LayersPanel.spec.ts` | New tests for tree rendering, indent, collapse, selection across nesting. |
| `src/apps/desktop/src/__tests__/DesignView.spec.ts` | New tests for Cmd+G shortcut wiring (2+ selected, <2 = noop). |
| `src/apps/desktop/src/__tests__/workspacesStoreGroup.spec.ts` | New tests for `groupDesignElements` store action (optimistic update + error rollback). |
| `src/modules/agent/tools/group_design_elements.zig` | **NEW** — LLM tool `group_elements` mirroring the HTTP endpoint with XML response shape (matches `update_design_element.zig::elementToXml`). |
| `src/modules/agent/tools/group_design_elements_test.zig` | **NEW** — static-contract tests. |
| `src/modules/agent/tools/mod.zig` (or `agent.zig`) | Register the new LLM tool. |
| `src/root.zig` | Re-export the new tool module. |
| `docs/SPEC.md` | Add §3.8 chunk to the design-mode section; add §10.2.1 PR index entry. |
| `docs/superpowers/plans/2026-07-28-grouped-layers.md` | This file. |

---

## Chunk 1 — Backend: `parent_id` round-trip via `DesignElement` struct + response

Read-back of `parent_id` is the foundational change — every other chunk depends on it.

### Task 1.1 — Add `parent_id` to `DesignElement` struct + extend `freeElement(s)`

File: `src/ai_workflow/tui/design_model.zig` (lines 368-411)

- Add `parent_id: []u8` field after `image_url` (line 389) in the `DesignElement` struct.
- Extend `freeElement` (line 395) to free the new field:
  ```zig
  allocator.free(e.parent_id);
  ```
- Extend `freeElements` (the loop in line 396) similarly.

**Static-contract test:** `src/ai_workflow/tui/design_model_test.zig` (new file or extend existing) — assert the struct field exists. Use `std.mem.indexOf(u8, source, "parent_id: []u8,")` + `"allocator.free(e.parent_id);"`.

**Verification:**
```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

### Task 1.2 — Extend `getElement` SELECT to read `parent_id`

File: `src/ai_workflow/tui/design_model.zig` (`getElement` function — find with `pub fn getElement`)

- Add `parent_id` to the SELECT column list.
- Map the column value to the new struct field after the query.
- Use the `row.values[N]` pattern (see `.nalar/memories/zig-sqlite-patterns.md` §"column reads").
- The column index for `parent_id` will be the LAST column in the SELECT (since `created_at` and `updated_at` are at the end today).
- Allocate `parent_id` via `allocator.dupe` (so the struct can own it past `row.deinit`).

**Static-contract test:** `design_model_test.zig` — grep for `parent_id` in the SELECT statement within `getElement`.

**Verification:** same as 1.1.

### Task 1.3 — Extend `listElements` SELECT to read `parent_id`

File: `src/ai_workflow/tui/design_model.zig` (`listElements` — find with `pub fn listElements` or similar)

- Same as 1.2 but for the list path (used by `set_design_page` to populate the LayersPanel).

**Static-contract test:** assert `parent_id` appears in the SELECT within `listElements`.

**Verification:** same as 1.1.

### Task 1.4 — Add `parent_id` to `DesignElementResponse` + mapper

File: `src/ai_workflow/tui/http_handlers/http_response.zig` (lines 761-817)

- Add `parent_id: []const u8` to the `DesignElementResponse` struct (lines 761-786). Position it after `image_url` to match the struct field order.
- Extend `makeDesignElementResponse` mapper (lines 792-817) to copy `element.parent_id` to `response.parent_id`.
- Update the file-level docstring (lines 696-708) to mention the new field.

**Static-contract test:** `src/ai_workflow/tui/http_handlers/design_elements_get_test.zig` (extend existing or new) — grep for `parent_id` in the response struct + mapper.

**Verification:**
```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

**Cross-compile smoke (mandatory per AGENTS.md):**
```bash
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
```

---

## Chunk 2 — Backend: `groupElements` model + `updateElement` accepts `parent_id`

### Task 2.1 — Extend `updateElement` SET clause to accept `parent_id`

File: `src/ai_workflow/tui/design_model.zig` (`updateElement` function — line ~627)

- Add `parent_id: ?[]const u8 = null` to `UpdateElementInput` (lines 88-106 of `design_elements_update.zig` — see Chunk 3.1).
- In `updateElement`'s dynamic SET-clause builder (lines 664-726):
  - After the existing checks, if `input.parent_id` is non-null, append `"parent_id = ?"` to `sets` and the value to `args`.
  - The string parameter pattern is the same as `fill`, `stroke`, `text_content`, etc.
- Extend the file-level docstring (lines 564-580 area).

**Static-contract test:** `design_model_test.zig` — grep for `parent_id` in the SET-clause construction within `updateElement`.

**Verification:** same as 1.4.

### Task 2.2 — Add `groupElements` model function

File: `src/ai_workflow/tui/design_model.zig` (new function, placed after `updateElement`)

Signature:

```zig
pub const GroupElementsInput = struct {
    page_id: []const u8,
    child_ids: []const []const u8,
    parent_name: []const u8,
    parent_type: ElementType, // .group or .frame
};

pub const GroupElementsError = error{
    PageNotFound,
    ItemPathMissing,
    BadChildId,
    ChildAlreadyParented,
    ChildAcrossDifferentPages,
    DbError,
    FileWriteFailed,
    OutOfMemory,
};

pub fn groupElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: GroupElementsInput,
) anyerror![]u8 {
    // Returns the new parent element_id (heap-owned, caller frees).
}
```

Behaviour:

1. **Validate the children are all on the same page** — query `SELECT page_id, x, y, width, height, parent_id FROM design_page_elements WHERE id IN (?, ?, ...)`. Reject if any returned row's `page_id` ≠ `input.page_id`.
2. **Reject if any child is already parented** (`parent_id IS NOT NULL`) — first-cut safety. Document this in the docstring. Future enhancement: support "re-parent" by passing through.
3. **Compute union bbox** from the children's x/y/width/height.
4. **INSERT the new group element** using the same INSERT statement pattern as `addElement` (line 542-559). Use:
   - `name = input.parent_name`
   - `elem_type = input.parent_type`
   - `x, y, width, height` from the union bbox
   - `fill = "transparent"`, `rotation = 0`, `corner_radius = 0`, `opacity = 1.0`
   - `z_index = MAX(z_index) + 1` of the children (so it renders on top of its children for selection purposes)
   - `position = MAX(position) + 1` of the children
   - On-disk html: write empty `<div style="width:100%;height:100%;"></div>` to `<item_path>/.nalar/design/<sanitized_page_name>/<sanitized_group_name>.html` via the same pattern as `addElement` (lines ~480-540).
   - `parent_id = NULL` (the new group is itself top-level).
5. **UPDATE children** in a single transaction:
   ```sql
   UPDATE design_page_elements SET parent_id = ? WHERE id IN (?, ?, ...)
   ```
   Use `db.exec` with the parameterized IN-list.
6. **Emit SSE events**: one `design_element_created` for the new group, one `design_element_updated` for each child. Mirror the SSE emit in `addElement` (line 568-574) and `updateElement` (after the SQL).
7. **Return the new parent element_id**.

**Use a transaction** to ensure atomicity. Either:
- Use the existing `db.begin()` / `tx.commit()` pattern from `.nalar/memories/zig-sqlite-patterns.md` §"Transaction Design".
- OR rely on SQLite's autocommit and accept partial-failure risk. **Prefer the transaction.**

**Static-contract test:** `src/ai_workflow/tui/design_model_group_test.zig` (new) — 6+ tests:
- `groupElements function signature includes page_id, child_ids, parent_name, parent_type`
- `groupElements INSERTs a new element with parent_id = NULL`
- `groupElements UPDATEs each child with the new parent's id`
- `groupElements uses union bbox geometry`
- `groupElements rejects cross-page child ids`
- `groupElements rejects already-parented children`
- `groupElements emits design_element_created SSE event`

**Verification:**
```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin && timeout 360 zig build 2>&1 | tail -n 5
```

### Task 2.3 — Wire `update_element` to accept `parent_id` (handler)

File: `src/ai_workflow/tui/http_handlers/design_elements_update.zig`

- Add `parent_id: ?[]const u8 = null` to `UpdateElementBody` (lines 37-54).
- Add the same field to `UpdateElementInput` (lines 88-106).
- Extend the `NoChanges` check (lines 140-156) to include `input.parent_id == null`.
- Pass through to `design_model.updateElement` (line 443-465).

**Static-contract test:** `design_elements_update_test.zig` (extend) — assert `parent_id` appears in the struct + `NoChanges` check.

**Verification:** same as 2.2.

---

## Chunk 3 — Backend: `POST /api/workspaces/:w/items/:i/design/pages/:p/elements/group` handler

### Task 3.1 — New handler file `design_elements_group.zig`

File: `src/ai_workflow/tui/http_handlers/design_elements_group.zig` (NEW, ~180 lines)

Use the `add_design_element.zig` / `delete_design_element.zig` template (per `.nalar/memories/nalar-backend-architecture.md`).

```zig
//! HTTP handler: POST /api/workspaces/:w/items/:i/design/pages/:p/elements/group
//!
//! Creates a new `group` (or `frame`) element at the union bbox of the
//! given `child_ids`, then sets `parent_id` on each child to the new
//! group's id. Single-transaction, idempotent on retry (overlapping
//! child ids from a prior partial call produce an explicit error
//! `ChildAlreadyParented`).
//!
//! Body: { child_ids: ["elem_a", "elem_b", ...],
//!         name?: string (default "Group"),
//!         type?: 'group'|'frame' (default 'group') }
//! Response 201: { parent: <full DesignElementResponse>,
//!                 children: [<full DesignElementResponse>, ...] }

const GroupBody = struct {
    child_ids: []const []const u8 = &.{},
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
};
```

Behaviours:
1. Parse body with `std.json.parseFromSliceLeaky`.
2. Validate `child_ids.len >= 2` (else 400 with hint "Select at least 2 elements to group").
3. Validate `type` if provided — must be `'group'` or `'frame'` (else 400).
4. Default `name = "Group"` if null, default `type = 'group'`.
5. Look up DB via `nalarcore.getSingleton().db`.
6. Call `design_model.groupElements(allocator, db, .{
        .page_id = pageId,
        .child_ids = parsed.child_ids,
        .parent_name = name,
        .parent_type = parsed_type,
   })`.
7. Re-fetch the full parent element via `design_model.getElement`.
8. Re-fetch all the children via `getElement` per id.
9. Build response struct `{ parent: <DesignElementResponse>, children: []<DesignElementResponse> }`.
10. Serialize via `std.json.Stringify.valueAlloc`.
11. Return 201 with body.
12. Map errors: `PageNotFound` → 404, `BadChildId` → 400 with hint, `ChildAlreadyParented` → 409 with hint listing the already-parented ids, `ChildAcrossDifferentPages` → 400 with hint.

### Task 3.2 — Register route in `src/main.zig`

Find where `POST .../elements` is registered (for `add_design_element` — grep for `addDesignElementHandler`) and add immediately after:

```zig
try gs.router.post(
    "/api/workspaces/:workspace_id/items/:workspace_item_id/design/pages/:page_id/elements/group",
    design_elements_group.designElementsGroupHandler,
);
```

### Task 3.3 — Re-export handler in `src/ai_workflow/tui/http_handlers/mod.zig`

Add `pub const design_elements_group = @import("design_elements_group.zig");` matching the existing convention.

### Task 3.4 — Static-contract tests

File: `src/ai_workflow/tui/http_handlers/design_elements_group_test.zig` (NEW, ~120 lines)

Mirror the structure of `workspace_items_create_kanban_test.zig`:

- `handler parses body with parseFromSliceLeaky`
- `handler requires child_ids length >= 2`
- `handler defaults parent_name to "Group" when null`
- `handler defaults parent_type to "group" when null`
- `handler calls design_model.groupElements`
- `handler returns 201 with { parent, children } envelope`
- `handler maps ChildAlreadyParented to 409`
- `handler maps PageNotFound to 404`
- `handler maps BadChildId to 400`
- `main.zig registers the POST route`
- `mod.zig re-exports design_elements_group`

**Verification:**
```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin && timeout 360 zig build 2>&1 | tail -n 5
```

---

## Chunk 4 — Backend: `deleteElement` NULLs children's `parent_id` for parents

### Task 4.1 — `deleteElement` NULLs `parent_id` for deleted parents

File: `src/ai_workflow/tui/design_model.zig` (`deleteElement` function — find with `pub fn deleteElement`)

Before deleting a frame/group element, NULL out `parent_id` for all rows that reference it:

```sql
UPDATE design_page_elements SET parent_id = NULL WHERE parent_id = ?
```

Order:
1. NULL children (so they're orphaned but not deleted).
2. DELETE the parent element row.
3. Delete the on-disk HTML file (existing logic).
4. Emit `design_element_deleted` SSE.

This avoids a "deleting a group silently deletes its children" surprise. The children become top-level again — they keep their geometry, the user can re-group them manually.

**Static-contract test:** `design_model_test.zig` — assert `parent_id` appears in the SET clause / SQL inside `deleteElement`.

**Verification:** same as 2.2.

### Task 4.2 — Wire frontend store + SSE reconcile for the NULL-back case

After the SQL UPDATE, the SSE `design_element_deleted` event triggers the frontend's `fetchDesignElements` reconcile — which will refresh the page and re-render the children as top-level. No new SSE event type needed.

---

## Chunk 5 — Frontend: TS surface + API + store

### Task 5.1 — Add `parent_id` to `DesignElement` interface

File: `src/apps/desktop/src/api/index.ts` (line 190-213)

- Add `parent_id?: string | null` after `image_url`. Optional (the field is always nullable at the DB level; legacy rows might not have it returned).

### Task 5.2 — Add `groupDesignElements` API helper

File: `src/apps/desktop/src/api/index.ts` (add near the other `*DesignElement*` helpers)

```ts
export interface GroupDesignElementsRequest {
  child_ids: string[]
  name?: string
  type?: 'group' | 'frame'
}

export async function groupDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: GroupDesignElementsRequest,
): Promise<{
  parent: DesignElement
  children: DesignElement[]
}> {
  return apiFetch<{
    parent: DesignElement
    children: DesignElement[]
  }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/group`,
    { method: 'POST', body },
  )
}
```

### Task 5.3 — Add `groupDesignElements` store action

File: `src/apps/desktop/src/stores/workspaces.ts` (lines ~1110-1269)

```ts
async function groupDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: GroupDesignElementsRequest,
): Promise<{ parent: DesignElement; children: DesignElement[] }> {
  const result = await groupDesignElementsApi(workspaceId, itemId, pageId, body)
  const ws = workspaces.value.find((w) => w.id === workspaceId)
  const item = ws?.items.find((i) => i.id === itemId)
  if (item?.design_elements) {
    // Push the new parent + replace the children with the updated versions.
    item.design_elements.push(result.parent)
    for (const updated of result.children) {
      const idx = item.design_elements.findIndex((e) => e.id === updated.id)
      if (idx !== -1) item.design_elements[idx] = updated
    }
  }
  return result
}
```

- Add the import alias at the top:
  ```ts
  import {
    groupDesignElements as groupDesignElementsApi,
    // ... existing ...
  } from '../api'
  ```
- Return the action from the store bag.

### Task 5.4 — Tests

File: `src/apps/desktop/src/__tests__/workspacesStoreGroup.spec.ts` (NEW)

- `groupDesignElements pushes the parent to item.design_elements`
- `groupDesignElements replaces each child by id`
- `groupDesignElements returns the API result unchanged on success`
- `groupDesignElements does not mutate the array on API failure`
- `groupDesignElements toast surfaces via apiFetch's ApiError`

**Verification:**
```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20   # type-check (vue-tsc)
timeout 60 bunx vitest run src/__tests__/workspacesStoreGroup.spec.ts 2>&1 | tail -n 20
timeout 60 bunx vitest run 2>&1 | tail -n 20   # full suite
```

---

## Chunk 6 — Frontend: `useDesignHandlers` composable + Cmd+G shortcut

### Task 6.1 — Add `groupSelection` to `useDesignHandlers` composable

File: `src/apps/desktop/src/composables/useDesignHandlers.ts`

Find the existing composable; add:

```ts
const groupSelection = async (): Promise<void> => {
  if (selectedIds.value.size < 2) return  // Figma behaviour: silent no-op
  const ws = props.workspaceId
  const item = effectiveItemId.value
  const page = activePageId.value
  if (!ws || !item || !page) return

  const name = window.prompt(
    'Name the new group:',
    `Group ${selectedIds.value.size}`,
  )
  if (name === null) return  // user cancelled
  try {
    await workspacesStore.groupDesignElements(ws, item, page, {
      child_ids: Array.from(selectedIds.value),
      name,
      type: 'group',
    })
    useNotificationStore().notify({
      type: 'success',
      message: `Grouped ${selectedIds.value.size} elements into "${name}".`,
    })
    selectedIds.value = new Set()  // clear selection after grouping
  } catch (err) {
    useNotificationStore().notifyError(err, 'Failed to group selection.')
  }
}

return { ..., groupSelection }
```

(If the composable doesn't take `selectedIds`/`activePageId` as args, refactor to take them or read from props. Mirror how `deletePage` already wires.)

### Task 6.2 — Cmd+G handler in `DesignView.vue`

File: `src/apps/desktop/src/components/design/DesignView.vue` (line 400 — `handleKeydown`)

Add a new key branch (between the existing Cmd+P branch at line 454 and the F/Shift+1 fit branch at line 468):

```ts
// Cmd/Ctrl+G groups the current selection into a new group. Figma
// convention. Silent no-op when < 2 elements are selected.
if (
  (event.key === 'g' || event.key === 'G') &&
  (event.ctrlKey || event.metaKey) &&
  !event.shiftKey &&
  !event.altKey
) {
  event.preventDefault()
  designHandlers.groupSelection()
  return
}

// Cmd/Ctrl+Shift+G ungroups the selected group element. Future
// enhancement; for now it's a no-op (the LLM tool path handles it).
if (
  (event.key === 'g' || event.key === 'G') &&
  (event.ctrlKey || event.metaKey) &&
  event.shiftKey &&
  !event.altKey
) {
  event.preventDefault()
  // TODO: implement ungroupSelection in Chunk 9.
  return
}
```

Wire `designHandlers` from the composable: at the top of `<script setup>` add `const designHandlers = useDesignHandlers({ ... })` mirroring the existing pattern. If the composable doesn't exist yet, create it from scratch following `.nalar/memories/design-tab-button-needs-full-wire.md` patterns.

### Task 6.3 — Tests

File: `src/apps/desktop/src/__tests__/DesignView.spec.ts` (extend existing)

- `handleKeydown recognizes Cmd+G when selection.size >= 2 and calls groupSelection`
- `handleKeydown recognizes Ctrl+G`
- `handleKeydown noops on Cmd+G when selection.size < 2`
- `handleKeydown noops on Cmd+Shift+G (ungroup deferred)`
- `handleKeydown does not fire groupSelection when target is INPUT/TEXTAREA/contenteditable`

Use the existing static-contract test pattern (regex on the source).

**Verification:** same as 5.4.

---

## Chunk 7 — Frontend: `LayersPanel` tree render

This is the largest UI chunk. It changes how layers are displayed.

### Task 7.1 — Build the tree from the flat `DesignElement[]`

File: `src/apps/desktop/src/components/design/LayersPanel.vue`

- Replace the `layers` computed with a tree builder:
  ```ts
  interface LayerTreeNode {
    element: DesignElement
    children: LayerTreeNode[]
  }

  const layerTree = computed<LayerTreeNode[]>(() => {
    const byParent = new Map<string | null, LayerTreeNode[]>()
    const nodes = new Map<string, LayerTreeNode>()
    for (const e of props.elements) {
      const node: LayerTreeNode = { element: e, children: [] }
      nodes.set(e.id, node)
      const pid = e.parent_id ?? null
      if (!byParent.has(pid)) byParent.set(pid, [])
      byParent.get(pid)!.push(node)
    }
    for (const node of nodes.values()) {
      node.children = byParent.get(node.element.id) ?? []
    }
    // Sort children within each level by z_index DESC, then position ASC.
    for (const [, children] of byParent) {
      children.sort((a, b) => {
        if (b.element.z_index !== a.element.z_index) return b.element.z_index - a.element.z_index
        return a.element.position - b.element.position
      })
    }
    return byParent.get(null) ?? []  // top-level
  })
  ```
- Add a `collapsedIds` ref: `const collapsedIds = ref(new Set<string>())`
- Helper: `toggleCollapse(elementId: string)` → adds/removes from the set.

### Task 7.2 — Extract recursive `<LayerRow>` component

File: `src/apps/desktop/src/components/design/LayerRow.vue` (NEW, ~140 lines)

Move the row template from `LayersPanel.vue` into a new component. Take props:
- `node: LayerTreeNode`
- `depth: number`
- `selectedIds: string[]`
- `readonly: boolean`
- `collapsedIds: Set<string>` (shared state)

Emit:
- `select: [{ elementId: string; additive: boolean }]`
- `reorder: [string[]]`
- `delete: [string]`
- `toggleCollapse: [string]`

The row:
- Renders with `:style="{ paddingLeft: `${depth * 16}px` }"`
- If `node.children.length > 0`, renders a ▶/▼ button before the type icon.
- Calls `emit('toggleCollapse', node.element.id)` on the chevron click.
- If `collapsedIds.has(node.element.id)`, does NOT render its children.
- Otherwise recursively renders each child `<LayerRow>` with `depth + 1`.

### Task 7.3 — Replace the flat `v-for` in `LayersPanel.vue` with the recursive component

- Remove the row template.
- Render:
  ```vue
  <LayerRow
    v-for="(node, idx) in layerTree"
    :key="node.element.id"
    :node="node"
    :depth="0"
    :selected-ids="selectedIds"
    :collapsed-ids="collapsedIds"
    :readonly="readonly"
    :data-testid="`design-layer-${node.element.id}`"
    @select="(p) => emit('select', p)"
    @delete="(id) => emit('delete', id)"
    @toggle-collapse="toggleCollapse"
  />
  ```
- Wire `toggleCollapse(elementId)` at the panel level.
- Preserve the up/down reorder semantics: this is more subtle in a tree. For first cut, **up/down operates within the same parent's children**. Moving a top-level element up moves it within the top-level list. Moving a child up moves it within its siblings. (A "move across parents" is a future drag-to-reparent enhancement.)
- The current `handleMoveUp` / `handleMoveDown` logic assumes a flat list. Refactor to operate per-node:
  - When the user clicks ▲ on a node, find its parent's children array (or the top-level `layerTree` if `parent_id` is null).
  - Swap with the previous sibling.
  - Emit `reorder` with the new flat order of ALL ids.

### Task 7.4 — Tests

File: `src/apps/desktop/src/__tests__/LayersPanel.spec.ts` (extend existing)

Use the existing `mount(LayersPanel, ...)` test pattern from the codebase. Add:

- `renders flat list when no element has parent_id`
- `renders parent before children when some element has parent_id`
- `indents children by depth * 16px`
- `clicking the chevron toggles children visibility`
- `selectedIds highlights rows across the tree regardless of nesting`
- `delete emit bubbles up from nested LayerRow`

**Verification:**
```bash
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20   # type-check (vue-tsc)
timeout 60 bunx vitest run src/__tests__/LayersPanel.spec.ts 2>&1 | tail -n 20
```

---

## Chunk 8 — Frontend: LLM tool `group_elements`

### Task 8.1 — New LLM tool file

File: `src/modules/agent/tools/group_design_elements.zig` (NEW, ~250 lines)

Mirror `update_design_element.zig` (line ~250 of that file). The tool:

- Name: `group_elements`
- Description: explain that it wraps 2+ elements into a new `group` or `frame` parent.
- Parameters:
  - `page_id` (required) — discover via `set_design_page`
  - `child_ids` (required, array of strings)
  - `name` (optional, default `"Group"`)
  - `type` (optional, `'group' | 'frame'`, default `'group'`)
- Execute: call the same `design_model.groupElements` from Chunk 2.2.
- Response XML shape:
  ```xml
  <group_elements>
    <parent id="elem_..." name="Kanban-view" type="group" x="0" y="64" width="1440" height="836" />
    <child id="elem_..." name="app-shell" parent_id="elem_..." />
    <child id="elem_..." name="toolbar" parent_id="elem_..." />
    ...
  </group_elements>
  ```
- Error XML shape:
  ```xml
  <group_elements><error>...</error></group_elements>
  ```

### Task 8.2 — Register in `src/root.zig`

Add `pub const group_design_elements = @import("modules/agent/tools/group_design_elements.zig");` near the existing `update_design_element` line.

### Task 8.3 — Wire into `tool_registry.zig` (or wherever tools are registered)

Find the existing `update_design_element` registration. Add the new tool alongside it (same pattern: `.{ .name = "group_elements", .function = .{...} }`).

### Task 8.4 — Static-contract tests

File: `src/modules/agent/tools/group_design_elements_test.zig` (NEW)

Mirror `update_design_element_test.zig`. At least:
- `tool definition declares name "group_elements"`
- `tool parameters declare page_id, child_ids, name, type as the schema`
- `tool description mentions frame vs group and 2+ children`
- `executeGroupElementsToString returns <group_elements><parent .../>...</group_elements> on success`
- `executeGroupElementsToString returns <group_elements><error>...</error></group_elements> on ChildAlreadyParented`
- `executeGroupElementsToString calls design_model.groupElements with the right args`

**Verification:**
```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin && timeout 360 zig build 2>&1 | tail -n 5
```

---

## Chunk 9 — Frontend: Ungroup (Cmd+Shift+G) + drag-to-reparent follow-ups

**Scope: DEFERRED.** This is listed as the final chunk but explicitly out of scope for the first PR. Mention it in the spec + plan README so future agents pick it up.

### Task 9.1 — Ungroup endpoint (backend)

Add `POST /api/workspaces/:w/items/:i/design/pages/:p/elements/ungroup` with body `{ group_id: "elem_..." }`. Behaviour: NULL `parent_id` on all children where `parent_id = group_id`, then DELETE the group element (same flow as delete-parent in Chunk 4.1).

### Task 9.2 — Ungroup action (frontend)

Add `ungroupSelection()` to `useDesignHandlers`. Wire Cmd+Shift+G in `DesignView.vue` (the placeholder branch from Chunk 6.2).

### Task 9.3 — Drag-to-reparent

Drag a layer row onto another row in the LayersPanel → sets the dragged element's `parent_id` to the drop target's id. Use `updateDesignElement` (extended in Chunk 2.1) for the API call.

---

## Verification (End-to-End)

After all chunks land:

```bash
# 1. Backend static + behavioural tests
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all
# Expect: total count UP from baseline (was ~1876/1876 before this plan)
#         all NEW tests pass (group_model, group_handler, group_tool, etc.)

# 2. Backend build + cross-compile
timeout 180 zig build install:linux:system
rm -rf zig-out/bin
timeout 360 zig build
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig

# 3. Frontend type-check + tests
cd src/apps/desktop
timeout 180 bun run build               # vue-tsc + vite
timeout 180 bunx vitest run             # all tests

# 4. Functional scenario (uses Python harness against an isolated nalar)
cd /home/ginwa/ginwaaitoolbox
zig build install:linux:system
env -i HOME=/tmp/nalar-group-smoke PATH=$PATH \
  ./zig-out/bin/nalar --port 8080 &
sleep 5
cd tests/functional
pytest -v group_design_elements_test.py
# Expect: all scenarios PASS

# 5. Live UI smoke against port 8080 (NEVER 8081)
# In nalar-desktop webapp:
#   - Open a design page with ≥ 2 elements
#   - Select 2 elements (click + Shift+click)
#   - Press Cmd+G → "Name the new group:" prompt appears
#   - Type "My Group", click OK
#   - LayersPanel now shows:
#       ▭ My Group
#         ▭ app-shell
#         ▭ toolbar
#   - Click the ▶/▼ chevron on "My Group" → children collapse
#   - Click it again → children re-expand
#   - Delete "My Group" → children become top-level again (parent_id = NULL)

# 6. LLM chat smoke (against port 8080)
# In nalar-desktop:
#   - Open a design item, click 💬
#   - Type "Group app-shell, toolbar, and kanban-board into a 'Kanban-view' parent"
#   - The LLM should call group_elements with the right child_ids
#   - The LayersPanel updates with the new group at the top
```

## Cleanup

- [ ] Delete this plan file (per `.nalar/memories/design-chat-per-page-chat-sessions.md` convention — plans roll into SPEC).
- [ ] Update `docs/SPEC.md` §3.8 with the new chunk summary.
- [ ] Add a PR index entry to `docs/SPEC.md` §10.2.1.

---

## Cross-cutting Pitfalls

These will bite if forgotten. Mirrors `.nalar/memories/design-tab-button-needs-full-wire.md`.

### Backend
- **Don't forget to NULL children's `parent_id` before deleting a parent.** (Chunk 4.1)
- **Transaction or fail loudly.** Either wrap `groupElements` in a `tx.commit()` or document the partial-failure mode explicitly. **Prefer the transaction.**
- **Don't hardcode the SSE event type name.** Read the existing `design_element_created` / `design_element_updated` event types from `on_event_sent_design.zig` and reuse them — don't invent `group_element_created`.
- **`parent_id` is TEXT NULL.** Use the empty-slice-vs-NULL pattern from `.nalar/memories/zig-sqlite-patterns.md` §"empty slice as NULL". A non-null `parent_id = ''` would write a literal empty string, not NULL — different semantics.
- **The on-disk HTML file for the new group.** The `addElement` function writes `<page_dir>/<element_name>.html`. The new group needs the same — use `design_io.sanitizeFilename` to be safe with non-ASCII names.
- **`type` parameter is a string in the wire, an enum internally.** Mirror the `parseOptionalElementType` pattern from `update_design_element.zig:369-378`.
- **Cross-compile before declaring done.** Run `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig` AND `-target aarch64-macos -lc` to catch lazy-analysis errors that `zig build test` misses (per `.nalar/memories/zig-build-and-test.md`).

### Frontend
- **`apiFetch` mock helpers need `text()` method + active Pinia** (per `.nalar/memories/nalar-frontend-patterns.md`). When testing `groupDesignElements`, mocks must implement `text: () => Promise.resolve(JSON.stringify(body))` and tests must `setActivePinia(createPinia())` in `beforeEach`.
- **`bun run build` is the type-check, NOT `bunx vitest run`.** Always run both.
- **Recursive components in Vue 3** must declare `name: 'LayerRow'` in `<script setup>` or set `defineOptions({ name: 'LayerRow' })` for `vue-tsc` to recognize them in `<LayerRow>` usage. Without this, `vue-tsc` reports "Component LayerRow is not registered in any module".
- **Selection across the tree is still flat.** A user might expect "clicking a group selects all its children"; this is NOT shipped in this plan. Document it in the chunk-9 follow-up.
- **The flat `handleMoveUp` / `handleMoveDown` from `LayersPanel.vue:75-101` becomes per-parent after Chunk 7.3.** Make sure the `reorder` emit still emits the FULL ordered list of all top-level ids (so the backend's `PATCH /reorder` works unchanged).
- **`window.prompt` is a hack.** Figma uses an inline rename affordance. For the first cut `window.prompt` is fine — note in the plan as a follow-up to replace with an inline rename.
- **The LayersPanel uses `data-testid="design-layer-${elementId}"` on each row** — preserve this in `LayerRow.vue` so existing tests that depend on it still pass.

### Cross-platform
- **Don't use `parentElement` in `LayersPanel.vue` JS** without checking `parentElement` exists — it can be `null` in JSDOM tests (per `.nalar/memories/nalar-frontend-patterns.md`).
- **The `selection` set is reactive** (`selectedIds.value = new Set()`); pass it via `toRaw` if passing to non-reactive contexts.

---

## Reference

- Existing memory: `.nalar/memories/design-tab-button-needs-full-wire.md` — same wire-must-reach-every-layer pattern.
- Existing memory: `.nalar/memories/design-mode-iframe-scrollbar-leak.md` — group nesting will need iframe scrollbar styling too (one per child iframe, not the group's outer iframe).
- Existing memory: `.nalar/memories/design-chat-per-page-chat-sessions.md` — recently landed sibling plan, follows the same structure.
- Plan file: `docs/plans/2026-07-08-design-mode-redesign.md` — original design-mode feature plan that left frame/group nesting deferred (§10.1 of SPEC).
- Nalar's project memory: `.nalar/memories/nalar-backend-architecture.md`, `nalar-frontend-patterns.md`, `zig-build-and-test.md`.