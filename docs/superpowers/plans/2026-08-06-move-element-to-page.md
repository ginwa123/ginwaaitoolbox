# Plan — Move element to another design page (context menu)

**Branch:** `worktree/design-move-to-page`
**Date:** 2026-08-06
**Owner:** session `task_1785847404640`
**Spec:** `docs/superpowers/specs/2026-08-06-move-element-to-page-design.md`

> **OPEN TRADE-OFFS** — this plan assumes the **recommended (A)** answer
> for Q1–Q6 of the spec. If you want a different answer, tell me and
> I'll patch the plan before implementing. The 6 trade-offs are:
>
> | # | Trade-off | Default | Alternative |
> |---|---|---|---|
> | Q1 | Submenu vs modal picker | **A — Modal** | B submenu · C both |
> | Q2 | Multi-select behavior | **A — Single element only** | B move all as top-level · C group them |
> | Q3 | Descendant cascade | **A — Cascade by default** | B leave descendants · C user pick |
> | Q4 | Parent not selected | **A — Auto-detach to top-level** | B reject · C include parent |
> | Q5 | Target position | **A — Append at end, keep x/y** | B reset to (0,0) · C user pick |
> | Q6 | Navigate after move | **A — Yes** | B stay on source page |

---

## Symptom

User wants to right-click an element in design mode → menu → "Move to page..." → pick a target page → element relocates. Today's workflow is: copy element data, delete source, recreate on target. Painful and error-prone.

## Root cause

The design model has a `moveElementsWithDescendantsBatch` function that moves elements WITHIN a page (changes `x`/`y` with a cascade). There's no equivalent that changes `page_id`. The `parent_id` reparent-batch handler (`reparentElements` → `POST .../reparent-batch`) handles within-page reparenting but not cross-page.

The context menu (`DesignContextMenu.vue`) has 9 items but no cross-page move affordance. The sidebar tree (`WorkspaceItem.vue`) shows the page list but has no drag-from-canvas-to-page-row gesture.

## What landed (planned)

### Files changed (10 new + 6 edited)

**Backend (6 new + 1 edit)**

- **`src/ai_workflow/tui/design_model.zig`** — new `moveElementToPage(allocator, db, input)` function
  ~150 lines. Mirrors `moveElementsWithDescendantsBatch` but UPDATEs `page_id` instead of `x`/`y`. Uses the same recursive CTE for cascade. Pre-flight checks: element exists on source page, target page exists on same design item, source page != target page. Returns the updated elements in tree-traversal order.
- **`src/ai_workflow/tui/design_model_move_to_page_test.zig`** (new) — inline behavioural tests. 8 cases:
  1. Move leaf (no children) — cascade is a no-op
  2. Move group with 2 children — subtree moves atomically
  3. Move group with grandchildren (depth 2) — recursive works
  4. Move element with `parent_id` set to non-selected parent — parent's `parent_id` is auto-cleared (Q4 default)
  5. Source page == target page → `SamePage` error
  6. Target page on different design item → `CrossDesign` error
  7. Target page doesn't exist → `PageNotFound` error
  8. Element doesn't exist on source page → `ElementNotFound` error
- **`src/ai_workflow/tui/http_handlers/design_elements_move_to_page.zig`** (new) — HTTP handler
  - `POST /api/workspaces/:w/items/:i/design/pages/:p/elements/:eid/move-to-page`
  - Body: `{ new_page_id: string, apply_to_children?: bool }` (default `true`)
  - Response: `{ updated: DesignElementResponse[] }`
  - Status codes: 200/400/404/500 per the Q7 contract
- **`src/ai_workflow/tui/http_handlers/design_elements_move_to_page_test.zig`** (new) — 6 inline tests:
  1. Happy path (200) with response shape
  2. SameSourceAndTarget (400)
  3. ElementNotFound (404)
  4. TargetPageNotFound (404)
  5. CrossDesignItem (400)
  6. DbError (500)
- **`src/ai_workflow/tui/modules/agent/tools/move_element_to_page.zig`** (new) — LLM tool
  - Tool definition + `executeMoveElementToPageToString(...)`
  - Mirrors `move_design_element.zig`'s input shape + error envelope
- **`src/ai_workflow/tui/modules/agent/tools/move_element_to_page_test.zig`** (new) — 4 wiring tests
- **`src/main.zig`** — register the new POST route (1 line)

**Frontend (4 new + 5 edited)**

- **`src/apps/desktop/src/api/index.ts`** — new `moveDesignElementToPage(...)` API wrapper
  - URL: `POST /workspaces/${wsId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/move-to-page`
  - Body: `{ new_page_id, apply_to_children }`
  - Returns: `{ updated: DesignElement[] }`
- **`src/apps/desktop/src/stores/workspaces.ts`** — new `moveElementsToPage(...)` store action
  - Optimistic: remove elements from source page's `design_elements`, append to target page's `design_elements`
  - Calls the API; on success, replaces the optimistic state with the wire response
  - On error: rolls back the optimistic state + fires error toast
- **`src/apps/desktop/src/components/design/MoveToPageDialog.vue`** (new) — centered modal
  - `<Teleport to="body">` + backdrop + Esc + ✕ close paths
  - Title: `Move "${element.name}" to which page?`
  - Body: scrollable list of OTHER pages in the design item (filter out the current page)
  - Each row: page name + `→` icon + click → emit `select` with pageId
  - Empty state: "This is the only page" (greyed select all)
  - `data-testid="move-to-page-dialog"` / `-backdrop` / `-close`
- **`src/apps/desktop/src/components/design/DesignContextMenu.vue`** — new menu item (edit)
  - New button "Move to page..." between "Bring to back" and the second separator (slot 9)
  - New `canMoveToPage` computed: enabled when `targetIds.length === 1` (Q2 default)
  - New `moveToPage: [targetId: string]` emit
  - `MENU_ROWS` updated `10` → `11`
  - `data-testid="design-context-menu-move-to-page"`
- **`src/apps/desktop/src/components/design/LayersPanel.vue`** — bubble the new emit (edit)
  - New `moveToPage: [elementId: string]` in `defineEmits`
  - `@move-to-page="(id) => emit('moveToPage', id)"`
- **`src/apps/desktop/src/components/design/DesignView.vue`** — handle the new menu action (edit)
  - New `handleDesignMoveToPageFromContextMenu(elementId)` handler
  - Sets `moveToPageDialogElementId.value = elementId` to open the dialog
  - Mounted the new `<MoveToPageDialog>` at AppLayout level (mirrors `KanbanChatDialog` pattern)
- **`src/apps/desktop/src/composables/useDesignHandlers.ts`** — new `moveToPage(elementId, newPageId)` (edit)
  - Mirrors `leaveGroup` shape: args-driven ids, silent no-op on missing args, try/catch around the store call, success toast via `notificationStore.notifyError`, error toast on failure
  - After successful move: navigates to the target page (Q6 default) via `setActiveDesignPage` + `setActiveWorkspaceItem`
  - Clears `selectedIds.value` on success
- **`src/apps/desktop/src/__tests__/MoveToPageDialog.spec.ts`** (new) — 9 behavioural tests
  1. Renders with title containing the element name
  2. Lists all OTHER pages (filters out current page)
  3. Click ✕ → emits `close`
  4. Click backdrop → emits `close`
  5. Press Esc → emits `close`
  6. Click a page row → emits `select` with the right pageId
  7. Hidden when `visible=false` (Teleport)
  8. Only-one-page edge case → shows "This is the only page" message (no selectable rows)
  9. Page list is sorted by position asc
- **`src/apps/desktop/src/__tests__/DesignContextMenu.spec.ts`** — 4 new tests in a new describe block "Move to page":
  1. Enabled when `targetIds.length === 1`
  2. Disabled when `targetIds.length > 1`
  3. Disabled when `targetIds.length === 0`
  4. Click emits `moveToPage` with the targetId
- **`src/apps/desktop/src/__tests__/DesignView.moveToPage.spec.ts`** (new) — 5 behavioural tests
  1. Right-click → menu → "Move to page..." → click → modal opens with element name
  2. Modal click page → store action called with right ids → modal closes
  3. Modal close (any path) → no store call
  4. After successful move, the active page is the target page (Q6 default)
  5. After successful move, `selectedIds` is cleared

### TDD trace (RED → GREEN per chunk)

| Chunk | What's new | RED → GREEN |
|---|---|---|
| 1. Backend design model | `design_model.zig::moveElementToPage` | 8 inline tests fail → utility passes |
| 2. Backend HTTP handler | `design_elements_move_to_page.zig` | 6 inline tests fail → handler passes |
| 3. Backend LLM tool | `move_element_to_page.zig` | 4 wiring tests fail → tool passes |
| 4. Frontend API | `api/index.ts::moveDesignElementToPage` | (covered by store/composable tests) |
| 5. Frontend store | `workspaces.ts::moveElementsToPage` | 3 optimistic-mirror tests fail → store passes |
| 6. Frontend modal | `MoveToPageDialog.vue` | 9 tests fail → component passes |
| 7. Frontend context menu | `DesignContextMenu.vue` (4 new tests) | 4 tests fail → menu passes |
| 8. Frontend integration | `DesignView.vue` + `useDesignHandlers.ts` (5 tests) | 5 tests fail → integration passes |
| 9. Manual + visual smoke | live dev server | passes |

### Verification

```bash
# Backend
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
timeout 360 bash -c 'rm -rf zig-out/bin && zig build'

# Cross-compile smoke (mandatory — the new SQL helpers can be hidden
# by lazy analysis without these)
timeout 60 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig
timeout 60 zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig

# Frontend
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run 2>&1 | tail -n 20
```

Expected: all backend tests pass (zero new failures), all 4 cross-compile
smoke pass, frontend vue-tsc clean, vitest passes (the 19 pre-existing
baseline failures are unchanged).

## Out of scope (explicitly deferred)

- **Bulk multi-page move** (per Q2/A default): moving N elements across
  N pages in one operation. v1 only handles one element (or its subtree)
  at a time.
- **Drag-from-canvas-to-page-row in the sidebar tree**: a separate UX.
  The LayersPanel already supports drag-to-reparent; that's a different
  gesture with different semantics. Future enhancement.
- **Position clamping if target page is smaller**: elements can end up
  off-screen. v1 doesn't clamp; the user drags them. Figma doesn't
  clamp either.
- **Cross-design-item move**: the new endpoint rejects this with
  `CrossDesign` (400). v1 restricts to the same design item.
- **Copy-to-page**: Figma's "Copy to page" is a separate affordance.
  Future enhancement (would add a `Copy` button next to the move item).
- **SSE event for the move**: the existing
  `design_elements_geometry_batch_updated` event is for coordinate
  changes. Cross-page moves need a new event type
  (`design_elements_page_changed` carrying the source/target page_id +
  the moved element ids). Emit it from `moveElementToPage` after the
  commit. The frontend's SSE handler ignores it for v1 (the optimistic
  store action already mirrors the local state — the SSE event is a
  safety net for OTHER tabs watching the same design).
- **Per-page filter or "search pages"**: when the design has 50+ pages,
  a modal listing all of them is long. v1 just scrolls. Future: add a
  search input at the top of the modal.

## Files reference

### Files to CREATE

- `docs/superpowers/specs/2026-08-06-move-element-to-page-design.md`
- `docs/superpowers/plans/2026-08-06-move-element-to-page.md` (this file)
- `src/ai_workflow/tui/design_model_move_to_page_test.zig`
- `src/ai_workflow/tui/http_handlers/design_elements_move_to_page.zig`
- `src/ai_workflow/tui/http_handlers/design_elements_move_to_page_test.zig`
- `src/modules/agent/tools/move_element_to_page.zig`
- `src/modules/agent/tools/move_element_to_page_test.zig`
- `src/apps/desktop/src/components/design/MoveToPageDialog.vue`
- `src/apps/desktop/src/__tests__/MoveToPageDialog.spec.ts`
- `src/apps/desktop/src/__tests__/DesignView.moveToPage.spec.ts`

### Files to EDIT

- `src/ai_workflow/tui/design_model.zig` (add `moveElementToPage`)
- `src/main.zig` (register new POST route)
- `src/apps/desktop/src/api/index.ts` (add `moveDesignElementToPage`)
- `src/apps/desktop/src/stores/workspaces.ts` (add `moveElementsToPage`)
- `src/apps/desktop/src/components/design/DesignContextMenu.vue` (add menu item)
- `src/apps/desktop/src/components/design/LayersPanel.vue` (bubble emit)
- `src/apps/desktop/src/components/design/DesignView.vue` (handle + mount dialog)
- `src/apps/desktop/src/composables/useDesignHandlers.ts` (add `moveToPage`)
- `src/apps/desktop/src/__tests__/DesignContextMenu.spec.ts` (4 new tests)
- `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` (reference for modal pattern only)

### Files NOT touched

- No migration (no schema change)
- No new test file in `migrations/` (no schema change)
- No change to `agentic_loop/mod.zig` (LLM tool registered through the
  `tools_exec_*.zig` + `tools_equipped.zig` flow that's already in place)

## Risk register

| Risk | Mitigation |
|---|---|
| Lazy semantic analysis hides SQL prepare errors in the new CTE | Cross-compile smoke + `zig build test` after every chunk |
| Vue 3 reactivity trap on `selectedIds` after navigation | Use `args.selectedIds.value = new Set()` exactly like `leaveGroup` does |
| The new modal's backdrop blocks the canvas drag | Modal is `Teleport` into body — same as `KanbanTaskDetailDialog`, no canvas interaction |
| Cascade of N elements is slow for designs with 100+ elements | The existing `moveElementsWithDescendantsBatch` already handles this; same performance |
| User moves the last element off a page, leaving it empty | The empty page is allowed (matches current delete-page semantics); user can delete it manually |
| Test fixtures leak `tasks` between design-page tests | Use existing `migration_test_runner.zig` patterns — each test sets up fresh DB |

## PR description draft

> **Move element to another design page (context menu)** — adds a right-click "Move to page..." menu item to the design canvas + LayersPanel. The element (and its descendants if it's a group/frame) relocates to the target page in one atomic SQL transaction. The user is navigated to the target page after the move so they can see the result. Mirrors the existing `moveElementsWithDescendantsBatch` cascade pattern and the `leaveGroup` handler pattern. Includes a new `move_element_to_page` LLM tool for symmetry. No new DB migration. 27 new behavioural tests (8 backend model + 6 HTTP + 4 LLM tool + 9 frontend modal + 4 menu + 5 integration = 36 if you include the 4 DesignContextMenu + 5 DesignView tests).

## Next step

After user confirms the plan + 6 trade-offs (or "all A" to accept defaults), I open a worktree at `.worktrees/design-move-to-page` and start chunk 1 (backend design model).
