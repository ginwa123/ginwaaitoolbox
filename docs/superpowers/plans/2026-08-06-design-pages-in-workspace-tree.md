# Design — Render design pages inside the workspace sidebar tree

**Branch:** `worktree/design-pages-in-tree`
**Date:** 2026-08-06
**Owner:** session `task_1785599134339`
**Status:** ✅ Ready for review

---

## Symptom

User reported (after PR #167 landed): *"i mean pages move inside workpace item, 'design' like config agentic ai"*. They want the design-mode page list to live **inside the workspace sidebar tree** — under the design workspace item, the same way `llls` shows up indented under `config agentic ai`. NOT in a separate left sidebar inside the design canvas.

Their reference screenshot shows:
```
WORKSPACES
  agentic coding
    saass
    config agentic ai          ← folder item, expands
      • llls                   ← task, indented under folder
    design                     ← clicked, currently selected
    sprint bulan juni
+ Add Item
```

The user wants `design` to behave like `config agentic ai` — expand on click and show its design pages as nested rows under it.

## Why PR #167 was the wrong place

PR #167 moved the pages from a horizontal tab strip at the top of DesignView to a vertical sidebar on the LEFT edge of DesignView (Figma convention). That was a reasonable interpretation, but it kept the page list **inside the design canvas** — separate from the workspace navigation tree where every other navigation primitive lives.

The user's mental model: **the workspace sidebar is the navigation surface**. Tasks live there (under their parent item), chats live there (ChatsList at the top), workspaces live there. Pages should also live there, under their parent design item — visible while the user is browsing OTHER items, not just when they've already navigated into the design view.

## What landed (this PR)

### 1. **Revert PR #167 entirely**

Commit `63c287f8` reverts PR #167. The pages tab strip goes back to the top of DesignView (original position), and the sidebar tests are removed.

Wait, actually — **the horizontal tabs at the top are ALSO removed**. Reason: the pages now live in the workspace sidebar tree, which is the single source of truth for navigation. Showing the same page list in two places (tree + DesignView top tabs) is redundant and confusing. The canvas header still shows the active page name, so the user always knows which page they're on.

### 2. **New: design pages render inside the workspace tree**

When `item.item_type === 'design'` AND the item is expanded, render `design_pages` as nested rows under the design item:

```
WORKSPACES
  agentic coding
    saass
    config agentic ai
      • llls
    ▶ design
    sprint bulan juni
```

After clicking `design`:
```
WORKSPACES
  agentic coding
    saass
    config agentic ai
      • llls
    ▼ design                      ← expanded
      • AI Chat View              ← page row (clickable, navigates to view)
      • Kanban Mode
      • Chat View In Progress
      • Workspaces Sidebar
      • Task Dialog
      • Task Dialog with Attachments
      + Add Page                  ← creates a new page (POST /pages)
    sprint bulan juni
```

Each page row:
- Click → set that page as active (`activeDesignPageId` in store) + navigate to the design view
- Hover → × delete button (matches WorkspaceItemTaskRow's hover affordance)
- Visual: same indent + dot styling as task rows, so the visual language stays consistent

### 3. **Click-to-expand design items**

Today, clicking `design` in the workspace tree activates it (loads DesignView) but doesn't expand the row. After this PR, clicking `design` toggles expansion (like `config agentic ai`). The user can also click the chevron to expand without activating.

Wait — actually we should keep the existing "click = activate" behavior since the user is already used to it. Let me think about this UX.

Two competing concerns:
- (a) The user expects `click design` to navigate INTO the design view (existing behavior, established)
- (b) Folders toggle expand on click (existing behavior, established)

Both `design` and `config agentic ai` are workspace items. The user wants `design` to behave like `config agentic ai`. But `config agentic ai` is a folder (sub-items visible inside the explorer), while `design` is a design canvas.

Compromise: clicking `design` always activates it (existing behavior). To expand pages, the user clicks the chevron `▶` on the left of the design row. This matches the WorkspaceList chevron pattern (the chevron is a separate click target from the row itself).

Actually looking at WorkspaceItem.vue line 96 — for `kanban` AND `design` items, the click handler does NOT toggle expand (it just emits the click). For other types (folder, etc.), it toggles. So:
- `kanban` row: click activates (existing)
- `design` row: click activates (existing) — we'll add chevron click to expand

The chevron is already there with the rotate-90 transform when expanded (line 396-400 in WorkspaceItem.vue). Currently `isExpanded` is gated on `expandedItemIds[item.id] === true` (line 67-69). For kanban items, expandedItemIds is never set to true (because click handler skips toggle). So isExpanded is always false.

For design items after this PR:
- The chevron itself becomes clickable to toggle expand
- The row body still does the "activate" action (click → navigate to design view)
- When expanded, design_pages render nested

### 4. **Where the page data lives**

Design pages are stored in `design_pages` DB table, fetched via `api.listDesignPages(workspaceId, itemId)`. Currently fetched inside `DesignView.vue` (`loadPages`, line 458-496).

After this PR:
- **Sidebar tree** also needs the page list to render the nested rows. Where does it live?
- **Option A**: Fetch in WorkspaceItem.vue on expand → store in local state. Simple but doesn't share with DesignView.
- **Option B**: Add `designPagesByItemId: Map<itemId, DesignPage[]>` to the workspaces Pinia store. Both consumers read from there.
- **Option C**: Fetch on expand AND when DesignView mounts. Each consumer owns its own copy.

Going with **Option B** — single source of truth. The workspaces store has `activeWorkspaceItemId` and `activeDesignPageId` already. Adding `designPagesByItemId: Record<itemId, DesignPage[]>` fits the pattern.

On expand of a design item:
1. If `designPagesByItemId[item.id]` exists → render immediately
2. Else → fire `fetchDesignPages(workspaceId, itemId)` → store result → render

On create page / delete page (from the sidebar's `+ Add Page` button or `×` button):
- POST `/pages` or DELETE `/pages/:id` → update local cache → emit event so DesignView re-fetches if mounted

### 5. **What happens to DesignView's tabs**

Removed. The active page name is shown in the canvas header bar (existing behavior — line 1996-2002 of DesignView.vue: `<div v-if="activePage" class="text-xs flex-1 truncate">{{ activePage.name }}</div>`).

The empty state's `+ Add the first page` button stays (covers the case where the user navigates into DesignView before expanding the tree).

## Files

**Modified (4 files):**
- `src/apps/desktop/src/components/workspace/WorkspaceItem.vue`
  - New template section for design pages (under the chevron, between the row and the tasks list section)
  - Click chevron on design item → toggle expand
  - Fetch design pages on first expand
  - Render each page as a row (similar to WorkspaceItemTaskRow layout, but simpler — no spinner, no routine branch)
- `src/apps/desktop/src/stores/workspaces.ts`
  - New state: `designPagesByItemId: Record<string, DesignPage[]>` (keyed by item id)
  - New action: `fetchDesignPages(workspaceId, itemId)` → calls API → caches in state
  - New action: `addDesignPage(workspaceId, itemId, name)` → POST + cache update
  - New action: `deleteDesignPage(workspaceId, itemId, pageId)` → DELETE + cache update
  - When user clicks a page row → `setActiveDesignPage(pageId)` (existing)
- `src/apps/desktop/src/components/design/DesignView.vue`
  - Remove `<DesignPageTabs>` (now lives in the sidebar tree)
  - Read pages from `workspacesStore.designPagesByItemId` instead of fetching locally
  - Re-emit `add-page` / `delete-page` from sidebar tree events → trigger the store actions
- `src/apps/desktop/src/components/design/DesignPageTabs.vue`
  - Either delete entirely OR repurpose as a sub-component of WorkspaceItem. **Decision**: repurpose as a content list (just the rows, no root container) so we can reuse the same row component both in the sidebar and (later) potentially elsewhere.

  Actually, **decision: delete DesignPageTabs.vue entirely**. The sidebar tree doesn't need a "tabs" component anymore — it just renders DesignPageRow.vue directly. Simpler.

**New (2 files):**
- `src/apps/desktop/src/components/workspace/DesignPageRow.vue` — single page row in the sidebar tree. Mirrors WorkspaceItemTaskRow's structure but for pages (no spinner, no routine, simpler events).
- `src/apps/desktop/src/__tests__/DesignPageRow.spec.ts` — 5-7 behavioural tests.

## Tests (behavioural)

- **`DesignPageRow.spec.ts`** — new 6-test suite:
  1. Renders page name
  2. Click emits `selectPage` with the page id
  3. × button emits `deletePage` with the page id
  4. × button hidden when `pages.length === 1` (orphan guard)
  5. Active page (matching `activePageId` prop) has the violet active style
  6. data-testid `design-page-row-${pageId}`

- **`WorkspaceItem.spec.ts`** (extend) — new describe block "design pages":
  1. When `item_type === 'design'` and `isExpanded === true`, renders the design-pages section
  2. Fetches pages via `workspacesStore.fetchDesignPages` on first expand
  3. `+ Add Page` button issues POST via store action
  4. Click a page row sets `activeDesignPageId` and emits `selectItem`
  5. Click chevron toggles expand WITHOUT activating the item (preserves existing click-row behavior)

- **`DesignView.spec.ts`** (extend or update) — confirm:
  1. DesignView no longer renders `<DesignPageTabs>` in its template
  2. DesignView reads pages from the store, not local state

- **`workspaces.store.designPages.spec.ts`** (new) — store tests:
  1. `fetchDesignPages` populates `designPagesByItemId`
  2. `addDesignPage` updates the cache
  3. `deleteDesignPage` removes from cache
  4. Concurrent fetches for the same item don't double-fetch (in-flight guard)

## Out of scope

- **Drag-to-reorder pages** — still not in the API. Same as previous PR.
- **Inline rename on double-click** — not in the API.
- **Page thumbnails** — would need server-rendered previews.
- **Persist expansion state for design items** — currently `expandedItemIds` is only persisted for folder items. We'll add design item ids to the same `expandedItemIds` set, so the existing localStorage mechanism works.
- **Migration of existing users**: anyone who has expanded a design item to see pages will see them in the new sidebar position. No data migration needed (design_pages table is unchanged).

## Verification

- `bun run build` clean (vue-tsc passes)
- `bunx vitest run`: 1922 tests + ~12 new = 1934. The 8 pre-existing failures on main remain (5 undoHidden + 1 DesignElement static + 1 nudge + 1 translate). All new tests must pass.
- Visual smoke: expand `design` in the sidebar → see pages nested → click a page → navigates to design view with that page active → click another page → switches → click `+ Add Page` → new page appears → click `×` → page deleted.

## Pitfalls

- **Empty state in DesignView**: when the user navigates into a design item that has 0 pages, they should see the empty state inside DesignView (the "+ Add the first page" button), NOT a blank canvas. Currently DesignView handles this in lines 1938-1958 (the `v-else-if="pages.length === 0"` branch). Preserve this — the only change is reading pages from the store instead of local state.
- **Two consumers racing on fetch**: if the sidebar expands and DesignView mounts at the same time, both could call `fetchDesignPages`. Add an in-flight guard in the store action (return the existing promise if one's already running for that item).
- **Active page sync between sidebar and DesignView**: when the user clicks a page in the sidebar, we set `activeDesignPageId` in the store. DesignView watches this (existing watcher at line 511-529 in pre-#167 DesignView.vue) and re-fetches elements. The store action that handles page clicks should NOT also fire a separate "select design item" event — the active item is already implied by the page's workspace item id.
- **Delete page race**: if the user deletes the active page, the active page id needs to fall back to another page (or empty). The existing `handleDeletePage` in pre-#167 DesignView.vue (lines 1113-1152) does this correctly. We can reuse the logic in the store action.
- **+ Add Page placement**: put it INSIDE the expanded design section, below the last page row. NOT next to the design row itself (that would be ambiguous).
