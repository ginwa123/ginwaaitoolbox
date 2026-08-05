# Design — Move element to another design page (context menu)

**Branch:** `worktree/design-move-to-page`
**Date:** 2026-08-06
**Owner:** session `task_1785847404640`
**Status:** 📝 SPEC — awaiting user confirmation on open questions below

---

## Symptom

User (current task `design mode, move another elements`) wants to
move a design element from one page to another. The screenshot
shows the workspace sidebar tree with 5 design pages (`AI Chat
View`, `Kanban Mode`, `Chat View In Progress`, `Workspaces
Sidebar`, `Task Dialog`) — pages already exist as a navigational
concept, but there's no way to relocate an element between them.

Today the only way to "move" between pages is:
1. Copy the element's data (x/y/w/h/etc.) manually.
2. Delete the source element.
3. Re-create it on the target page.

The user wants a single menu action: **right-click → "Move to
page..." → pick a target page → done**.

## Mental model

Figma's "Move to page" affordance. The user can:

- Right-click on a single element (or a group) → "Move to page…"
- Pick a target page from the list of OTHER pages in the same design
- The element (and its descendants if it's a group/frame) moves
  to the target page
- The user is navigated to the target page so they can see the
  result

This is **not** a copy — it's a relocate. The element disappears
from the source page and appears on the target page (in the same
position, same dimensions, same name, same parent if its parent is
also being moved).

## Architecture (high level)

1. **Backend** — new `POST .../elements/:element_id/move-to-page`
   endpoint with body `{ new_page_id, apply_to_children? }`.
   Returns `{ updated: DesignElement[] }` (the moved element +
   its descendants).
2. **Design model** — new `moveElementToPage(allocator, db, input)`
   function that mirrors the existing `moveElementsWithDescendantsBatch`
   but changes the `page_id` column instead of `x`/`y`. Uses the same
   recursive CTE to cascade when `apply_to_children=true`.
3. **Frontend** — new `MoveToPageDialog` modal (Vue component) that
   lists all OTHER pages for the design item. Triggered from the
   existing `DesignContextMenu.vue` via a new "Move to page..." menu item.
4. **Store** — new `workspacesStore.moveElementsToPage(...)` action that
   handles the optimistic UI mirror (remove from source page, add to
   target page) and the API call.
5. **LLM tool** — new `move_element_to_page` tool (mirrors the existing
   `move_design_element` tool shape) so the LLM can do this too.

## Open questions (need user confirmation BEFORE implementation)

> **Per project rule (`out-of-scope-trade-offs-need-user-confirmation`):**
> I will NOT implement these decisions unilaterally. Each one has a
> recommended default in the table — reply with the pre-overridden
> letter if you want me to change any of them.

### Q1. Submenu vs modal picker for the target page list

| Option | Description | Pros | Cons |
|---|---|---|---|
| **A — Modal** (recommended) | New `<MoveToPageDialog>` component listing other pages in a centered modal. Existing Figma-like modal pattern (e.g. `KanbanTaskDetailDialog`). | Simpler to test (mount + click); accessible (focus trap, Esc, backdrop); scales to many pages (scrollable) | Two clicks vs one |
| B — Submenu on hover | When user hovers "Move to page…", a second popover opens to the right listing pages. | Fewer clicks; matches Figma desktop | Harder to test; tight on viewport space; the existing menu already has 9 items — submenu push would overflow |
| C — Both | Submenu on hover, modal fallback when menu doesn't fit | Best of both | Most code to write |

### Q2. How to handle multi-selection

| Option | Description | Notes |
|---|---|---|
| **A — Single element only** (recommended) | "Move to page…" is greyed out when `targetIds.length > 1`. The user selects one element, moves it, then the next. | Simplest. Matches Figma's "Move to page" being per-element. |
| B — Move all multi-selected elements as individual top-level | Each selected element moves to the target page as top-level (parent_id cleared). | Conflicts with the cascade rule in Q3. |
| C — Move all multi-selected elements as a group | If 2+ are selected, move them all AND insert a new parent group atomically. | Complex; not how Figma works. |

### Q3. How to handle descendants (cascading)

| Option | Description | Notes |
|---|---|---|
| **A — Cascade by default** (recommended, mirror `move_design_element`) | If the selected element is a `group`/`frame`, move the element AND every descendant. `apply_to_children=true` is the default and the only mode for v1. | Mirrors the existing `move_design_element` cascade semantics. Figma parity. |
| B — Move element only, leave descendants | Move the element; descendants are orphaned (parent_id cleared, retained on source page). | Easier to implement. But creates orphan data on the source page. |
| C — User picks inside the dialog | Dialog has a "Move with [N] descendants" checkbox. | More config, more tests. |

### Q4. How to handle children whose parent is NOT being moved

| Option | Description | Notes |
|---|---|---|
| **A — Auto-detach to top-level on target page** (recommended) | If the selected element has a `parent_id` pointing to an element NOT being moved, the move proceeds but the element's new `parent_id` is set to `''` (top-level on the target page). | Matches the existing "Leave group" menu item's behavior — the element is "pulled out" of the parent as part of the cross-page move. |
| B — Reject the move | Return 400 with "Cannot move child whose parent is not selected; leave group first". | Forces the user to think about the tree. Can be frustrating. |
| C — Silently include the parent | Cascade UP to include the parent. | Could move hundreds of elements the user didn't intend. |

### Q5. Target position within the destination page

| Option | Description | Notes |
|---|---|---|
| **A — Append at end** (recommended) | New element's `position` = `MAX(position) + 1` on the target page. Keep original x/y. | No surprises. The user can drag to reposition. |
| B — Drop at origin (0, 0) | Reset x/y to 0 regardless of original coords. | Anonymous. Loses context. |
| C — User picks | Add x/y inputs to the dialog. | Over-engineered for v1. |

### Q6. Should the user be navigated to the target page after a successful move?

| Option | Description | Notes |
|---|---|---|
| **A — Yes, navigate** (recommended) | After the move completes, switch the active page to the target. The user sees the result. | Figma desktop does this. |
| B — No, stay on the source page | User sees the element disappear (and the next target page in the sidebar tree shows the new element). | Less obvious that the move succeeded. |

### Q7. Backend error contract

| Status | When | Wire |
|---|---|---|
| 200 | Success | `{ updated: DesignElement[] }` |
| 400 | `new_page_id` is empty / same as source page_id | `{ error: "SamePage", message: "..." }` |
| 404 | `element_id` not found on the source page | `{ error: "ElementNotFound", ... }` |
| 404 | `new_page_id` not found | `{ error: "PageNotFound", ... }` |
| 400 | `new_page_id` is on a different design item | `{ error: "CrossDesign", ... }` |
| 500 | DB failure | `{ error: "DbError", ... }` |

## What this plan does NOT do (out of scope)

- **Bulk multi-page move**: moving N elements across N pages in one
  operation. v1 only handles one element (or its subtree) at a time.
- **Drag-drop to page in the sidebar tree**: a separate UX. The
  LayersPanel already supports drag-to-reparent; that's a different
  gesture with different semantics. Future enhancement.
- **Move with absolute position adjustment**: if the target page has a
  different canvas size, elements can end up off-screen. v1 doesn't
  clamp; the user drags them. Figma doesn't clamp either.
- **Cross-design-item move**: moving an element from design A's page
  to design B's page. The new endpoint rejects this with
  `CrossDesign`. v1 is restricted to the same design item.
- **Copy (not move)**: Figma has "Move to page" + "Copy to page". v1
  only does move. Copy-to-page is a follow-up.

## Verification plan

- `bun run build` clean (vue-tsc + vite)
- `bunx vitest run` — all new tests pass; no regressions in the 19
  pre-existing baseline failures
- `zig build test --summary all` — backend tests pass
- `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` — Windows
  cross-compile clean
- `zig build-obj -fno-emit-bin -target aarch64-macos` — macOS
  cross-compile clean
- Live smoke: right-click an element on a real design page → menu
  shows "Move to page…" → click → modal lists other pages → pick one
  → element disappears from source, appears on target, current page
  switches to target, selection is cleared

## Reference patterns to mirror

- `src/ai_workflow/tui/http_handlers/design_elements_move_batch.zig` —
  the existing batch move handler (request body shape, error
  envelope, response envelope)
- `src/ai_workflow/tui/design_model.zig::moveElementsWithDescendantsBatch`
  — the existing cascade move (recursive CTE, transaction, page
  lookup, SSE event)
- `src/modules/agent/tools/move_design_element.zig` — the existing
  LLM tool (input shape, error XML envelope, validation helpers)
- `src/apps/desktop/src/components/design/DesignContextMenu.vue` — the
  existing context menu (item pattern, canX computed, emit contract)
- `src/apps/desktop/src/composables/useDesignHandlers.ts::leaveGroup`
  — the most recent menu item addition (handler pattern, args-driven
  ids, store call, success/error toast)
- `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` —
  the existing centered modal pattern (Teleport, backdrop, Esc)
- `docs/superpowers/plans/2026-08-06-design-leave-group-menu.md` —
  the most recent context-menu addition plan (PR #166)

## Action requested

Reply with **A** or your preferred alternative for each of Q1–Q6 (Q7
is the recommended default unless you want to change it). Once I
have the answers, I'll write the full implementation plan in
`docs/superpowers/plans/2026-08-06-move-element-to-page.md` and start
the TDD-ordered chunks.
