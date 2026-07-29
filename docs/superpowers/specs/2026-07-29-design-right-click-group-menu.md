# Design: Right-click context menu in LayersPanel + canvas (design mode)

**Status:** Draft — awaiting user review (2026-07-29)

**Related work:** PR #136 (grouped layers, Chunk 7). Continues the layers-panel parity work. Plan: `docs/superpowers/plans/2026-07-29-design-right-click-group-menu.md`.

---

## Goal

Add a right-click context menu to the design layers panel AND the design canvas with: Group selection · Select all · Bring to front · Bring forward · Send backward · Send to back · Delete. Fix canvas Shift+click parity so the canvas supports multi-select (currently it always replaces). Add the matching keyboard shortcuts (Cmd+A, Cmd+[ / ], Cmd+Shift+[ / ], Backspace) so the new actions have both mouse and keyboard entry points. Behind the scenes: introduce the missing `/elements/reorder` endpoint so the four "Bring / Send" actions actually persist to the DB (a pre-existing bug — the per-row ▲/▼ buttons on the layers panel only update the local layer panel view today; they don't reach the backend).

## Out of scope (explicit YAGNI)

- **Ungroup (Cmd+Shift+G right-click item).** Deferred to a follow-up plan. Would require a new `/ungroup` endpoint that reparents children + deletes the parent. Listed in the original deferred-items list of the grouped-layers plan (Chunk 9).
- **Marquee drag-select on the canvas.** Rubber-band rectangle to select everything it intersects. Deferred.
- **Lock / hide per-element.** Requires a schema migration. Deferred.
- **Per-element right-click on the canvas (only background supports it in this plan).** The user can right-click empty canvas or any layer row. Right-clicking directly on a canvas element (not the empty area) is deferred.
- **Inline rename for new groups (replaces the existing `window.prompt`).** Documented as the §7.1 follow-up in the original grouped-layers plan. Not in this plan.

## Architecture overview

Two new frontend affordances + a small backend extension, no schema changes:

1. **`DesignContextMenu.vue`** — shared, Teleport-based floating menu (mirrors the proven `GitChanges.vue` pattern). Renders the menu items with appropriate disabled states and accelerators.
2. **`useDesignContextMenu.ts` composable** — owns the `visible / x / y / targetIds` state, listens for `document click` / `Escape` / `scroll` to dismiss. Returns `{ open(event, ids), close(), state }` so any consumer can drive it.
3. **Canvas `Shift+click` toggle** — `DesignElement.vue` already emits `select`; we change the handler in `DesignView.vue:1600` from `(id) => handleElementToggle(id, false)` to `(id, additive) => handleElementToggle(id, additive)` and pass `shiftKey` from the pointerdown handler. Single-click keeps replace semantics.
4. **`Cmd+A` / `Ctrl+A` → Select all** — bound in `DesignView.vue`'s existing `handleKeydown`. Prevents default browser select-all-text behavior when the canvas is focused. Picks every element on the active page.
5. **Reorder extension via new endpoint** — new `POST /api/.../design/pages/:p/elements/reorder` accepts `{ mode, element_ids }` for the four reorder modes (absolute front / back, single step). Backed by the existing `design_page_elements.z_index` column.

## Menu items (in display order)

| Item | Accelerator (mac) | Accelerator (Linux/Win) | Enabled when | Action |
|---|---|---|---|---|
| Group selection | `⌘G` | `Ctrl+G` | `selectedIds.size >= 2` and none are already parented to a `group`/`frame` | Calls existing `workspacesStore.groupDesignElements(...)` (the path Cmd+G uses today) |
| Select all | `⌘A` | `Ctrl+A` | always | Replaces selection with `new Set(elements.map(e => e.id))` |
| ─── separator | | | | |
| Bring to front | `⌘⇧]` | `Ctrl+Shift+]` | `selectedIds.size >= 1` | Sets the highest `z_index` in the page (+1) on every selected element |
| Bring forward | `⌘]` | `Ctrl+]` | `selectedIds.size >= 1` | Swaps with the next-sibling above in z-order |
| Send backward | `⌘[` | `Ctrl+[` | `selectedIds.size >= 1` | Swaps with the next-sibling below in z-order |
| Send to back | `⌘⇧[` | `Ctrl+Shift+[` | `selectedIds.size >= 1` | Sets the lowest `z_index` in the page on every selected element |
| ─── separator | | | | |
| Delete | `⌫` | `Del` | `selectedIds.size >= 1` | Existing per-element delete handler, batched |

Each accelerator label is shown in a right-aligned dim column inside the menu (matches `GitChanges.vue` pattern + Figma / macOS conventions). Disabled items render dim with no hover state.

## Where the menu appears

- **Layers panel rows** (`LayerRow.vue`): `@contextmenu.prevent="openContextMenu($event, [node.element.id])"` — open with just this one id, but if `event.shiftKey` AND the row is already in `selectedIds`, open with the whole selection (right-click extends). If shift-click doesn't match, replace the selection at the cursor first, then open the menu against that single id.
- **Canvas background** (any pixel inside the design canvas where no element is hit): `@contextmenu.prevent` on `design-canvas` — open with the current `selectedIds` (so the user can right-click empty canvas to act on a multi-selection).
- **NOT on an individual element on the canvas** — to keep this scope bounded. Future plan can add per-element right-click on canvas if desired.
- **`readonly = true`** (Preview mode): the menu is hidden entirely. Same as the layers panel's existing `readonly` gate.

## Component / file touch map

| File | Action | Purpose |
|---|---|---|
| `src/apps/desktop/src/components/design/DesignContextMenu.vue` | NEW | Shared Teleport menu |
| `src/apps/desktop/src/composables/useDesignContextMenu.ts` | NEW | Open / close / state |
| `src/apps/desktop/src/components/design/LayerRow.vue` | EDIT | Add `@contextmenu` handler |
| `src/apps/desktop/src/components/design/LayersPanel.vue` | EDIT | Own the `useDesignContextMenu()` instance, pass it down + render `<DesignContextMenu>` once |
| `src/apps/desktop/src/components/design/DesignView.vue` | EDIT | Canvas `@contextmenu` on canvas div, keyboard shortcuts (Cmd+A, Cmd+[ / ], Cmd+Shift+[ / ], Backspace), pipe `additive` through from `DesignElement` select → `handleElementToggle`, hook menu actions to handlers |
| `src/apps/desktop/src/components/design/DesignElement.vue` | EDIT | Emit `select` payload with `additive: shiftKey` from the pointerdown |
| `src/apps/desktop/src/stores/workspaces.ts` | EDIT | Add `reorderDesignElements(ws, item, page, mode, ids)` store action |
| `src/apps/desktop/src/api/index.ts` | EDIT | Add `reorderDesignElements` API wrapper |
| `src/ai_workflow/tui/design_model.zig` | EDIT | Extend `reorderElements` model to accept `ReorderMode` (4 variants) |
| `src/ai_workflow/tui/http_handlers/design_elements_reorder.zig` | EDIT | New handler |
| `src/ai_workflow/tui/http_handlers/design_elements_reorder_test.zig` | EDIT | New behavioural tests |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | EDIT | If `DesignElementResponse` needs any reorder-specific field (likely no — same shape) |
| `src/ai_workflow/tui/on_event_sent_design.zig` | EDIT | Add `action: 'reordered'` SSE event variant |
| `src/apps/desktop/src/composables/useDesignHandlers.ts` | EDIT | Add `reorderSelection(mode)` function reusing the existing args shape + reuse `groupSelection` for the menu |
| `src/main.zig` | EDIT | Register the new `/reorder` route |
| `src/apps/desktop/src/__tests__/DesignContextMenu.spec.ts` | NEW | Behavioural tests for the menu component |
| `src/apps/desktop/src/__tests__/LayersPanel.contextMenu.spec.ts` | NEW | Behavioural tests for right-click in the layers panel |
| `src/apps/desktop/src/__tests__/DesignView.shortcut.spec.ts` | NEW | Behavioural tests for the new keyboard shortcuts |
| `src/apps/desktop/src/__tests__/DesignView.shiftClick.spec.ts` | NEW | Behavioural tests for canvas Shift+click toggle |

## Backend reorder endpoint (new)

**Route:** `POST /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reorder`

**Body:**
```json
{
  "mode": "bring_to_front" | "send_to_back" | "bring_forward" | "send_backward",
  "element_ids": ["elem_a", "elem_b"]
}
```

**Response 200:** `{ reordered: <DesignElementResponse>[] }` (the updated rows in their new z-order, top-to-bottom).

**Errors:**
- 400 `BadMode`, `NoElementIds`, `EmptyElementIds`
- 404 `PageNotFound`, `BadElementId` (an id doesn't resolve)
- 409 `CrossPageIds` (ids live on different pages)

**Model:** `design_model.reorderElements(alloc, db, .{ page_id, mode, element_ids })`. Implementation: load all elements on the page sorted by current `z_index DESC, position ASC`, then for each mode:

- `bring_to_front`: set `z_index = max_z + 1` on every selected id (preserving their relative order); bump subsequent elements if collisions
- `send_to_back`: set `z_index = min_z - 1` (preserving relative order)
- `bring_forward`: swap each selected id with the next-sibling ABOVE it in z-order (preserves multi-selection order — topmost selected element goes first)
- `send_backward`: mirror of `bring_forward` going downward

Wrap in `Transaction` (already in codebase — see `nalar-data-and-routines.md` §"SQLite Transaction Design"). Single round-trip; SSE `design_element_reordered` event emitted per row at the end.

**SSE wire:** add `action: 'reordered'` to the existing `DesignElementEvent` (api/index.ts:265). Payload is the full `DesignElement` (matches the existing `created`/`updated`/`deleted` shape). The existing SSE handler in the workspace store already dispatches by `action` so no consumer code change needed.

## Frontend wire

| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | New `reorderDesignElements(ws, item, page, { mode, element_ids })` → POSTs the new endpoint |
| `src/apps/desktop/src/stores/workspaces.ts` | New `reorderDesignElements(ws, item, page, mode, ids)` action that calls the API + mirrors the returned rows into `design_elements` |
| `src/apps/desktop/src/composables/useDesignHandlers.ts` | New `reorderSelection(mode)` exported function reusing the existing args shape |
| `src/apps/desktop/src/components/design/DesignView.vue` | `handleReorderElements(orderedIds)` stays for per-row ▲/▼ path; new `handleReorderByMode(mode)` calls the store action with `selectedIds` |

The existing `handleReorderElements` path stays as-is for now (it doesn't reach the backend today; that's pre-existing tech debt). The new `handleReorderByMode` is the canonical persist path and is what the context menu + new shortcuts use.

## Keyboard shortcuts (added to `DesignView.vue::handleKeydown`)

| Key | Condition | Action |
|---|---|---|
| `Cmd+A` / `Ctrl+A` | not in input | `selectedIds = new Set(elements.map(e => e.id))` |
| `Cmd+Shift+]` / `Ctrl+Shift+]` | selection.size ≥ 1 | `reorderSelection('bring_to_front')` |
| `Cmd+]` / `Ctrl+]` | selection.size ≥ 1 | `reorderSelection('bring_forward')` |
| `Cmd+[` / `Ctrl+[` | selection.size ≥ 1 | `reorderSelection('send_backward')` |
| `Cmd+Shift+[` / `Ctrl+Shift+[` | selection.size ≥ 1 | `reorderSelection('send_to_back')` |
| `Backspace` / `Delete` | selection.size ≥ 1, not in input | `confirm("Delete N elements?")` → `for (id of selectedIds) workspacesStore.deleteDesignElement(...)` |
| `Escape` | (existing) | clear selection; close any open context menu via `useDesignContextMenu.close()` |

**Cross-platform label conventions** (for the menu accelerator column):
- macOS: `⌘⇧]`, `⌘]`, `⌘[`, `⌘⇧[`, `⌘A`, `⌫`
- Linux / Windows: `Ctrl+Shift+]`, `Ctrl+]`, `Ctrl+[`, `Ctrl+Shift+[`, `Ctrl+A`, `Del`

Detect via `navigator.platform.includes('Mac')`. Stored once at module load so the menu doesn't recompute on every render.

**Input-focus guard preserved** (the existing `if (target.tagName === 'INPUT'...)` check stays at the top of `handleKeydown`). Backspace inside a `<PropertiesPanel>` input must NOT delete the selection — the existing guard catches this.

**Conflict notes:**
- `Cmd+A` overrides browser select-all-text in the canvas — `event.preventDefault()` is required.
- `Cmd+[ / ]` doesn't conflict with browser tab-switch (`Ctrl+Shift+Tab` etc.) because we use `Cmd` on macOS and `Ctrl` on Linux/Windows where `Ctrl+Tab` is the browser-tab shortcut. Users on Linux/Windows can use the menu instead.
- `Cmd+Shift+[` / `Cmd+Shift+]` is safe (no browser conflict on macOS).

## Component contracts

### `DesignContextMenu.vue`

```ts
defineProps<{
  /** Whether the menu is currently visible. The component renders nothing when false. */
  visible: boolean
  /** Viewport-relative x coordinate of the menu's top-left corner (clientX from the contextmenu event). */
  x: number
  /** Viewport-relative y coordinate. */
  y: number
  /** The element ids the menu actions will operate on. Empty = no selection (menu still renders but all items except Select all are disabled). */
  targetIds: string[]
}>()

defineEmits<{
  /** Fires when the user picks "Group selection". Payload: the targetIds the menu had at open time. */
  group: [targetIds: string[]]
  /** Fires when the user picks "Select all". */
  selectAll: []
  /** Each reorder variant fires its own event so the consumer doesn't need to switch on a discriminator. */
  bringToFront:  [targetIds: string[]]
  bringForward:  [targetIds: string[]]
  sendBackward:  [targetIds: string[]]
  sendToBack:    [targetIds: string[]]
  /** Fires when the user picks "Delete". The consumer owns the confirm() + store-action loop. */
  delete:        [targetIds: string[]]
  /** Fires when the menu should close (Escape, click-outside, scroll, route change). */
  close:         []
}>()
```

**Rendering rules:**
- When `visible = false`, the component renders nothing (no empty `<div>` left in the DOM — avoids stray event listeners).
- Uses `<Teleport to="body">` so the menu floats above everything else (matches `GitChanges.vue` pattern).
- `pointer-events: auto` on the menu div (default).
- `z-index: 50` matches the existing `fixed top-3 right-3 z-50` badge convention.

**Edge clamping:**
- If `x + estimatedMenuWidth > window.innerWidth - 8`, shift left so the menu's right edge sits at `window.innerWidth - 8`.
- If `y + estimatedMenuHeight > window.innerHeight - 8`, shift up so the menu's bottom edge sits at `window.innerHeight - 8`.
- Estimated dimensions: 220px wide × 40px per item. Items render top-to-bottom in a fixed order so the height is deterministic.
- Recompute on `window resize` (close the menu — easier than recomputing geometry mid-session).

### `useDesignContextMenu.ts`

```ts
export function useDesignContextMenu(): {
  /** Open the menu at the given viewport coordinates, targeting the given element ids. */
  open: (event: MouseEvent, targetIds: string[]) => void
  /** Close the menu without firing any action. */
  close: () => void
  /** Reactive state — read by `<DesignContextMenu>` and by callers that want to know if a menu is up. */
  state: ComputedRef<{ visible: boolean; x: number; y: number; targetIds: string[] }>
}
```

**Lifecycle listeners** (registered in `onMounted` of whichever component mounts the menu — `LayersPanel.vue` AND `DesignView.vue` separately, each with their own composable instance):
- `document click` (capture: false) → close
- `document keydown Escape` → close + emit `close` event
- `window resize` → close
- `window scroll` (capture: true) → close (catches scroll inside the layers panel overflow)
- The `contextmenu` event itself does NOT bubble to `document` because we call `event.preventDefault()` — so the click-outside listener doesn't race with the open call.

## Tests (behavioural only — no static-contract / source-grep tests)

Per the project-wide rule saved in `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`, every test below exercises real code paths via real calls + crafted inputs + assertions on return values.

### `design_elements_reorder_test.zig` (backend)

- 4 per-mode round-trips: `bring_to_front` / `send_to_back` / `bring_forward` / `send_backward` on a 3-element page, asserting new `z_index` values per row + that the returned `reordered` array is in the expected order.
- Cross-page rejection: insert one element on a different page; assert `error.CrossPageIds` propagates through `useCase`.
- Empty-element-ids: `useCase` with `element_ids: []` returns `error.EmptyElementIds`.
- Bad-mode: `useCase` with `mode: 'banana'` returns `error.BadMode`.
- PageNotFound: `useCase` with a missing `page_id` returns `error.PageNotFound`.
- BadElementId: `useCase` with an id not on the page returns `error.BadElementId`.
- Multi-select `bring_to_front`: select 3 of 5 elements, assert those 3 end up at the top, the other 2 stay in their relative order.

### `DesignContextMenu.spec.ts` (frontend)

- Mount with items array; assert each item's label + accelerator renders as a button.
- Click on a "Group" item; assert the menu emits the right payload.
- Mount with all items disabled (empty selection); assert disabled items don't emit on click and have the `disabled` attribute.
- Mount near the right edge of the viewport; assert the menu's `left` is clamped to viewport - menu width.

### `LayersPanel.contextMenu.spec.ts` (frontend)

- Mount with elements, dispatch `contextmenu` event on a row's DOM, assert `<DesignContextMenu>` becomes visible with that row's id as the only targetId.
- Mount with multi-selection, dispatch `contextmenu` on a row that's NOT in the selection, assert the menu opens with just that one id (single-element path).
- Mount with multi-selection, dispatch `contextmenu` on a row that IS in the selection + `shiftKey: true`, assert the menu opens with the full selection as targetIds.
- Mount with `readonly: true`, dispatch `contextmenu`, assert the menu does NOT render.

### `DesignView.shortcut.spec.ts` (frontend)

- Mount DesignView with 3 elements; dispatch `keydown` for `Cmd+A`; assert `vm.selectedIds` has all 3 ids.
- Dispatch `Cmd+Shift+]`; assert `workspacesStore.reorderDesignElements` was called with `mode: 'bring_to_front'` and the selected ids.
- Dispatch `Backspace` with `selection.size = 2`; assert `confirm()` was called with "Delete 2 elements?" and `workspacesStore.deleteDesignElement` was called for each id.
- Dispatch `Cmd+A` while focus is in an `<input>`; assert `selectedIds` does NOT change (input-focus guard).
- Dispatch `Cmd+Shift+]` while `selectedIds.size === 0`; assert no reorder call (no-op gate).

### `DesignView.shiftClick.spec.ts` (frontend)

- Mount DesignView with 3 elements; dispatch `click` on element B (no shift); assert `selectedIds` is `{B}`.
- Dispatch `click` on element C with `shiftKey: true`; assert `selectedIds` is `{B, C}`.
- Dispatch `click` on element C again with `shiftKey: true`; assert `selectedIds` is `{B}` (toggle off).
- Dispatch `click` on element A with `shiftKey: true`; assert `selectedIds` is `{A, B}` (additive — A was not previously selected).

**Total:** ~25 behavioural tests across 5 files (1 backend, 4 frontend).

## Chunk decomposition (for the implementation plan)

Following the project's existing pattern of multi-chunk plans (one chunk per PR-sized change):

| Chunk | Scope | Files |
|---|---|---|
| **1. `useDesignContextMenu` + `DesignContextMenu` skeleton** | Composable + component with `visible / x / y / targetIds` props. Open / close lifecycle. Click-outside / Escape / scroll dismiss. Renders nothing yet (just an empty div for layout testing). Tests: `DesignContextMenu.spec.ts` mount + visible toggle + click-outside dismiss. | NEW: composable, component, spec |
| **2. LayersPanel right-click → context menu → Group** | LayerRow `@contextmenu` → LayersPanel handler → `useDesignContextMenu.open(...)` → menu renders → user picks "Group selection" → fires `useDesignHandlers.groupSelection()`. Tests: `LayersPanel.contextMenu.spec.ts` (4 behavioural tests). | EDIT: LayersPanel, LayerRow, DesignView |
| **3. Canvas right-click + canvas Shift+click toggle** | Add `@contextmenu` on the canvas div, shift-click toggles in selection on `<DesignElement>` select emit. Tests: `DesignView.shiftClick.spec.ts` (4 behavioural tests). | EDIT: DesignView, DesignElement |
| **4. Keyboard shortcuts (Cmd+A / Cmd+[ / ] / Backspace)** | Extend `DesignView::handleKeydown` with the new shortcuts. Tests: `DesignView.shortcut.spec.ts` (5 behavioural tests). | EDIT: DesignView |
| **5. Backend reorder endpoint + wire into context menu** | New `design_elements_reorder.zig` + model function + route registration + frontend store action + API wrapper + wire into the menu's 4 reorder events. Tests: `design_elements_reorder_test.zig` (10 behavioural tests) + 2 frontend integration tests via the context menu. | NEW: handler, test, store action; EDIT: model, main.zig, store, api, context menu wiring |

Each chunk ships as its own commit. Each chunk has its own behavioural test file. The chunks are independent enough to land in any order, but the recommended order is 1 → 2 → 3 → 4 → 5 because:
- Chunk 1 establishes the menu shell that chunks 2 + 5 plug into.
- Chunk 2 ships the headline user-visible feature (right-click → Group).
- Chunk 3 + 4 add the parity improvements.
- Chunk 5 lands the heavier backend work last (single biggest blast radius).

## Success criteria

The feature is "done" when ALL of the following pass on a fresh `zig build test`, `bun run build`, `bunx vitest run`, AND a manual smoke test:

### Automated

1. `cd /home/ginwa/ginwaaitoolbox && timeout 180 zig build test --summary all` — all pre-existing tests still pass + new behavioural tests pass.
2. `timeout 180 zig build install:linux:system` — Linux binary builds clean (no `addExecutable`-only errors lurking).
3. `rm -rf zig-out/bin && timeout 360 zig build` — fresh rebuild from scratch passes.
4. `cd src/apps/desktop && timeout 180 bun run build` — vue-tsc + vite build clean (NOT just `bunx vitest run` — see `nalar-frontend-patterns.md` §"`bun run build` is the type-check").
5. `timeout 180 bunx vitest run` — full frontend suite passes.
6. `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig` and `... -target aarch64-macos -lc ...` — cross-compile smoke (catches Windows/macOS-only compile errors).

### Manual smoke (port 8080, NEVER 8081 — see `project-working-patterns.md`)

1. Boot `nalar --port 8080` against an isolated `$HOME=/tmp/right-click-smoke`.
2. Create a design item with one page containing 3 elements (rectangle, frame, text).
3. **Right-click on a layer row** → context menu appears at cursor → click "Group selection" (no other rows selected, so disabled) — menu items disabled correctly.
4. **Shift+click two layer rows** → both highlight → right-click on either → menu shows "Group selection" enabled → click it → the two elements become children of a new `Group` element at the top of the layer tree (verified by re-fetching `GET /api/workspaces/:w/items/:i/design/pages/:p/elements`).
5. **Right-click on the canvas background** → context menu → "Select all" → all 3 elements highlight in the layers panel + canvas outlines appear.
6. **Press Cmd+A** → same selection state.
7. **Press Cmd+Shift+]** with 1 element selected → that element jumps to the top of the layers panel (new `z_index` visible in DB).
8. **Press Backspace** with 2 elements selected → confirm dialog → elements gone.
9. **Switch to Preview mode** (Cmd+P) → right-click anywhere → menu does NOT appear.
10. **Open a second tab to the same design item** → in tab A, press Cmd+Shift+] on an element → in tab B, the layer panel reflects the new order within ~500ms (SSE-driven).

## Edge cases handled

- **Empty layers panel** right-click → menu disabled / hidden (no elements to act on).
- **Right-click on a row that's NOT in the current selection** → the menu targets just that one element (single-element actions like Bring to front still work; Group is disabled).
- **Right-click on a row that IS in the current selection with `event.shiftKey`** → menu targets the whole selection (Figma parity: shift-right-click extends).
- **`readonly = true`** → entire `<DesignContextMenu>` is not rendered.
- **Page switching mid-menu** → `useDesignContextMenu.close()` fires on every `activePageId` change (already happens naturally — `selectedIds` resets to empty on page switch).
- **Modal/dialog open** (e.g. `AddDesignElementDialog`) → menu is closed via `useDesignContextMenu.close()` when the dialog opens (a watcher in `DesignView`).
- **Window resize** → menu closes (no mid-session geometry recompute).
- **Scroll inside the layers panel** → menu closes (capture phase listener).
- **Two `<DesignView>` instances mounted simultaneously** (chat-open / chat-closed branches in AppLayout) → each gets its own `useDesignContextMenu()` instance with separate state.
- **Cross-platform accelerators** → detected once at module load via `navigator.platform.includes('Mac')`.

## Open questions (none remaining)

All design decisions resolved. No follow-up questions for the implementation plan.

## References

- Plan file: `docs/superpowers/plans/2026-07-29-design-right-click-group-menu.md`
- Predecessor: PR #136 — grouped layers (frame/group nesting) on design canvas
- Predecessor: PR #125 — design element drag-and-drop (Figma-style)
- Pattern reference: `src/apps/desktop/src/components/git/GitChanges.vue` (Teleport-based context menu)
- Pattern reference: `src/apps/desktop/src/composables/useDesignHandlers.ts` (composable that owns design-related store actions)
- Memory: `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md` (never use static-contract tests)
- Memory: `~/.config/nalar/memories/nalar-frontend-patterns.md` (bun run build IS the type-check)
- Memory: `~/.config/nalar/memories/nalar-data-and-routines.md` (SQLite Transaction Design)