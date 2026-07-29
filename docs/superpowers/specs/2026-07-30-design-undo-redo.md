# Design: Undo/Redo for design mode (element-level)

**Status:** Draft — awaiting user review (2026-07-30)

**Related work:** Builds on §3.8 design canvas. Pre-existing silent-drop bugs
(LayersPanel ▲/▼, Monaco Save) are wired in Chunk 1 as a prerequisite for the
scope's affected rows. Plan: `docs/superpowers/plans/2026-07-30-design-undo-redo.md`.

---

## Goal

Add keyboard undo/redo (`Cmd+Z` / `Cmd+Shift+Z` / `Cmd+Y`) to the design canvas
with per-page history stacks. Captures the "one entry per gesture" semantic
(drag, resize, rename, properties edit, HTML body edit, delete, reorder, group)
at the natural gesture boundaries that already exist in the codebase (50 ms
throttled emit + trailing emit on `pointerup` in `DesignElement.vue`, `@change`
on inputs in `PropertiesPanel.vue`, Save button for Monaco). Mirrors the
Approach A (client-only) design from the brainstorm and the Figma/Excalidraw
UX convention.

**Architecture:** Client-only in-memory history stack (Pinia store slice +
`useDesignHistory` composable). No backend changes, no schema migration.
Per-page stack capped at 100 entries. LocalStorage-backed (debounced 500 ms)
for refresh resilience. Cleared on page switch.

## Out of scope (explicit YAGNI)

- **Page-level mutations** (create page, delete page, rename page, change
  width/height). Deferred — page operations are rare and would need a larger
  snapshot (the whole page + all elements + all HTML files). Spec §3.8 row
  remains unchanged.
- **The `+ Element` dialog silent-drop bug.** Pre-existing — the dialog submit
  emits `createElement` upward but `AppLayout.vue` has no listener. Not in the
  user's selected scope; the wire-up is a separate follow-up.
- **Ungroup (`Cmd+Shift+G`).** No backend endpoint exists yet. Add when ungroup
  ships.
- **LLM tool mutations** (`add_element`, `update_element`, `set_design_page`
  agent tools). These bypass the UI gesture boundary entirely. Server-side
  complement (Approach B in the brainstorm) is a future plan.
- **Multi-page undo (undo across pages).** Each page has its own stack in v1.
- **Cross-session undo.** LocalStorage restore is opportunistic — if the page
  changes server-side, the stack is silently discarded.
- **Collaborative undo.** Single-user app.
- **Marquee drag-select.** Not needed for undo.

## Architecture overview

Six pieces, frontend-only, no backend changes:

1. **`composables/useDesignHistory.ts`** — Owns the push/pop API + capture
   helpers. Pure UI logic, no direct store access. Returns `{ canUndo,
   canRedo, nextUndoLabel, nextRedoLabel, undo, redo, capturePreState,
   capturePostState, captureDelete, captureCreate, captureReorder,
   captureGroup }`.
2. **`stores/designHistory.ts`** (Pinia) — Holds the per-page stacks
   `Record<pageId, {past: HistoryEntry[], future: HistoryEntry[]}>`. Auto-syncs
   to localStorage (debounced 500 ms). Clears `future` on any new push.
3. **`components/design/DesignHistoryButtons.vue`** — Two toolbar buttons
   (undo + redo) with disabled states and tooltips showing the next entry's
   label.
4. **Gesture-boundary capture points** — 10 instrumented call sites in
   `DesignView.vue`, `DesignElement.vue`, `PropertiesPanel.vue`,
   `LayersPanel.vue`, `DesignContextMenu.vue`. Each captures pre-state at
   gesture start, compares against post-state at gesture end, pushes an entry
   if different.
5. **Keyboard shortcuts** — `Cmd+Z` / `Ctrl+Z` (undo), `Cmd+Shift+Z` /
   `Ctrl+Shift+Z` and `Cmd+Y` / `Ctrl+Y` (redo). Bound in `DesignView.vue`'s
   existing `handleKeydown`. Input-focus guard preserves browser-native
   text-input undo.
6. **Wire-up of 2 silently-dropped emits** (Chunk 1 prerequisite) —
   `LayersPanel.vue` ▲/▼ → `reorderDesignElements`;
   `PropertiesPanel.vue` Monaco Save → `updateDesignElementHtml`. Tiny
   1-line route fixes; the store actions already exist.

## History entry shape

```ts
type HistoryEntry = {
  id: string                          // ULID for dedup
  timestamp: number                   // Date.now()
  label: string                       // "Move element", "Delete 3 elements",
                                       //  "Group 2 elements"
  pageId: string                      // page this entry belongs to
  kind: EntryKind
  // For geometry/style/rename (single or multi-element):
  changes?: Array<{
    elementId: string
    before: Partial<DesignElement>   // only the fields that changed
    after: Partial<DesignElement>
  }>
  // For delete (single or batch):
  deletedElements?: Array<{
    element: DesignElement
    htmlBody: string | null           // null if no file_path
  }>
  // For group:
  groupOp?: {
    parentId: string                 // the new parent id
    childIds: string[]
    beforeParentExisted: boolean     // always false in v1 (no ungroup)
  }
  // For reorder:
  reorderOp?: {
    beforeOrder: string[]            // z-index order top→bottom
    afterOrder: string[]
  }
}
```

**Reconciliation:** Every `forward(entry)` and `inverse(entry)` call applies
the captured payload to the backend via the existing store actions, then
patches the local store. Failures (404, SSE conflict) are reported via the
notification store — the entry stays on the stack and the user can retry.

**HTML body capture:** For any entry that touches an element with a non-null
`file_path`, capture the HTML body alongside the row fields. Restore on
inverse. This is mandatory for delete+undo and create+undo (or the element
comes back with a blank body).

**No-op detection:** At capture time, compare `before` to `after` field-by-field.
If equal, skip the push. (Same gesture can be a no-op when the user drags an
element back to its starting position.)

**Capacity:** 100 entries per page. When the cap is hit, evict the oldest
entry from `past`. The `future` stack is unbounded within a single session.

**localStorage persistence:**
- Key: `design-history:v1:<workspaceId>:<itemId>:<pageId>`
- Value: JSON-serialized `{past: Entry[], future: Entry[]}`
- Saved debounced 500 ms after every push
- Loaded on `setActiveDesignPage(pageId)` (don't restore on every page mount)
- Cleared on page switch (Figma parity — redo stack lost on page change)
- Versioned via the `:v1:` segment; future migrations bump the segment and
  silently discard old buckets

## Component / file touch map

| File | Action | Purpose |
|---|---|---|
| `src/apps/desktop/src/composables/useDesignHistory.ts` | NEW | Core composable: push/pop, capture helpers, inverse/forward application |
| `src/apps/desktop/src/stores/designHistory.ts` | NEW | Pinia store slice: per-page stacks, localStorage sync |
| `src/apps/desktop/src/components/design/DesignHistoryButtons.vue` | NEW | Toolbar undo/redo buttons with disabled state + tooltip |
| `src/apps/desktop/src/composables/useDesignHandlers.ts` | EDIT | Add `updateElementHtml`, `reorderSelection` methods |
| `src/apps/desktop/src/components/design/DesignView.vue` | EDIT | Keyboard shortcuts; toolbar mount; gesture capture at drag/resize/group-drag/delete/reorder boundaries |
| `src/apps/desktop/src/components/design/DesignElement.vue` | EDIT | Emit `pointerdown` start marker; add gesture capture at pointerup trailing emit |
| `src/apps/desktop/src/components/design/PropertiesPanel.vue` | EDIT | Capture pre-state on focus, post-state on `@change`; wire Monaco Save emit to `useDesignHandlers.updateElementHtml` |
| `src/apps/desktop/src/components/design/LayersPanel.vue` | EDIT | Wire ▲/▼ emits to `useDesignHandlers.reorderSelection` (currently silent-drop) |
| `src/apps/desktop/src/components/design/DesignContextMenu.vue` | EDIT | Add `data-testid` for testability |
| `src/apps/desktop/src/components/AppLayout.vue` | EDIT | Mount `<DesignHistoryButtons>` in the design toolbar slot |
| `src/apps/desktop/src/__tests__/useDesignHistory.spec.ts` | NEW | 8 behavioural tests |
| `src/apps/desktop/src/__tests__/designHistoryStore.spec.ts` | NEW | 6 behavioural tests |
| `src/apps/desktop/src/__tests__/DesignHistoryButtons.spec.ts` | NEW | 4 behavioural tests |
| `src/apps/desktop/src/__tests__/DesignView.undo.spec.ts` | NEW | 8 behavioural tests |
| `src/apps/desktop/src/__tests__/DesignView.redo.spec.ts` | NEW | 3 behavioural tests |
| `src/apps/desktop/src/__tests__/LayersPanel.reorder.spec.ts` | NEW | 1 wire-up regression test |
| `src/apps/desktop/src/__tests__/PropertiesPanel.htmlSave.spec.ts` | NEW | 1 wire-up regression test |

**Total:** ~17 files (7 NEW, 10 EDIT), ~2 160 lines new code.

## Keyboard shortcuts (added to `DesignView.vue::handleKeydown`)

| Shortcut | Action | Notes |
|---|---|---|
| `Cmd/Ctrl+Z` | Undo | Pops one entry from `past`, applies inverse, pushes previous forward to `future` |
| `Cmd/Ctrl+Shift+Z` | Redo (mac convention) | Pops one entry from `future`, applies forward, pushes inverse to `past` |
| `Cmd/Ctrl+Y` | Redo (Windows convention) | Same as `Cmd+Shift+Z` |
| `Cmd/Ctrl+Z` while input focused | **No-op** | Browser's native input-level undo; do not capture at canvas level |

**Input-focus guard:** When the focus is in an `<input>` / `<textarea>` /
contenteditable, the browser's native undo handles `Cmd+Z` for text. The
canvas listener must skip when `event.target` is an editable element.

## Component contracts

### `useDesignHistory(pageId: ComputedRef<string>)` composable

```ts
type UseDesignHistory = {
  // Stack state
  canUndo: ComputedRef<boolean>
  canRedo: ComputedRef<boolean>
  nextUndoLabel: ComputedRef<string | null>
  nextRedoLabel: ComputedRef<string | null>

  // Direct stack actions
  undo(): Promise<void>
  redo(): Promise<void>

  // Capture helpers (called from gesture sites)
  capturePreState(ids: string[]): void                       // sets internal pre-state
  capturePostState(ids: string[]): Promise<void>             // pushes entry if changed
  captureDelete(elements: Array<{element: DesignElement, htmlBody: string | null}>): Promise<void>
  captureCreate(element: DesignElement, htmlBody: string | null): Promise<void>
  captureReorder(beforeOrder: string[], afterOrder: string[]): Promise<void>
  captureGroup(parentId: string, childIds: string[], beforeParentExisted: boolean): Promise<void>
}
```

### `stores/designHistory.ts` (Pinia)

```ts
export const useDesignHistoryStore = defineStore('designHistory', () => {
  const stacksByPage = ref<Record<string, {past: HistoryEntry[], future: HistoryEntry[]}>>({})

  function getStack(pageId: string): {past: HistoryEntry[], future: HistoryEntry[]}
  function push(pageId: string, entry: HistoryEntry): void
  function popPast(pageId: string): HistoryEntry | null
  function popFuture(pageId: string): HistoryEntry | null
  function clearPage(pageId: string): void
  function clearAll(): void
})
```

### `DesignHistoryButtons.vue`

Two buttons with `data-testid="design-undo-button"` /
`data-testid="design-redo-button"`, tooltips showing the next label, disabled
state bound to `canUndo` / `canRedo`. Click handlers call
`useDesignHistory.undo()` / `redo()`.

## Tests (behavioural only)

Per project-wide rule (`~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`),
every test below is a real call + assertion.

### `useDesignHistory.spec.ts`

- Push then pop returns the same entry
- Push A, push B → pop returns B → pop returns A
- Push + undo + push → `future` is cleared (redo lost)
- Push then no-op (no change) → entry not pushed
- Push 101 entries → oldest is evicted
- Multi-element capture: `capturePreState([A, B])`, `capturePostState([A, B])` → one entry with both changes
- Delete capture: `captureDelete([{element, htmlBody: '<div>foo</div>'}])` → entry has full element + html
- Group capture: `captureGroup(parent, [A, B], false)` → one entry with `groupOp.block` set

### `designHistoryStore.spec.ts`

- `getStack(missingPageId)` returns `{past: [], future: []}` (no error)
- `push` to a new page creates the stack
- `clearPage` removes both `past` and `future`
- `localStorage.getItem('design-history:v1:ws:item:page')` returns JSON after pushes
- localStorage key format: `design-history:v1:<workspaceId>:<itemId>:<pageId>`
- Schema version mismatch: discard localStorage content silently

### `DesignHistoryButtons.spec.ts`

- Renders two buttons with `data-testid="design-undo-button"` and `data-testid="design-redo-button"`
- Disabled state: `canUndo=false` → undo button disabled; `canRedo=false` → redo button disabled
- Tooltip: shows `nextUndoLabel` / `nextRedoLabel` text
- Click on undo button → calls `useDesignHistory.undo()` once

### `DesignView.undo.spec.ts`

- Mount DesignView with 1 element; dispatch `keydown` for `Cmd+Z` (no captures happened) → no API call (entry stack empty)
- Drag element from `x=0` to `x=100` → 1 entry on `past`; dispatch `Cmd+Z` → element back at `x=0`; dispatch `Cmd+Shift+Z` → element at `x=100`
- Arrow-key nudge selection of 2 elements → 5 entries (one per keypress); undo 5 times → positions back to start
- Backspace with 2 elements selected → 1 entry; undo → both elements restored
- `Cmd+G` with 2 elements → 1 entry; undo → group removed, 2 children back at top-level
- Bring/Send (`Cmd+]`) → 1 entry; undo → z-order back
- Input-focus guard: focus `<input>`; dispatch `Cmd+Z`; assert no undo call
- Selection of 1 element + drag → 1 entry (not 2)

### `DesignView.redo.spec.ts`

- Push A → undo → `canRedo=true`; push B → `canRedo=false` (future cleared)
- `Cmd+Y` behaves identically to `Cmd+Shift+Z`
- Redo past the end of the `future` stack → no-op, no error

### `LayersPanel.reorder.spec.ts` (wire-up regression)

- Mount with 3 elements; click ▲ on row 2 → `workspacesStore.reorderDesignElements` called with `mode: 'bring_forward'`; history entry pushed

### `PropertiesPanel.htmlSave.spec.ts` (wire-up regression)

- Mount with 1 element; mock Monaco; click Save → `workspacesStore.updateDesignElementHtml` called; history entry pushed

**Total:** ~40 behavioural tests across 8 files.

## Chunk decomposition

| Chunk | Theme | Files | Tests |
|---|---|---|---|
| **C1 — Wire-up** (prerequisite) | Fix 2 silently-dropped emits: LayersPanel ▲/▼, Monaco Save | 2 files EDIT | 2 spec files |
| **C2 — Composable + store** | `useDesignHistory` + Pinia store + localStorage | 3 files NEW | 2 spec files |
| **C3 — Buttons + keyboard** | `DesignHistoryButtons.vue` + `Cmd+Z`/`Shift+Z`/`Y` bound in DesignView | 2 files NEW+EDIT | 1 spec file |
| **C4 — Geometry capture** | Wire drag/resize/nudge/PropertiesPanel geometry to capture+commit | 3 files EDIT | 1 spec file |
| **C5 — Delete + reorder + group capture** | Wire delete/backspace/Cmd+]/Cmd+G to capture+commit | 4 files EDIT | 1 spec file |
| **C6 — HTML body capture + integration tests** | Ensure HTML body is captured in delete/create entries + extend C4/C5 specs | 1 file EDIT | extend C4/C5 specs |
| **C7 — End-to-end + manual smoke** | Full undo cycle test + manual smoke recipe | 1 spec file ADD | 1 spec file |

## Success criteria

### Automated

1. `cd /home/ginwa/ginwaaitoolbox && timeout 180 zig build test --summary all` —
   all pre-existing tests pass + new tests pass (no backend changes, should be
   0 regressions).
2. `timeout 180 zig build install:linux:system` — Linux binary builds clean.
3. `cd src/apps/desktop && timeout 180 bun run build` — vue-tsc + vite build
   clean (NOT just `bunx vitest run` — see `nalar-frontend-patterns.md`).
4. `timeout 180 bunx vitest run` — full frontend suite passes.

### Manual smoke (port 8080, NEVER 8081 — see `project-working-patterns.md`)

1. Boot `nalar --port 8080` against `$HOME=/tmp/undo-smoke`.
2. Create a design item with 1 page and 3 elements.
3. Drag element A 100 px right → drag element B 50 px down → click Undo
   (twice) → A and B return to original positions.
4. Delete element C → click Undo → C restored.
5. Group A and B → click Undo → group removed, A and B back at top-level.
6. Edit HTML body of A via Monaco → click Save → click Undo → body reverts.
7. Refresh page → history persists (drags undo-undo works after refresh).
8. Switch tabs (Pages) → history for previous page is preserved (re-open page
   → entries are there).

## Edge cases handled

- **No-op gestures** (drag back to start) → no entry pushed.
- **Multi-element drag** (2 elements selected + drag) → 1 entry with both
  changes.
- **Arrow-key nudge** (multi-select + 5 keypresses) → 5 entries (Figma
  parity).
- **Group + drag + delete + undo** → undo restores group, then undo restores
  last delete, etc.
- **HTML body change** (Monaco Save on element) → entry captures before/after
  HTML body.
- **Delete element with HTML body** → entry captures full element + HTML body.
- **Undo while a request is in flight** → queue the undo, apply after request
  completes. (Drag trailing emit + undo race.)
- **localStorage schema version mismatch** → discard silently.
- **Page switch** → redo stack cleared (Figma parity).
- **Input focus** (PropertiesPanel input) → `Cmd+Z` is browser-native undo,
  canvas does not intercept.

## References

- `docs/SPEC.md` §3.8 (Frontend — Design Canvas)
- `docs/superpowers/specs/2026-07-29-design-right-click-group-menu.md` (sibling
  spec, same project conventions)
- `~/.config/nalar/memories/project-working-patterns.md` (verification before
  completion)
- `~/.config/nalar/memories/nalar-frontend-patterns.md` §"`bun run build` is the
  type-check"
- `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`
  (no static-contract tests)
- `.nalar/memories/applayout-close-handlers-strip-url-params.md` (silent-drop
  emit pattern — same bug class as the 2 wire-up bugs)
- `docs/superpowers/plans/2026-07-29-design-right-click-group-menu.md` (most
  recent design plan, same conventions)
