# Kanban Sort-By Tasks (per-column, ⋮ menu)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-column sort-by menu inside each `<KanbanColumn>`'s existing "⋮" header menu (Rename/Delete). Each column's sort is independent — column A can be sorted by Name (A→Z) while column B stays on Manual drag-reorder.

**Architecture:** Each `KanbanColumn` instance owns its own `sortBy` + `direction` refs (local state, NOT store, NOT URL). The ⋮ menu gains a "Sort tasks…" entry between Rename and Delete. Clicking it opens a centered modal containing the existing `<KanbanSortMenu>` rendered in `showTrigger=false` mode (just the menu items, no button). The modal closes on selection (existing behaviour) + backdrop click + Esc. Sort application happens at `KanbanColumn.cardsInColumn` — first by the per-column sort mode, then by `kanban_position asc` as tiebreaker. Drag-to-reorder stays enabled in all modes (the column writes `kanban_position` on drop; the next reactive re-sort preserves the user's chosen primary sort).

**Tech Stack:** Vue 3 (Composition API), TypeScript, Zig 0.16 backend with existing `TaskSortField` + `TaskSortDirection` enums (used only for the regression test in Task 1).

## Global Constraints

- **Each column has independent sort state.** No URL persistence, no store state. Drag-to-reorder stays enabled.
- **The modal is opened by clicking "Sort tasks…" in the column's existing ⋮ menu.** Closes on selection, backdrop click, Esc. No title bar — just the menu items inside a rounded card on a fixed backdrop.
- **The modal must use the existing `<KanbanSortMenu>` component** with a new `showTrigger` prop set to false. Reusable across the codebase (e.g. a future header button would set `showTrigger=true`).
- **Drag-to-reorder writes `kanban_position` on drop** — unchanged from today. The card visually stays where the user dropped it within the current reactive render (no server refetch). When the user picks Manual, drag persists across re-renders naturally.
- **Cross-platform**: Linux/macOS/Windows. `bun run build` (vue-tsc) + `bunx vitest run` are mandatory per AGENTS.md.
- **No URL persistence** — sort is ephemeral view state per column. The kanban's URL (`?view=workspace&workspaceId=...&itemId=...`) still works; we don't add `?sort=...&dir=...`.
- **Backend already supports `sort_by=created_at|updated_at|name` × `asc|desc`** — the SQL ORDER BY was added in earlier work. This plan only adds ONE backend test (Task 1) to lock in the contract; no SQL changes.
- **Default sort = `position` (asc)** — today's behaviour, no regression.

## Out of scope

- URL persistence for sort (sort is local view state).
- Cross-column sort coordination (e.g. "sort all columns by created date").
- Saved sort preferences in localStorage.
- LLM-controlled sort modes (UX-driven, not LLM-driven).
- Custom multi-field sort.

## File Structure

**Modified (3):**
- `src/apps/desktop/src/components/kanban/KanbanSortMenu.vue` — add `showTrigger?: boolean` prop (default true). When false, render only the `<ul>` items (no trigger button, no click-outside listeners, no Esc handler).
- `src/apps/desktop/src/components/kanban/KanbanColumn.vue` — add per-column `sortBy` + `direction` refs; extend `cardsInColumn` to apply sort; add "Sort tasks…" entry to ⋮ menu; mount centered modal `<KanbanSortMenu :show-trigger="false" ...>` when `sortModalOpen` is true.
- `docs/SPEC.md` §3.7 — update the kanban-sort-by row + section to reflect per-column design.

**New (3):**
- `src/apps/desktop/src/__tests__/KanbanSortMenu.spec.ts` — update existing tests to cover the new `showTrigger` prop (button hidden when false, items still render).
- `src/apps/desktop/src/__tests__/KanbanColumn.sortMenu.spec.ts` — new tests for per-column sort behaviour (independent state, modal open/close, sort application).
- `docs/superpowers/plans/2026-08-06-kanban-sort-by.md` — this file.

## Tasks

### Task 1 — Backend sort regression test (already done on main, kept for context)

The backend's `llm_history.zig::listWorkspaceItemTasksWithCursor` already supports `sort_by=created_at|updated_at|name × asc|desc` with `(sort_field, id)` tuple pagination. Two behavioural tests at the bottom of `llm_history.zig` (Contract 12 + 13) lock in `name` and `created_at` ordering. These already landed in commit `0fd38316` on `worktree/kanban-sort-by`.

- [x] **DONE** — `test(backend): lock in sort_by=name + sort_by=created_at coverage` (commit `0fd38316`).

### Task 2 — `<KanbanSortMenu>` learns to render without a trigger button

The component currently always renders a `<button>` trigger + an absolutely-positioned `<ul>` dropdown. For the per-column modal, we want just the `<ul>` items inside a centered card on a backdrop — no trigger button, no click-outside handler (the modal's backdrop handles close).

- [ ] **RED** — Update `src/apps/desktop/src/__tests__/KanbanSortMenu.spec.ts` to add 4 tests:
  1. With `showTrigger=false`, no trigger button is rendered.
  2. With `showTrigger=false`, the `<ul>` menu items are rendered immediately (not behind a click).
  3. With `showTrigger=false`, no `document.click` listener is installed (clicking outside the `<ul>` does NOT close it).
  4. With `showTrigger=false`, no Esc listener fires (Esc on the document doesn't change anything).
- [ ] **GREEN** — Implement: add `showTrigger?: boolean` prop. When false, skip the trigger `<button>`, skip the click-outside handler, skip the Esc handler. Always render the `<ul>` items in their wrapper.
- [ ] **Verify** — `bunx vitest run src/__tests__/KanbanSortMenu.spec.ts` → all pass.
- [ ] **Commit** — `feat(kanban): KanbanSortMenu supports showTrigger=false for modal use`

### Task 3 — Per-column sort state + application in `KanbanColumn`

Add `sortBy` + `direction` refs to `<KanbanColumn>`. Extend `cardsInColumn` to apply the per-column sort FIRST, then `kanban_position asc` as tiebreaker (matches the backend's `(sort_field, id)` pagination pattern). Each column has independent state — mounting two columns gives each its own sort.

- [ ] **RED** — Create `src/apps/desktop/src/__tests__/KanbanColumn.sortMenu.spec.ts` with 8 tests:
  1. Two columns with the same fixture sort independently — changing column A's sort doesn't affect column B's.
  2. Default sortBy='position' + direction='asc' → cards in `kanban_position asc` order (today's behaviour).
  3. sortBy='name' + direction='asc' → cards in name A→Z order (within the column).
  4. sortBy='name' + direction='desc' → cards in name Z→A order.
  5. sortBy='created_at' + direction='desc' → cards in newest-first order.
  6. Cards with the same sort-field value fall back to `kanban_position asc` (tiebreaker).
  7. Mounting a column with an in-progress drag → sort preserves the drag's position (drag wins within the same render cycle, sort applies on the next).
  8. Setting sortBy='position' restores the original kanban_position order even after the user picked Name (A→Z) earlier.
- [ ] **GREEN** — Implement in `KanbanColumn.vue`:
  - Add `sortBy` + `direction` refs (default 'position' + 'asc').
  - Extend `cardsInColumn` to apply the sort: comparator reads the field, falls back to `kanban_position` asc as tiebreaker.
  - The sort is purely client-side — no server refetch, no store changes, no URL.
- [ ] **Verify** — `bunx vitest run src/__tests__/KanbanColumn.sortMenu.spec.ts` → all pass.
- [ ] **Commit** — `feat(kanban): per-column sort state in KanbanColumn`

### Task 4 — "Sort tasks…" entry in the column ⋮ menu + centered modal

The existing ⋮ menu (lines 519-552 of `KanbanColumn.vue`) has Rename + Delete. Insert a "Sort tasks…" entry between them. Clicking it opens a centered modal containing `<KanbanSortMenu :show-trigger="false" v-model:sortBy v-model:direction>` — same component, just rendered without its trigger button, on a fixed backdrop. The modal closes on selection (already does this), backdrop click, and Esc.

- [ ] **RED** — Add 4 more tests to `KanbanColumn.sortMenu.spec.ts`:
  1. ⋮ menu has 3 items: Rename, Sort tasks…, Delete (in that order).
  2. Click "Sort tasks…" → the modal opens (modal root has `data-testid="kanban-column-${columnId}-sort-modal"`).
  3. Modal backdrop click closes the modal.
  4. Modal Esc keydown closes the modal.
- [ ] **GREEN** — Implement:
  - Add `sortModalOpen` ref.
  - Add "Sort tasks…" entry to ⋮ menu between Rename and Delete; clicking it emits a new local handler that closes the menu + opens the modal.
  - Mount the modal inside the column's `<section>` (or use `<Teleport to="body">` if layout is tricky — the simpler path is just inside the column section, the modal's `position: fixed` escapes it anyway).
  - Modal structure: `<div class="fixed inset-0 z-50 flex items-center justify-center">` → backdrop `<div @click.self="close">` → card `<div class="rounded-lg bg-card-bg">` → `<KanbanSortMenu :show-trigger="false" v-model:sortBy v-model:direction>`.
  - Esc closes — add a `keydown` listener on document when `sortModalOpen`.
- [ ] **Verify** — `bunx vitest run src/__tests__/KanbanColumn.sortMenu.spec.ts` → all pass.
- [ ] **Commit** — `feat(kanban): Sort tasks entry in column ⋮ menu opens centered modal`

### Task 5 — Final verification

- [ ] `bun run build` (vue-tsc + vite) clean.
- [ ] `bunx vitest run` → no new failures (existing pre-existing 12 are OK).
- [ ] `zig build test --summary all` → no new failures (the 2 backend tests in Task 1 still pass).
- [ ] `zig build` clean — produces `pabrik` + `pabrik-desktop` binaries.
- [ ] Cross-compile smoke: `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` and `-target aarch64-macos` both pass (no compile errors). This is a frontend-only change; the existing tests already pass these on main.
- [ ] Live smoke on port 8080 (NOT 8081): open a kanban, click ⋮ on a column, pick "Sort tasks…", choose "Name (A→Z)", confirm cards in that column reorder. Open a second column, pick a different sort, confirm independence. Refresh — sorts reset to Manual (no URL persistence).
- [ ] **Commit** — `chore(kanban): final verification + cross-platform smoke`

### Task 6 — Documentation

- [ ] Append a new entry to `AGENTS.md`'s "Recent changes" section explaining the per-column sort design + the user's mental model + why no URL persistence.
- [ ] Update `docs/SPEC.md` §3.7 to reflect per-column sort (the row already exists from before; rewrite the §3.7.8 section or add §3.7.8 if missing).
- [ ] **Commit** — `docs: kanban per-column sort changelog + SPEC.md status`

## Pitfalls

- **No URL persistence.** The user previously asked for URL persistence for per-board sort, but per-column sort is purely local view state. If the user asks for URL persistence, follow up separately.
- **The modal closes on selection** — `KanbanSortMenu.handleSelect` already calls `closeMenu()` internally; we need to also close the modal wrapper. Hook `closeMenu()` → modal `close` handler. The simplest path: have the modal watch the menu's `menuOpen` ref OR have the menu emit a `close` event we forward.
- **Drag-to-reorder during a non-Manual sort**: the column writes `kanban_position` on drop, but the cards are sorted by the primary mode. After a drop, the dragged card visually snaps back to its server-sorted position on the next reactive render. This is the same "option B" UX as before — keep drag enabled.
- **`cardsInColumn` already sorts by `kanban_position`** (lines 99-111 of `KanbanColumn.vue`). The new comparator REPLACES this single sort with a two-key sort (primary + tiebreaker), so existing tests that assert `kanban_position asc` order may break for non-Manual modes. Fix: change those tests to use the Manual mode (or update expectations to use the new comparator output).
- **Per-column state means N independent `ref`s.** Each `<KanbanColumn>` instance has its own; closing and reopening the kanban (which re-mounts the columns via `:key="kanban-${itemId}"`) RESETS all per-column sorts to Manual. Same lifecycle as the existing drag-reorder order. No persistence.
- **Modal positioning** — `position: fixed inset-0` works regardless of where in the DOM the modal is mounted. No need to Teleport to body; mounting inside `<KanbanColumn>` is fine. (Verified: fixed positioning escapes overflow containers.)
- **`showTrigger=false` test isolation** — the global document listeners (click-outside, Esc) must be removed in `onUnmounted` regardless of `showTrigger`. The existing handler attachment should not depend on `showTrigger`; only the handler's behaviour should. Specifically: when `showTrigger=false`, the handlers do nothing (no menu to close).
- **`KanbanSortMenu` props order**: `defineProps<{ showTrigger?: boolean }>()` must come BEFORE `defineEmits` — Vue 3 macros are order-sensitive in some configs.

## Verification

- [ ] All Tasks 1-6 commits land on `worktree/kanban-sort-by`.
- [ ] `bun run build` clean.
- [ ] `bunx vitest run` — pre-existing 12 failures OK, no NEW failures.
- [ ] `zig build test --summary all` — pre-existing 2 leaks OK, no NEW failures.
- [ ] Manual smoke test on port 8080: open a kanban, ⋮ → Sort tasks… → pick a mode per column, confirm independence + drag still works.

## Plan

`docs/superpowers/plans/2026-08-06-kanban-sort-by.md` (this file).

## Reference

- Backend sort support: `src/ai_workflow/tui/llm_history.zig:3870-4100` (`listWorkspaceItemTasksWithCursor`)
- Existing column header menu pattern: `src/apps/desktop/src/components/kanban/KanbanColumn.vue:264-307` (the "⋮" menu — copy this pattern for "Sort tasks…")
- Existing cardsInColumn sort: `src/apps/desktop/src/components/kanban/KanbanColumn.vue:99-111`
- Plan (replaced): `docs/superpowers/plans/2026-08-06-kanban-sort-by.md` (earlier per-board + URL-persistence design)
- Previous (now-superseded) commits: `9145f283` … `4627bc85` — see git log. Reset to `0fd38316` before this redo.