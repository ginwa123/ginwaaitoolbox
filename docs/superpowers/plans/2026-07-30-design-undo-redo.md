# Design Mode Undo/Redo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development
> (recommended) or executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add keyboard undo/redo (`Cmd+Z` / `Cmd+Shift+Z` / `Cmd+Y`) to the
design canvas with per-page history stacks. Captures the "one entry per
gesture" semantic (drag, resize, rename, properties edit, HTML body edit,
delete, reorder, group) at the natural gesture boundaries. Includes the
wire-up of 2 silently-dropped emits (LayersPanel ▲/▼, Monaco Save) as a
prerequisite. Mirrors the Approach A (client-only) design from the brainstorm
and the Figma/Excalidraw UX convention.

**Architecture:**

1. **NEW** `src/apps/desktop/src/composables/useDesignHistory.ts` — Core
   composable: push/pop API, capture helpers (`capturePreState`,
   `capturePostState`, `captureDelete`, `captureCreate`, `captureReorder`,
   `captureGroup`), undo/redo functions. Pure UI logic, no direct store
   access.
2. **NEW** `src/apps/desktop/src/stores/designHistory.ts` — Pinia store
   slice: `stacksByPage: Record<pageId, {past: HistoryEntry[], future:
   HistoryEntry[]}>`. Auto-syncs to localStorage (debounced 500 ms). Clears
   `future` on any new push.
3. **NEW** `src/apps/desktop/src/components/design/DesignHistoryButtons.vue`
   — Two toolbar buttons with disabled states + tooltips showing the next
   undo/redo entry's label.
4. **NEW** 7 test files (one per source file + 2 wire-up regressions).
5. **EDIT** `src/apps/desktop/src/components/design/DesignView.vue` — Add
   `Cmd+Z` / `Cmd+Shift+Z` / `Cmd+Y` keyboard shortcuts; mount
   `<DesignHistoryButtons>`; add gesture capture at drag/resize/group-drag/
   delete/reorder boundaries.
6. **EDIT** `src/apps/desktop/src/components/design/DesignElement.vue` — Emit
   `pointerdown` start marker; add gesture capture at pointerup trailing emit.
7. **EDIT** `src/apps/desktop/src/components/design/PropertiesPanel.vue` —
   Capture pre-state on focus, post-state on `@change`; wire Monaco Save emit
   to `useDesignHandlers.updateElementHtml`.
8. **EDIT** `src/apps/desktop/src/components/design/LayersPanel.vue` — Wire
   ▲/▼ emits to `useDesignHandlers.reorderSelection`.
9. **EDIT** `src/apps/desktop/src/components/design/DesignContextMenu.vue` —
   Add `data-testid` for testability.
10. **EDIT** `src/apps/desktop/src/components/AppLayout.vue` — Mount
    `<DesignHistoryButtons>` in the design toolbar slot.
11. **EDIT** `src/apps/desktop/src/composables/useDesignHandlers.ts` — Add
    `updateElementHtml`, `reorderSelection` methods.

**Tech Stack:** Vue 3 + TypeScript (project pin), Pinia 2, vitest 1.x,
@vue/test-utils 2.x, localStorage (browser native).

**Spec:** `docs/superpowers/specs/2026-07-30-design-undo-redo.md` (Draft,
awaiting user review)

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/design-undo-redo` on
branch `worktree/design-undo-redo`

**Decisions taken (with rationale):**

1. **Client-only history stack** — no backend changes, no schema migration.
   Matches Figma's UX. Per-page keys. Capped at 100 entries.
2. **LocalStorage persistence** — debounced 500 ms. Survives refresh.
   Discarded on schema version mismatch (`:v1:` segment in the key).
3. **Gesture-boundary capture** — pointerdown → capture pre-state; pointerup
   → capture post-state; push entry if changed. Matches the existing 50 ms
   throttled emit + trailing emit on pointerup pattern in `DesignElement.vue`
   (one trailing emit = one undo entry).
4. **Arrow-key nudge = 1 entry per keypress** (not "1 entry per gesture").
   Figma parity; matches the user's stated semantic.
5. **Delete/backspace = 1 entry per gesture** (multi-select blanket-delete).
   Captures all N elements + their HTML bodies in one entry.
6. **HTML body captured in every entry that touches an element** — guarantees
   delete+undo restores the body. Cost: ~5 KB per entry average; bounded by
   100-entry cap = ~500 KB per page.
7. **Wire-up of 2 silently-dropped emits** (LayersPanel ▲/▼, Monaco Save) is
   Chunk 1 — same bug class as `applayout-close-handlers-strip-url-params.md`.
   The user's scope includes "LayersPanel ▲/▼" and "Edit HTML body (Monaco
   Save)" so the wire-up is mandatory for those rows to be undoable. The third
   silent-drop (+ Element dialog) is NOT in scope and remains a follow-up.
8. **No new dependencies** — use Pinia (already in) + localStorage (already in
   browser) + VueUse `useDebounceFn` (already in for debounce).
9. **Per-page history** — switching pages clears the redo stack (Figma
   parity). The `past` stack is preserved per page across tab/mount cycles.
10. **No `useDesignHistory` for the agent tool mutations** — they bypass the
    UI gesture boundary. Adding them is a separate plan (Approach B follow-up).

## Global Constraints

- **Cross-platform** — frontend only, no platform-specific code. The
  localStorage key format uses `:` separators (Windows-friendly).
- **No static-contract tests** — every test is behavioural (real call +
  assertion). See `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`.
- **TDD** — every implementation task is preceded by a failing test step.
- **Behavioural Vue tests** use `@vue/test-utils` `mount` +
  `setActivePinia(createPinia())` in `beforeEach`. Mock fetch via `vi.fn()`
  returning `{ ok, status, json, text }` shape (see
  `nalar-frontend-patterns.md` §"`apiFetch` mock helpers need `text()`
  method").
- **Vue 3 conventions** — `ref` / `computed` / `defineProps` / `defineEmits`.
  Single-component-script-setup style.
- **No backend changes** — this is a frontend-only feature. No
  `design_model.zig`, no migration, no API changes.
- **Don't introduce new dependencies** — use Pinia (already in) + localStorage
  (already in browser) + VueUse `useDebounceFn` (already in).
- **Verification before completion** — `bun run build` + `bunx vitest run`
  must pass before any task is marked complete.
- **End-to-end smoke** — final task includes a manual smoke recipe against
  port 8080 (NEVER 8081).
- **Single commits per task** — one commit per task, message in the form
  `feat(<scope>): …` or `test(<scope>): red — …` per project convention.

## File Touch Map

| File | Action | Lines changed (est.) |
|---|---|---|
| `src/apps/desktop/src/composables/useDesignHistory.ts` | NEW | ~280 |
| `src/apps/desktop/src/stores/designHistory.ts` | NEW | ~180 |
| `src/apps/desktop/src/components/design/DesignHistoryButtons.vue` | NEW | ~110 |
| `src/apps/desktop/src/composables/useDesignHandlers.ts` | EDIT | +60 |
| `src/apps/desktop/src/components/design/DesignView.vue` | EDIT | +180 |
| `src/apps/desktop/src/components/design/DesignElement.vue` | EDIT | +40 |
| `src/apps/desktop/src/components/design/PropertiesPanel.vue` | EDIT | +90 |
| `src/apps/desktop/src/components/design/LayersPanel.vue` | EDIT | +50 |
| `src/apps/desktop/src/components/design/DesignContextMenu.vue` | EDIT | +10 |
| `src/apps/desktop/src/components/AppLayout.vue` | EDIT | +5 |
| `src/apps/desktop/src/__tests__/useDesignHistory.spec.ts` | NEW | ~280 |
| `src/apps/desktop/src/__tests__/designHistoryStore.spec.ts` | NEW | ~200 |
| `src/apps/desktop/src/__tests__/DesignHistoryButtons.spec.ts` | NEW | ~120 |
| `src/apps/desktop/src/__tests__/DesignView.undo.spec.ts` | NEW | ~280 |
| `src/apps/desktop/src/__tests__/DesignView.redo.spec.ts` | NEW | ~120 |
| `src/apps/desktop/src/__tests__/LayersPanel.reorder.spec.ts` | NEW | ~80 |
| `src/apps/desktop/src/__tests__/PropertiesPanel.htmlSave.spec.ts` | NEW | ~80 |

**Total: 17 files (7 NEW, 10 EDIT), ~2 160 lines new code.**

---

## Tasks

The plan is decomposed into 7 chunks. Each chunk is a sequence of TDD
red/green tasks ending with a literal commit.

---

## Chunk 1 — Wire-up of 2 silently-dropped emits (prerequisite)

### Task 1.1 — Wire `LayersPanel.vue` ▲/▼ to `reorderDesignElements` (RED)

**Goal:** Clicking ▲ or ▼ on a layer row triggers a `reorderDesignElements`
API call. Currently the emit goes nowhere.

**File:** `src/apps/desktop/src/__tests__/LayersPanel.reorder.spec.ts`

- [ ] **Step 1.1.1** — Create the test file at
  `src/apps/desktop/src/__tests__/LayersPanel.reorder.spec.ts` with imports,
  `setActivePinia(createPinia())` in `beforeEach`, and mock
  `workspacesStore.reorderDesignElements` via `vi.fn()`.
- [ ] **Step 1.1.2** — Add test "▲ button on layer row triggers
  `reorderDesignElements` with `mode: 'bring_forward'`": mount LayersPanel
  with 3 elements, click ▲ on row 2, assert store called with `mode:
  'bring_forward'` and the expected id list.
- [ ] **Step 1.1.3** — Add test "▼ button on layer row triggers
  `reorderDesignElements` with `mode: 'send_backward'`": same shape, opposite
  direction.
- [ ] **Step 1.1.4** — Run `timeout 60 bunx vitest run
  src/__tests__/LayersPanel.reorder.spec.ts` and confirm 0 tests pass (RED).
- [ ] **Step 1.1.5** — Commit: `git add
  src/apps/desktop/src/__tests__/LayersPanel.reorder.spec.ts && git commit -m
  "test(LayersPanel): red — ▲/▼ reorder wire-up tests"`.

### Task 1.2 — Wire ▲/▼ to the store (GREEN)

**File:** `src/apps/desktop/src/components/design/LayersPanel.vue`

- [ ] **Step 1.2.1** — Read `LayersPanel.vue` lines 212–244 to understand the
  current `handleMoveUp`/`handleMoveDown` shape.
- [ ] **Step 1.2.2** — Replace the `emit('reorder', ...)` calls with
  `workspacesStore.reorderDesignElements(workspaceId, itemId, pageId, mode,
  orderedIds)` where `mode` is `'bring_forward'` or `'send_backward'`.
- [ ] **Step 1.2.3** — Remove the now-unused `emit('reorder')` from
  `<LayerRow>` (or keep it if shared — your call).
- [ ] **Step 1.2.4** — Run `timeout 60 bunx vitest run
  src/__tests__/LayersPanel.reorder.spec.ts` and confirm 2/2 pass (GREEN).
- [ ] **Step 1.2.5** — Run `timeout 60 bunx vitest run
  src/__tests__/LayersPanel.contextMenu.spec.ts` and confirm no regression.
- [ ] **Step 1.2.6** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 1.2.7** — Run `timeout 180 bun run build 2>&1 | tail -n 20` and
  confirm clean (vue-tsc + vite).
- [ ] **Step 1.2.8** — Commit: `git add
  src/apps/desktop/src/components/design/LayersPanel.vue && git commit -m
  "fix(LayersPanel): wire ▲/▼ to reorderDesignElements (was silent-drop)"`.

### Task 1.3 — Wire `PropertiesPanel.vue` Monaco Save to
`updateDesignElementHtml` (RED)

**Goal:** Clicking "Save" in the Monaco HTML editor triggers an
`updateDesignElementHtml` API call. Currently the emit goes nowhere.

**File:** `src/apps/desktop/src/__tests__/PropertiesPanel.htmlSave.spec.ts`

- [ ] **Step 1.3.1** — Create the test file at
  `src/apps/desktop/src/__tests__/PropertiesPanel.htmlSave.spec.ts` with
  imports + `setActivePinia(createPinia())` in `beforeEach`. Mock
  `workspacesStore.updateDesignElementHtml` via `vi.fn()`.
- [ ] **Step 1.3.2** — Add test "Monaco Save button triggers
  `updateDesignElementHtml` with the new html body": mount PropertiesPanel
  with 1 element, expand the HTML editor, set the html body to `'<div>new
  content</div>'`, click Save, assert store called with the same body.
- [ ] **Step 1.3.3** — Run `timeout 60 bunx vitest run
  src/__tests__/PropertiesPanel.htmlSave.spec.ts` and confirm 0 tests pass
  (RED).
- [ ] **Step 1.3.4** — Commit: `git add
  src/apps/desktop/src/__tests__/PropertiesPanel.htmlSave.spec.ts && git
  commit -m "test(PropertiesPanel): red — Monaco Save wire-up test"`.

### Task 1.4 — Wire Monaco Save to the store (GREEN)

**File:** `src/apps/desktop/src/components/design/PropertiesPanel.vue`

- [ ] **Step 1.4.1** — Read `PropertiesPanel.vue` lines 198–200 to understand
  the current `handleHtmlSave` shape.
- [ ] **Step 1.4.2** — Change the emit to call
  `workspacesStore.updateDesignElementHtml(workspaceId, itemId, pageId,
  elementId, html)`. If the store action doesn't exist, add it to
  `workspaces.ts` wrapping `api.updateDesignElementHtml`. Mirror the
  `updateDesignElement` pattern at `workspaces.ts:1213–1233`.
- [ ] **Step 1.4.3** — Add `emit('htmlChanged', {elementId, html})` as a
  fallback for any parent that wires the emit (for tests + future use).
- [ ] **Step 1.4.4** — Run `timeout 60 bunx vitest run
  src/__tests__/PropertiesPanel.htmlSave.spec.ts` and confirm 1/1 pass.
- [ ] **Step 1.4.5** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 1.4.6** — Run `timeout 180 bun run build 2>&1 | tail -n 20` and
  confirm clean.
- [ ] **Step 1.4.7** — Commit: `git add
  src/apps/desktop/src/components/design/PropertiesPanel.vue
  src/apps/desktop/src/stores/workspaces.ts && git commit -m
  "fix(PropertiesPanel): wire Monaco Save to updateDesignElementHtml (was
  silent-drop) + add store action"`.

---

## Chunk 2 — Composable + store (the core)

### Task 2.1 — `useDesignHistory` composable (RED)

**Goal:** Composite API for push/pop/capture exists; the public shape matches
the spec.

**File:** `src/apps/desktop/src/__tests__/useDesignHistory.spec.ts`

- [ ] **Step 2.1.1** — Create the test file at
  `src/apps/desktop/src/__tests__/useDesignHistory.spec.ts` with imports,
  `setActivePinia(createPinia())` in `beforeEach`, and a `setup()` helper
  that mounts the composable with a `computed(() => 'page_test')` for
  `pageId`.
- [ ] **Step 2.1.2** — Add test "push then pop returns the same entry":
  call `capturePreState(['elem_A'])` then
  `capturePostState(['elem_A'])` with a mutation between, assert
  `entries.past[0].kind === 'update'`, call `undo()`, assert element back to
  pre-state.
- [ ] **Step 2.1.3** — Add test "push A, push B → pop returns B → pop
  returns A".
- [ ] **Step 2.1.4** — Add test "push + undo + push → future is cleared".
- [ ] **Step 2.1.5** — Add test "push then no-op (no change) → entry not
  pushed": call `capturePreState` + `capturePostState` with NO mutation
  between, assert `entries.past.length === 0`.
- [ ] **Step 2.1.6** — Add test "push 101 entries → oldest is evicted".
- [ ] **Step 2.1.7** — Add test "multi-element capture: 1 entry with both
  changes": capturePreState([A, B]); mutate A.x and B.x; capturePostState
  → assert entry has `changes.length === 2`.
- [ ] **Step 2.1.8** — Add test "delete capture: entry has full element +
  html": captureDelete([{element: elemA, htmlBody: '<div>foo</div>'}]) →
  assert entry has `deletedElements[0].element.id === 'elem_A'` and
  `deletedElements[0].htmlBody === '<div>foo</div>'`.
- [ ] **Step 2.1.9** — Add test "group capture: entry has groupOp":
  captureGroup(parent, [A, B], false) → assert entry has
  `groupOp.parentId` and `groupOp.childIds.length === 2`.
- [ ] **Step 2.1.10** — Run `timeout 60 bunx vitest run
  src/__tests__/useDesignHistory.spec.ts` and confirm 0 tests pass (RED).
- [ ] **Step 2.1.11** — Commit: `git add
  src/apps/desktop/src/__tests__/useDesignHistory.spec.ts && git commit -m
  "test(useDesignHistory): red — composable contract tests"`.

### Task 2.2 — `useDesignHistory` composable (GREEN)

**File:** `src/apps/desktop/src/composables/useDesignHistory.ts`

- [ ] **Step 2.2.1** — Create the file at
  `src/apps/desktop/src/composables/useDesignHistory.ts` with imports
  (`useDesignHistoryStore`, `useWorkspacesStore`, `useNotificationStore`).
- [ ] **Step 2.2.2** — Define the `HistoryEntry` interface (mirror the spec).
- [ ] **Step 2.2.3** — Implement `capturePreState(ids)` — store the FULL
  pre-state of each element (read from `workspacesStore`). Keep in a local
  `ref<Map<elementId, DesignElement>>`.
- [ ] **Step 2.2.4** — Implement `capturePostState(ids)` — read the
  post-state, diff against pre-state, push a `changes`-shape entry if any
  field changed. Use `workspacesStore.fetchDesignElement(id)` for the read
  (or read from the local store array directly if it's already there).
- [ ] **Step 2.2.5** — Implement `captureDelete(elements)` — push a
  `deletedElements`-shape entry.
- [ ] **Step 2.2.6** — Implement `captureCreate(element, htmlBody)` — push
  a `newElementId`-shape entry (kind: 'create').
- [ ] **Step 2.2.7** — Implement `captureReorder(beforeOrder, afterOrder)` —
  push a `reorderOp`-shape entry.
- [ ] **Step 2.2.8** — Implement `captureGroup(parentId, childIds,
  beforeParentExisted)` — push a `groupOp`-shape entry.
- [ ] **Step 2.2.9** — Implement `undo()` and `redo()` — pop from
  `past`/`future`, apply inverse/forward, push to the other side. Use
  `workspacesStore` actions for the actual API calls.
- [ ] **Step 2.2.10** — Export `canUndo`, `canRedo`, `nextUndoLabel`,
  `nextRedoLabel` as computed refs.
- [ ] **Step 2.2.11** — Run `timeout 60 bunx vitest run
  src/__tests__/useDesignHistory.spec.ts` and confirm 8/8 pass (GREEN).
- [ ] **Step 2.2.12** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 2.2.13** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 2.2.14** — Commit: `git add
  src/apps/desktop/src/composables/useDesignHistory.ts && git commit -m
  "feat(useDesignHistory): composable with push/pop/capture + undo/redo"`.

### Task 2.3 — Pinia store (RED)

**File:** `src/apps/desktop/src/__tests__/designHistoryStore.spec.ts`

- [ ] **Step 2.3.1** — Create the test file at
  `src/apps/desktop/src/__tests__/designHistoryStore.spec.ts` with imports.
- [ ] **Step 2.3.2** — Add test "`getStack(missingPageId)` returns `{past: [],
  future: []}` (no error)".
- [ ] **Step 2.3.3** — Add test "`push` to a new page creates the stack".
- [ ] **Step 2.3.4** — Add test "`clearPage` removes both past and future".
- [ ] **Step 2.3.5** — Add test "localStorage key format:
  `design-history:v1:<workspaceId>:<itemId>:<pageId>`": push entry, wait
  500 ms, assert `localStorage.getItem(...)` returns JSON.
- [ ] **Step 2.3.6** — Add test "schema version mismatch: discard
  localStorage content silently": pre-seed localStorage with a `:v0:`
  prefix, call `getStack`, assert stack is empty.
- [ ] **Step 2.3.7** — Run `timeout 60 bunx vitest run
  src/__tests__/designHistoryStore.spec.ts` and confirm 0 tests pass (RED).
- [ ] **Step 2.3.8** — Commit: `git add
  src/apps/desktop/src/__tests__/designHistoryStore.spec.ts && git commit -m
  "test(designHistoryStore): red — Pinia store contract tests"`.

### Task 2.4 — Pinia store (GREEN)

**File:** `src/apps/desktop/src/stores/designHistory.ts`

- [ ] **Step 2.4.1** — Create the file at
  `src/apps/desktop/src/stores/designHistory.ts` with imports.
- [ ] **Step 2.4.2** — Define `useDesignHistoryStore` with `stacksByPage` ref
  + `getStack`/`push`/`popPast`/`popFuture`/`clearPage`/`clearAll` actions.
- [ ] **Step 2.4.3** — Implement localStorage sync with `useDebounceFn`
  (VueUse) — debounced 500 ms, key format
  `design-history:v1:<workspaceId>:<itemId>:<pageId>`.
- [ ] **Step 2.4.4** — Implement schema version check on `getStack`:
  if localStorage key exists with `:v0:` prefix, discard.
- [ ] **Step 2.4.5** — Run `timeout 60 bunx vitest run
  src/__tests__/designHistoryStore.spec.ts` and confirm 6/6 pass (GREEN).
- [ ] **Step 2.4.6** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 2.4.7** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 2.4.8** — Commit: `git add
  src/apps/desktop/src/stores/designHistory.ts && git commit -m
  "feat(designHistoryStore): Pinia store with localStorage sync"`.

---

## Chunk 3 — Buttons + keyboard

### Task 3.1 — `DesignHistoryButtons.vue` (RED)

**File:** `src/apps/desktop/src/__tests__/DesignHistoryButtons.spec.ts`

- [ ] **Step 3.1.1** — Create the test file.
- [ ] **Step 3.1.2** — Add test "renders two buttons with `data-testid`":
  mount, assert `design-undo-button` and `design-redo-button` exist.
- [ ] **Step 3.1.3** — Add test "disabled state: `canUndo=false` → undo
  button disabled".
- [ ] **Step 3.1.4** — Add test "tooltip shows `nextUndoLabel` / `nextRedoLabel`
  text".
- [ ] **Step 3.1.5** — Add test "click on undo button → calls
  `useDesignHistory.undo()` once".
- [ ] **Step 3.1.6** — Run `timeout 60 bunx vitest run
  src/__tests__/DesignHistoryButtons.spec.ts` and confirm 0 tests pass (RED).
- [ ] **Step 3.1.7** — Commit: `git add
  src/apps/desktop/src/__tests__/DesignHistoryButtons.spec.ts && git commit -m
  "test(DesignHistoryButtons): red — toolbar button contract tests"`.

### Task 3.2 — `DesignHistoryButtons.vue` (GREEN)

**File:** `src/apps/desktop/src/components/design/DesignHistoryButtons.vue`

- [ ] **Step 3.2.1** — Create the file at
  `src/apps/desktop/src/components/design/DesignHistoryButtons.vue` with
  script-setup style.
- [ ] **Step 3.2.2** — Add props: `workspaceId: string`, `itemId: string`,
  `pageId: string`.
- [ ] **Step 3.2.3** — Call `useDesignHistory(computed(() => props.pageId))` to
  get `canUndo`, `canRedo`, `nextUndoLabel`, `nextRedoLabel`, `undo`, `redo`.
- [ ] **Step 3.2.4** — Render two buttons with `data-testid` and
  `:title="nextUndoLabel"` / `:title="nextRedoLabel"`.
- [ ] **Step 3.2.5** — Run `timeout 60 bunx vitest run
  src/__tests__/DesignHistoryButtons.spec.ts` and confirm 4/4 pass (GREEN).
- [ ] **Step 3.2.6** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 3.2.7** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 3.2.8** — Commit: `git add
  src/apps/desktop/src/components/design/DesignHistoryButtons.vue && git
  commit -m "feat(DesignHistoryButtons): toolbar undo/redo buttons"`.

### Task 3.3 — Keyboard shortcuts in DesignView (RED)

**File:** `src/apps/desktop/src/__tests__/DesignView.undo.spec.ts` (and
`DesignView.redo.spec.ts`)

- [ ] **Step 3.3.1** — Create the test file at
  `src/apps/desktop/src/__tests__/DesignView.undo.spec.ts`.
- [ ] **Step 3.3.2** — Add test "Mount DesignView with 1 element; dispatch
  `keydown` for `Cmd+Z` (empty stack) → no API call".
- [ ] **Step 3.3.3** — Add test "Input-focus guard: focus `<input>`; dispatch
  `Cmd+Z`; assert no undo call".
- [ ] **Step 3.3.4** — Add test "After an entry is pushed, dispatch `Cmd+Z`
  → `useDesignHistory.undo()` called once".
- [ ] **Step 3.3.5** — Create the test file at
  `src/apps/desktop/src/__tests__/DesignView.redo.spec.ts`.
- [ ] **Step 3.3.6** — Add test "After undo, dispatch `Cmd+Shift+Z` →
  `useDesignHistory.redo()` called once".
- [ ] **Step 3.3.7** — Add test "Cmd+Y behaves identically to Cmd+Shift+Z".
- [ ] **Step 3.3.8** — Run both spec files and confirm 0 tests pass (RED).
- [ ] **Step 3.3.9** — Commit: `git add
  src/apps/desktop/src/__tests__/DesignView.undo.spec.ts
  src/apps/desktop/src/__tests__/DesignView.redo.spec.ts && git commit -m
  "test(DesignView): red — keyboard shortcuts tests"`.

### Task 3.4 — Keyboard shortcuts in DesignView (GREEN)

**File:** `src/apps/desktop/src/components/design/DesignView.vue`

- [ ] **Step 3.4.1** — In `handleKeydown` (around line 498), add three new
  branches for `Cmd+Z`, `Cmd+Shift+Z`, `Cmd+Y` (after the existing
  Cmd+A/]/[/P/G handlers).
- [ ] **Step 3.4.2** — Add the input-focus guard: if `event.target` is an
  `<input>`, `<textarea>`, or contenteditable, skip and let the browser
  handle it.
- [ ] **Step 3.4.3** — Mount the composable: `const history =
  useDesignHistory(computed(() => activePageId.value))`.
- [ ] **Step 3.4.4** — In the new branches, call `history.undo()` / `redo()`
  and `event.preventDefault()`.
- [ ] **Step 3.4.5** — Run the test files and confirm 5/5 pass (GREEN).
- [ ] **Step 3.4.6** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 3.4.7** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 3.4.8** — Commit: `git add
  src/apps/desktop/src/components/design/DesignView.vue && git commit -m
  "feat(DesignView): Cmd+Z / Cmd+Shift+Z / Cmd+Y keyboard shortcuts"`.

### Task 3.5 — Mount `<DesignHistoryButtons>` in the toolbar

**File:** `src/apps/desktop/src/components/AppLayout.vue`

- [ ] **Step 3.5.1** — Find the design toolbar slot in `AppLayout.vue` (around
  lines 1919–1929 and 2016–2027).
- [ ] **Step 3.5.2** — Add `<DesignHistoryButtons :workspace-id="..."
  :item-id="..." :page-id="..." />` in BOTH `<DesignView>` invocations.
- [ ] **Step 3.5.3** — Pass `activeDesignPageId` from the workspaces store as
  the `pageId` prop.
- [ ] **Step 3.5.4** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 3.5.5** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 3.5.6** — Commit: `git add
  src/apps/desktop/src/components/AppLayout.vue && git commit -m
  "feat(AppLayout): mount DesignHistoryButtons in design toolbar"`.

---

## Chunk 4 — Geometry capture

### Task 4.1 — `useDesignHandlers` extensions (RED)

**Goal:** Add `updateElementHtml` and `reorderSelection` methods to the
composable, mirroring the existing `updateElement` / `deleteElement` patterns.

**File:** `src/apps/desktop/src/__tests__/useDesignHandlers.spec.ts` (extend
existing)

- [ ] **Step 4.1.1** — Add test "useDesignHandlers.updateElementHtml calls
  `workspacesStore.updateDesignElementHtml`": mount composable, call
  `updateElementHtml(ws, item, page, elem, html)`, assert store called.
- [ ] **Step 4.1.2** — Add test "useDesignHandlers.reorderSelection calls
  `workspacesStore.reorderDesignElements` with the right mode": mount
  composable, call `reorderSelection('bring_forward')`, assert store called
  with `mode: 'bring_forward'`.
- [ ] **Step 4.1.3** — Run `timeout 60 bunx vitest run
  src/__tests__/useDesignHandlers.spec.ts` and confirm 2 new tests fail (RED).
- [ ] **Step 4.1.4** — Commit: `git add
  src/apps/desktop/src/__tests__/useDesignHandlers.spec.ts && git commit -m
  "test(useDesignHandlers): red — updateElementHtml + reorderSelection tests"`.

### Task 4.2 — `useDesignHandlers` extensions (GREEN)

**File:** `src/apps/desktop/src/composables/useDesignHandlers.ts`

- [ ] **Step 4.2.1** — Add `updateElementHtml(workspaceId, itemId, pageId,
  elementId, html)` — delegates to
  `workspacesStore.updateDesignElementHtml(...)`.
- [ ] **Step 4.2.2** — Add `reorderSelection(mode)` — reads `selectedIds`,
  delegates to `workspacesStore.reorderDesignElements(workspaceId, itemId,
  pageId, mode, [...selectedIds])`.
- [ ] **Step 4.2.3** — Run the test file and confirm 2 new tests pass.
- [ ] **Step 4.2.4** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 4.2.5** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 4.2.6** — Commit: `git add
  src/apps/desktop/src/composables/useDesignHandlers.ts && git commit -m
  "feat(useDesignHandlers): add updateElementHtml + reorderSelection"`.

### Task 4.3 — Drag/resize gesture capture (RED)

**File:** `src/apps/desktop/src/__tests__/DesignView.undo.spec.ts` (extend)

- [ ] **Step 4.3.1** — Add test "Drag element from x=0 to x=100 → 1 entry on
  `past`; dispatch `Cmd+Z` → element back at x=0; dispatch `Cmd+Shift+Z` →
  element at x=100".
- [ ] **Step 4.3.2** — Add test "Multi-element drag of 2 elements → 1 entry
  with both changes".
- [ ] **Step 4.3.3** — Add test "Selection of 1 element + drag → 1 entry (not
  2)".
- [ ] **Step 4.3.4** — Run `timeout 60 bunx vitest run
  src/__tests__/DesignView.undo.spec.ts` and confirm 3 new tests fail (RED).
- [ ] **Step 4.3.5** — Commit: `git add
  src/apps/desktop/src/__tests__/DesignView.undo.spec.ts && git commit -m
  "test(DesignView): red — drag/resize gesture capture tests"`.

### Task 4.4 — Drag/resize gesture capture (GREEN)

**File:** `src/apps/desktop/src/components/design/DesignElement.vue` and
`src/apps/desktop/src/components/design/DesignView.vue`

- [ ] **Step 4.4.1** — In `DesignElement.vue`, find `startDrag` (line ~147).
  At the start of the gesture, `emit('dragStart', {elementId, additive})`.
- [ ] **Step 4.4.2** — At the `pointerup` (line ~282), `emit('dragEnd', {elementId, dx, dy})`.
- [ ] **Step 4.4.3** — In `DesignView.vue`, listen to `dragStart` and call
  `history.capturePreState([...selectedIds])`.
- [ ] **Step 4.4.4** — Listen to `dragEnd` and call
  `history.capturePostState([...selectedIds])` if anything changed.
- [ ] **Step 4.4.5** — Run the test file and confirm 3 new tests pass.
- [ ] **Step 4.4.6** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 4.4.7** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 4.4.8** — Commit: `git add
  src/apps/desktop/src/components/design/DesignView.vue
  src/apps/desktop/src/components/design/DesignElement.vue && git commit -m
  "feat(design): drag/resize gesture capture for undo"`.

### Task 4.5 — Arrow-key nudge capture (RED)

**File:** `src/apps/desktop/src/__tests__/DesignView.undo.spec.ts` (extend)

- [ ] **Step 4.5.1** — Add test "Arrow-key nudge selection of 2 elements → 5
  entries (one per keypress); undo 5 times → positions back to start".
- [ ] **Step 4.5.2** — Run `timeout 60 bunx vitest run
  src/__tests__/DesignView.undo.spec.ts` and confirm 1 new test fails (RED).
- [ ] **Step 4.5.3** — Commit: `git add
  src/apps/desktop/src/__tests__/DesignView.undo.spec.ts && git commit -m
  "test(DesignView): red — arrow-key nudge capture test"`.

### Task 4.6 — Arrow-key nudge capture (GREEN)

**File:** `src/apps/desktop/src/components/design/DesignView.vue`

- [ ] **Step 4.6.1** — In `handleKeydown` (around line 681–719), at each
  arrow-key nudge, call `history.capturePreState([...selectedIds])` BEFORE
  the PATCH and `history.capturePostState([...selectedIds])` AFTER.
- [ ] **Step 4.6.2** — Run the test file and confirm 1 new test passes.
- [ ] **Step 4.6.3** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 4.6.4** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 4.6.5** — Commit: `git add
  src/apps/desktop/src/components/design/DesignView.vue && git commit -m
  "feat(design): arrow-key nudge capture for undo"`.

### Task 4.7 — PropertiesPanel `@change` capture (RED)

**File:** `src/apps/desktop/src/__tests__/DesignView.undo.spec.ts` (extend)

- [ ] **Step 4.7.1** — Add test "PropertiesPanel X/Y edit → 1 entry per
  field-commit".
- [ ] **Step 4.7.2** — Add test "PropertiesPanel style (fill/stroke) edit →
  1 entry per field-commit".
- [ ] **Step 4.7.3** — Run `timeout 60 bunx vitest run
  src/__tests__/DesignView.undo.spec.ts` and confirm 2 new tests fail (RED).
- [ ] **Step 4.7.4** — Commit: `git add
  src/apps/desktop/src/__tests__/DesignView.undo.spec.ts && git commit -m
  "test(DesignView): red — PropertiesPanel capture tests"`.

### Task 4.8 — PropertiesPanel `@change` capture (GREEN)

**File:** `src/apps/desktop/src/components/design/PropertiesPanel.vue`

- [ ] **Step 4.8.1** — In the `handleNumericChange` /
  `handleStringChange` functions, capture pre-state on `focus` of the input
  and post-state on `@change`.
- [ ] **Step 4.8.2** — Rename element: same shape, capture on `focus` /
  `@change`.
- [ ] **Step 4.8.3** — Run the test file and confirm 2 new tests pass.
- [ ] **Step 4.8.4** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 4.8.5** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 4.8.6** — Commit: `git add
  src/apps/desktop/src/components/design/PropertiesPanel.vue && git commit
  -m "feat(PropertiesPanel): capture edits for undo"`.

---

## Chunk 5 — Delete + reorder + group capture

### Task 5.1 — Delete capture (RED)

**File:** `src/apps/desktop/src/__tests__/DesignView.undo.spec.ts` (extend)

- [ ] **Step 5.1.1** — Add test "Backspace with 2 elements selected → 1 entry;
  undo → both elements restored with their HTML bodies".
- [ ] **Step 5.1.2** — Add test "LayersPanel × delete → 1 entry; undo → element
  restored".
- [ ] **Step 5.1.3** — Run `timeout 60 bunx vitest run
  src/__tests__/DesignView.undo.spec.ts` and confirm 2 new tests fail (RED).
- [ ] **Step 5.1.4** — Commit: `git add
  src/apps/desktop/src/__tests__/DesignView.undo.spec.ts && git commit -m
  "test(DesignView): red — delete capture tests"`.

### Task 5.2 — Delete capture (GREEN)

**File:** `src/apps/desktop/src/components/design/DesignView.vue` and
`src/apps/desktop/src/components/design/LayersPanel.vue`

- [ ] **Step 5.2.1** — In `DesignView.vue::handleKeydown` for
  Backspace/Delete (around line 602), capture pre-state of selectedIds +
  their HTML bodies BEFORE the delete loop.
- [ ] **Step 5.2.2** — After the delete loop, call
  `history.captureDelete(deletedElements)` with the full snapshot.
- [ ] **Step 5.2.3** — In `LayersPanel.vue::handleDelete` (line ~280), same
  shape: capture pre-state before deleting, call `captureDelete` after.
- [ ] **Step 5.2.4** — Run the test file and confirm 2 new tests pass.
- [ ] **Step 5.2.5** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 5.2.6** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 5.2.7** — Commit: `git add
  src/apps/desktop/src/components/design/DesignView.vue
  src/apps/desktop/src/components/design/LayersPanel.vue && git commit -m
  "feat(design): delete capture for undo with HTML body restore"`.

### Task 5.3 — Reorder capture (RED)

**File:** `src/apps/desktop/src/__tests__/DesignView.undo.spec.ts` (extend)

- [ ] **Step 5.3.1** — Add test "Bring/Send (`Cmd+]`) → 1 entry; undo → z-order
  back".
- [ ] **Step 5.3.2** — Run `timeout 60 bunx vitest run
  src/__tests__/DesignView.undo.spec.ts` and confirm 1 new test fails (RED).
- [ ] **Step 5.3.3** — Commit: `git add
  src/apps/desktop/src/__tests__/DesignView.undo.spec.ts && git commit -m
  "test(DesignView): red — reorder capture test"`.

### Task 5.4 — Reorder capture (GREEN)

**File:** `src/apps/desktop/src/components/design/DesignView.vue` and
`src/apps/desktop/src/components/design/LayersPanel.vue`

- [ ] **Step 5.4.1** — In `DesignView.vue::dispatchReorder` (line 136),
  capture the pre-state z-order BEFORE the reorder call.
- [ ] **Step 5.4.2** — After the reorder call, call
  `history.captureReorder(beforeOrder, afterOrder)` with the new order.
- [ ] **Step 5.4.3** — In `LayersPanel.vue::handleMoveUp/Down` (lines 212–244
  after Chunk 1 wire-up), same shape.
- [ ] **Step 5.4.4** — Run the test file and confirm 1 new test passes.
- [ ] **Step 5.4.5** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 5.4.6** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 5.4.7** — Commit: `git add
  src/apps/desktop/src/components/design/DesignView.vue
  src/apps/desktop/src/components/design/LayersPanel.vue && git commit -m
  "feat(design): reorder capture for undo/redo"`.

### Task 5.5 — Group capture (RED)

**File:** `src/apps/desktop/src/__tests__/DesignView.undo.spec.ts` (extend)

- [ ] **Step 5.5.1** — Add test "`Cmd+G` with 2 elements → 1 entry; undo →
  group removed, 2 children back at top-level".
- [ ] **Step 5.5.2** — Run `timeout 60 bunx vitest run
  src/__tests__/DesignView.undo.spec.ts` and confirm 1 new test fails (RED).
- [ ] **Step 5.5.3** — Commit: `git add
  src/apps/desktop/src/__tests__/DesignView.undo.spec.ts && git commit -m
  "test(DesignView): red — group capture test"`.

### Task 5.6 — Group capture (GREEN)

**File:** `src/apps/desktop/src/components/design/DesignView.vue`

- [ ] **Step 5.6.1** — In `DesignView.vue` around line 649 (Cmd+G handler),
  capture the pre-state (selectedIds had no parent) BEFORE the group call.
- [ ] **Step 5.6.2** — After the group call, call
  `history.captureGroup(parent.id, childIds, false)`.
- [ ] **Step 5.6.3** — Run the test file and confirm 1 new test passes.
- [ ] **Step 5.6.4** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 5.6.5** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 5.6.6** — Commit: `git add
  src/apps/desktop/src/components/design/DesignView.vue && git commit -m
  "feat(design): group capture for undo"`.

---

## Chunk 6 — HTML body capture + integration tests

### Task 6.1 — HTML body capture across all entry types

**Goal:** Ensure every entry that touches an element with a `file_path`
captures the HTML body.

- [ ] **Step 6.1.1** — In `useDesignHistory.capturePostState`, AFTER the
  diff, look up each element's HTML body via
  `api.getDesignElementHtml(...)` and add it to the entry's `changes[i].htmlBody`.
  (Cache the response in localStorage to avoid re-fetching on every push.)
- [ ] **Step 6.1.2** — In `useDesignHistory.undo()` for a `changes` entry,
  REWRITE the HTML body via `api.updateDesignElementHtml(...)` if the
  `before` had a different body than the `after`.
- [ ] **Step 6.1.3** — Add test "drag element with HTML body → entry has
  htmlBody field → undo restores the body".
- [ ] **Step 6.1.4** — Run `timeout 60 bunx vitest run
  src/__tests__/DesignView.undo.spec.ts` and confirm 1 new test passes.
- [ ] **Step 6.1.5** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 6.1.6** — Commit: `git add
  src/apps/desktop/src/composables/useDesignHistory.ts
  src/apps/desktop/src/__tests__/DesignView.undo.spec.ts && git commit -m
  "feat(useDesignHistory): capture HTML body in every entry that touches an
  element"`.

### Task 6.2 — Monaco Save capture (RED)

**File:** `src/apps/desktop/src/__tests__/PropertiesPanel.htmlSave.spec.ts`
(extend)

- [ ] **Step 6.2.1** — Add test "Monaco Save → entry pushed with before/after
  HTML body".
- [ ] **Step 6.2.2** — Run `timeout 60 bunx vitest run
  src/__tests__/PropertiesPanel.htmlSave.spec.ts` and confirm 1 new test
  fails (RED).
- [ ] **Step 6.2.3** — Commit: `git add
  src/apps/desktop/src/__tests__/PropertiesPanel.htmlSave.spec.ts && git
  commit -m "test(PropertiesPanel): red — Monaco Save capture test"`.

### Task 6.3 — Monaco Save capture (GREEN)

**File:** `src/apps/desktop/src/components/design/PropertiesPanel.vue`

- [ ] **Step 6.3.1** — In `handleHtmlSave` (line 198), capture pre-state
  BEFORE the API call and post-state AFTER.
- [ ] **Step 6.3.2** — Push the entry with `kind: 'html_edit'`.
- [ ] **Step 6.3.3** — Run the test file and confirm 1 new test passes.
- [ ] **Step 6.3.4** — Run `timeout 120 bunx vitest run` and confirm no
  regression.
- [ ] **Step 6.3.5** — Run `timeout 180 bun run build` and confirm clean.
- [ ] **Step 6.3.6** — Commit: `git add
  src/apps/desktop/src/components/design/PropertiesPanel.vue && git commit
  -m "feat(PropertiesPanel Monaco): capture HTML body edits for undo"`.

---

## Chunk 7 — End-to-end + manual smoke

### Task 7.1 — End-to-end undo cycle test

**File:** `src/apps/desktop/src/__tests__/DesignView.undo.spec.ts` (add)

- [ ] **Step 7.1.1** — Add test "Full undo cycle: drag + delete + group →
  undo 3x → everything restored".
- [ ] **Step 7.1.2** — Add test "Undo + redo + push → redo stack cleared".
- [ ] **Step 7.1.3** — Add test "Switch page → redo stack cleared".
- [ ] **Step 7.1.4** — Run `timeout 60 bunx vitest run
  src/__tests__/DesignView.undo.spec.ts` and confirm 3 new tests pass.
- [ ] **Step 7.1.5** — Commit: `git add
  src/apps/desktop/src/__tests__/DesignView.undo.spec.ts && git commit -m
  "test(DesignView): end-to-end undo cycle + page-switch behaviour"`.

### Task 7.2 — Final verification + manual smoke

- [ ] **Step 7.2.1** — Run `timeout 180 zig build test --summary all` and
  confirm 0 regressions (no backend changes).
- [ ] **Step 7.2.2** — Run `timeout 180 zig build install:linux:system` and
  confirm Linux binary builds clean.
- [ ] **Step 7.2.3** — Run `timeout 180 zig build-obj -fno-emit-bin -target
  x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/test_mod.zig
  -Mnalarcore=src/root.zig` and confirm Windows cross-compile clean.
- [ ] **Step 7.2.4** — Run `timeout 180 zig build-obj -fno-emit-bin -target
  aarch64-macos -lc --dep nalarcore -Mroot=/tmp/test_mod.zig
  -Mnalarcore=src/root.zig` and confirm macOS cross-compile clean.
- [ ] **Step 7.2.5** — Run `timeout 180 bun run build` and confirm
  vue-tsc + vite clean.
- [ ] **Step 7.2.6** — Run `timeout 180 bunx vitest run` and confirm 0
  failures.
- [ ] **Step 7.2.7** — Run manual smoke test against port 8080 (NEVER 8081):
  - Boot `nalar --port 8080` against `$HOME=/tmp/undo-smoke`.
  - Create a design item with 1 page and 3 elements.
  - Drag element A 100 px right → drag element B 50 px down → press
    `Cmd+Z` twice → A and B return to original positions.
  - Delete element C → press `Cmd+Z` → C restored.
  - Group A and B → press `Cmd+Z` → group removed, A and B back at
    top-level.
  - Edit HTML body of A via Monaco → click Save → press `Cmd+Z` → body
    reverts.
  - Refresh page → history persists (drags undo-undo works after refresh).
- [ ] **Step 7.2.8** — Update `docs/SPEC.md` §3.8 with the new feature row
  (mirror the existing pattern in PR #136 entry).
- [ ] **Step 7.2.9** — Commit: `git add docs/SPEC.md && git commit -m
  "docs(spec): mark design undo/redo as landed in SPEC.md §3.8"`.

---

## Pitfalls (project-wide gotchas to remember while implementing)

- **Don't break the existing gesture pattern.** The current 50 ms throttle +
  trailing emit on pointerup in `DesignElement.vue` produces ONE natural
  undo entry per gesture. Don't double-capture — capture pre-state at
  pointerdown, post-state at the trailing emit (not on every throttled emit).
- **LocalStorage version mismatch.** The key embeds `:v1:`. Future
  migrations bump the segment. Old keys are silently discarded. NEVER
  crash on a mismatch.
- **HTML body capture is async.** Fetches go through `api.getDesignElementHtml`,
  which is a Promise. The capture site must `await` the fetch before
  pushing the entry. Otherwise the entry is pushed without the body and
  undo can't restore it.
- **SSE double-emit on `addElement`.** Backend `design_model.addElement` AND
  HTTP handler `design_elements_create.zig` both emit `design_element_created`.
  For undo this means re-issuing the API call triggers two SSE events. The
  frontend's SSE handler should be idempotent (it just refreshes the local
  state). Verify this works.
- **`reorderElements` has no SSE.** Backend silent update. The frontend's
  reorder mirror in `workspacesStore.reorderDesignElements` (line 1315–1338)
  handles local state. Undo replays the API call → store mirror.
- **The `+ Element` dialog silent-drop is NOT in scope.** Don't fix it
  here. The dialog submit emits `createElement` but no one listens. This
  is a pre-existing bug covered in a separate follow-up plan.
- **Static-contract tests are forbidden.** Per the project-wide rule, every
  test must be a real call + assertion. The 5 wire-up tests in Chunk 1 look
  static (they assert on a store call), but they're behavioural — they call
  the component handler and assert on the store mock.
- **Bun is required for `bun run build` to type-check.** `bunx vitest run`
  alone does NOT type-check. Run both.
- **No new dependencies.** Use Pinia + localStorage + VueUse `useDebounceFn`.
- **Don't refactor the existing capture point.** The current `pointermove`
  throttle + `pointerup` trailing emit is the right granularity. Capture
  pre-state at the START of the gesture, post-state at the END.
- **Storage cap = 100 entries per page.** When the cap is hit, evict the
  oldest from `past`. Future is unbounded within a single session.
- **Page switch clears redo stack.** Figma parity. Don't preserve redo
  across pages — too confusing for users.

## Verification

- [ ] `timeout 180 zig build test --summary all` passes
- [ ] `timeout 180 zig build install:linux:system` passes
- [ ] `timeout 180 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig` passes
- [ ] `timeout 180 zig build-obj -fno-emit-bin -target aarch64-macos -lc
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig` passes
- [ ] `cd src/apps/desktop && timeout 180 bun run build` passes (vue-tsc +
  vite)
- [ ] `timeout 180 bunx vitest run` passes
- [ ] Manual smoke test against port 8080 passes (see Task 7.2.7)
- [ ] `docs/SPEC.md` §3.8 row updated

## Reference

- `docs/superpowers/specs/2026-07-30-design-undo-redo.md` — the spec
- `docs/superpowers/specs/2026-07-29-design-right-click-group-menu.md` —
  sibling spec, same conventions
- `docs/superpowers/plans/2026-07-29-design-right-click-group-menu.md` —
  most recent design plan, same conventions
- `docs/superpowers/plans/2026-07-29-create-kanban-task-tool.md` — recent
  tool plan, canonical TDD red/green cadence
- `~/.config/nalar/memories/project-working-patterns.md` — verification
  before completion
- `~/.config/nalar/memories/nalar-frontend-patterns.md` §"`bun run build` is
  the type-check"
- `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`
  — no static-contract tests
- `.nalar/memories/applayout-close-handlers-strip-url-params.md` — silent-drop
  emit pattern (same bug class as the 2 wire-up bugs)
- `.nalar/memories/nalar-backend-architecture.md` §"HTTP handler thin-wrapper
  pattern" — consensus API conventions
- `.nalar/memories/nalar-frontend-patterns.md` §"Vue 3 async `onMounted` +
  click race" — race-prevention pattern for undo + in-flight requests
