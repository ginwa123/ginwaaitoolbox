# Design — Move pages list from top tabs to left sidebar

**Branch:** `worktree/design-pages-left`
**Date:** 2026-08-06
**Owner:** session `task_1785599134339`
**Status:** ✅ Ready for review

---

## Symptom

User reported: *"change pages position, design mode. currently the list
pages, is on the top, i want you to move that to the left"*.

Workflow: in the design canvas, the page tab strip (AI Chat View, Kanban
Mode, Chat View In Progress, Workspaces Sidebar, Task Dialog, Task
Dialog with Attachments, + Page) is rendered as horizontal tabs across
the top of DesignView. The user wants it moved to a vertical list on the
left edge so the canvas gets the full viewport width and the page list
behaves like Figma's left "pages" sidebar.

## Current layout (before)

```
DesignView (flex-col h-full)
├── <toolbar>                       (top: item name + 💬 chat)
├── <DesignPageTabs>                ← HORIZONTAL TABS (target of move)
├── [ loading | error | empty | main-split ]
└── main-split (flex-row)
    ├── canvas-column (flex-1)
    │   ├── canvas-header bar
    │   └── canvas viewport
    ├── resize-handle (drag vertical)
    └── right-sidebar
        ├── LayersPanel
        ├── layers-resize-handle
        └── PropertiesPanel
```

## Target layout (after)

```
DesignView (flex-col h-full)
├── <toolbar>                       (top: item name + 💬 chat)
├── [ loading | error | empty | main-split ]
└── main-split (flex-row)
    ├── left-pages-sidebar          ← NEW: vertical page list (resizable)
    ├── pages-resize-handle         ← NEW: drag-vertical divider
    ├── canvas-column (flex-1)      (unchanged content, just no top tabs)
    │   ├── canvas-header bar
    │   └── canvas viewport
    ├── resize-handle (drag vertical)
    └── right-sidebar               (unchanged)
```

This mirrors the Figma / Sketch layout — `Pages` on the left, `Layers +
Properties` on the right, canvas in the middle.

## Why a left sidebar (and not just rotate the strip)

- Figma/Sketch/Adobe XD all use a vertical page list. Switching to a
  list matches the user's mental model from any design tool they've
  used before.
- A horizontal tab strip scales poorly past ~7 tabs (the user's current
  count is 6 tabs + 1 `+ Page` button = 7 row items). Tabs overflow and
  scroll horizontally; on a left sidebar, they scroll vertically and
  there's much more usable real estate before they crowd.
- The active tab gets a left-edge accent (border-left violet) instead
  of a bottom border — closer to how a vertical menu highlights
  selection.
- Width is resizable, persisted to localStorage with the same
  pattern that the right sidebar already uses (`SIDEBAR_WIDTH_KEY` →
  `PAGES_SIDEBAR_WIDTH_KEY`).

## What landed

### Source files (3 edits)

#### 1. `src/apps/desktop/src/components/design/DesignPageTabs.vue`

Rename in spirit only — keep the file name to minimise import churn
(only DesignView imports this). The component itself flips orientation:

| Property | Before | After |
|---|---|---|
| Direction | horizontal (`flex items-center`, `overflow-x-auto`) | vertical (`flex flex-col`, `overflow-y-auto`) |
| Active indicator | 2px bottom border (violet) | 3px left border (violet) |
| Per-row layout | name + × delete (side-by-side) | name (top) + × delete (top-right) — Figma parity |
| Per-row chrome | inline delete when `pages.length > 1` | hover-revealed delete (still gated on `pages.length > 1`) |
| Root background | `var(--semantic-sidebar-bg)` (same) | unchanged |
| Root data-testid | `design-page-tabs` | unchanged (contract preserved) |
| Per-page data-testid | `design-page-tab-${page.id}` | unchanged |
| Delete data-testid | `design-delete-page-${page.id}` | unchanged |
| Add Page data-testid | `design-add-page` | unchanged |

Emits are unchanged: `selectPage`, `addPage`, `deletePage`. Props are
unchanged. The minimum CSS surgery is:

- Remove the active-tab `border-bottom: 2px solid` →
  `border-left: 3px solid` (slight visual weight bump because a
  vertical list needs stronger left-edge affirmation than a horizontal
  bottom underline).
- Add `flex-col` and `overflow-y-auto`.
- Add a small padding tweak so page names truncate with ellipsis
  instead of forcing the sidebar wide.

#### 2. `src/apps/desktop/src/components/design/DesignView.vue`

Two changes:

1. **Move the tabs out of the top column.** The `<DesignPageTabs>`
   block currently sits after `<toolbar>` in the outer `flex-col`
   container; delete it from there.
2. **Mount the tabs as a new left column inside the main split.** Add a
   new column `<DesignPageTabs>` immediately to the LEFT of the canvas
   column. Wire up the same `@select-page`, `@add-page`, `@delete-page`
   handlers. Add a drag-vertical resize handle between the pages
   sidebar and the canvas column. Persist the width to localStorage
   with key `design-view-pages-sidebar-width` (new constant; mirrors
   `SIDEBAR_WIDTH_KEY`).

The right sidebar (Layers + Properties) layout stays exactly as-is. The
canvas column stays exactly as-is. The toolbar stays exactly as-is.

Update the file's top-of-file doc-comment (lines 1-63) to reflect the
new vertical orientation.

#### 3. Update existing static-contract tests where they lock the
**WRONG** invariant:

- `DesignPageTabs.spec.ts` — `it('renders one tab per page with the
  data-testid selector', ...)` and `it('highlights the active page with
  the violet bottom border', ...)` reference "bottom border" — the
  test SHOULD be updated to reference the new left-border. The other
  asserts (emits, props, testids) are still valid. (See "Conversion
  to behavioural" below.)
- `DesignView.spec.ts` — `it('renders the page tabs, canvas, and
  right sidebar with Layers + Properties')` is fine (tabs still
  rendered, just positioned differently). But the assertion that
  `<DesignPageTabs` appears in the source (used as a structural smoke
  test) is moot after this change — TODO: convert to behavioural.

### Conversion to behavioural tests (per user rule 2026-07-29)

The two existing static-contract test files (`DesignPageTabs.spec.ts`
and the relevant `DesignView.spec.ts` blocks) reference the
horizontal-tab layout. Per the project-wide rule:
> **NEVER write static-contract tests** — user rule (2026-07-29).

The existing tests use `expect(source).toContain(...)` and
`expect(source).toMatch(...)` patterns, which the rule explicitly
bans. They were grandfathered at the time but this change touches
exactly the area they assert; converting to behavioural at the same
time is the cleaner outcome.

**Convert `DesignPageTabs.spec.ts`**: rename to
`DesignPagesSidebar.spec.ts` (matches the new mental model), keep the
emits + props contract as behavioural tests via mount + assert,
**delete** the bottom-border-colour static test (no longer applies),
**add** a left-border-accent behavioural test. ~5 behavioural tests.

**Convert `DesignView.spec.ts`**: keep it as-is (it asserts many
things beyond layout — undo/redo behaviour, onUnmounted invariant,
etc.), but **replace** the layout-assertion block
(`'renders the page tabs, canvas, and right sidebar with Layers +
Properties'`) with a behavioural test that mounts DesignView and
checks the DOM tree shows the pages sidebar on the LEFT of the canvas
column.

### New behavioural tests (`__tests__/DesignPagesSidebar.spec.ts`)

Five tests, all behavioural:

1. **Renders one button per page** — mount with 3 pages, assert 3
   `data-testid="design-page-tab-..."` buttons exist.
2. **Click emits `selectPage`** — mount, click page 2, assert
   `selectPage` emit fires with `page2.id`.
3. **Click `+ Page` emits `addPage`** — mount with 1 page, click
   `design-add-page`, assert `addPage` emit fires.
4. **× button emits `deletePage` with the right id** — mount with 2
   pages, click `design-delete-page-<id>`, assert `deletePage` emit
   fires with that id. Also assert × is rendered (currently conditional
   on `pages.length > 1`).
5. **Active page has the `border-left` violet highlight, not the
   `border-bottom`** — mount with 2 pages, assert the
   `data-testid="design-page-tab-<activeId>"` element's `style`
   attribute contains `border-left` (not `border-bottom`).

### New behavioural tests (`__tests__/DesignView.pagesSidebar.spec.ts`)

Six tests, all behavioural:

1. **Pages sidebar is rendered to the LEFT of the canvas column** —
   mount DesignView, find the `data-testid="design-pages-sidebar"`
   element, find `data-testid="design-canvas-column"`, assert the
   `pages-sidebar`'s bounding rect's `right` is `<=` the
   `canvas-column`'s bounding rect's `left`.
2. **Pages sidebar is NOT inside the top toolbar's column** — assert
   the `data-testid="design-toolbar"` element does NOT contain the
   `data-testid="design-pages-sidebar"` (regression test for the
   pre-fix layout where it was at the top).
3. **Drag the resize handle grows/shrinks the pages sidebar width** —
   mount, simulate mousedown + mousemove + mouseup on the
   `data-testid="design-pages-resize-handle"`, assert the sidebar
   width matches.
4. **Width persists across remounts** — mount, set width to 250,
   unmount, remount, assert width is still 250 (localStorage).
5. **Click a page tab updates `data-design-active-page-id`** — mount,
   click `data-testid="design-page-tab-<id>"`, assert the canvas column
   or DesignView root reflects the active page (regression test that
   the wire moved with the layout).
6. **`+ Page` button still works from the sidebar position** — mount,
   click `design-add-page`, assert `handleAddPage` was invoked
   (observable via the `pages.value` Array growing once the mock
   resolves).

## Why a new component name (or no — file path kept)

The file path `DesignPageTabs.vue` is preserved to keep the import
chain (`DesignView.vue:66`) untouched. The internal class
component-instance name (in `<script setup>` there isn't one) doesn't
matter; the file is referred to as `<DesignPageTabs>` in the template
still — names happen to be identical to the tag, so the change is
purely CSS / template + a `data-testid` semantic refresh where needed.

We considered renaming to `DesignPagesSidebar.vue` for clarity, but
the migration churn is non-trivial (every spec that imports the
component, every docstring reference, etc.). Defer to a future PR if
the user wants the rename.

## Out of scope

- **Pages reordering (drag-to-reorder pages)** — out of scope. The
  current API order is `created_at ASC` and there's no
  `POST .../reorder` endpoint for pages. Figma has this — defer.
- **Renaming a page via double-click** — out of scope. Not in the
  current API contract.
- **A separate visual "page thumbnail"** — Figma shows small previews
  per page; out of scope (would need a server-rendered thumbnail
  pipeline).
- **Moving the LEFT sidebar's width from localStorage to Pinia** — the
  right sidebar already uses localStorage; keep the same pattern for
  consistency. Future refactor can unify these into the workspaces
  store.

## Verification

- `cd src/apps/desktop && bun run build` — vue-tsc must remain clean.
- `cd src/apps/desktop && bunx vitest run` — full test suite. The
  expected added count is `5 + 6 = 11` behavioural tests (with one
  existing static-contract block converted). Total expected: `+
  roughly 10 net` tests green.
- `cd src/apps/desktop && bun run build` and visually verify by
  serving the webapp (`bun run dev`) and clicking a design item.
- No backend changes — `zig build test` and the Zig build pipeline
  should NOT be touched.
- Manual smoke: open a design item, click each page tab on the left,
  confirm + Page still appends a new page, confirm × still deletes.

## Pitfalls

- **Don't break the `design-page-tab-${page.id}` testid contract.**
  Some downstream test/Playwright suite may rely on this exact
  selector. Static-pattern grep across the codebase showed only the
  component itself + its own spec reference this testid, but be
  careful during the merge.
- **The `<DesignPageTabs>` instance may have multiple children inside
  it now** (a tab per page + the `+ Page` button) — verify the
  `pagesLoading` / `pagesError` / `pages.length === 0` empty-state
  branches in DesignView still render the helpful empty states. The
  tabs strip ONLY renders when `pages.length > 0` (it's inside the
  `v-else` branch of pages fetch states).
- **The canvas viewport's scroll container assumes a `flex-col` from
  DesignView; adding a left sidebar can squeeze the canvas width on
  narrow windows** — verify the toolbar's chat button is still
  reachable at the smallest window (~1024px wide) and that the right
  sidebar's drag handle still works.
- **Don't accidentally move the `+ Page` button below the `<DesignPageTabs>`
  root in the new left-sidebar layout** — keep it INSIDE the
  `DesignPageTabs` component so the empty-state button in
  `DesignView.pages-empty` (which is its own `<button>`, separate
  from the tabs component) is still the path users hit when they have
  zero pages.

## Files

**New (2 files):**
- `src/apps/desktop/src/__tests__/DesignPageTabs.spec.ts` (rewrite to
  behavioural — replace the 5 source-grep tests)
- `src/apps/desktop/src/__tests__/DesignView.pagesSidebar.spec.ts` (new
  6-test suite)

**Modified (2 files):**
- `src/apps/desktop/src/components/design/DesignPageTabs.vue` (CSS
  flip + minor template tweaks — keep props/emits/testids)
- `src/apps/desktop/src/components/design/DesignView.vue` (move
  DesignPageTabs from top column to left sidebar column; add resize
  handle + width persistence; update doc-comment block at the top)

## Plan summary

- **Source edits:** 2 files (DesignPageTabs.vue + DesignView.vue)
- **Test edits:** 2 files (convert static to behavioural + 1 new spec)
- **Net test impact:** ~11 new behavioural tests, ~5 static-contracts
  removed
- **Backend impact:** none
- **Migration impact:** none
- **Risk:** low — CSS-only on DesignPageTabs, layout-only on
  DesignView, all behavior contracts preserved
