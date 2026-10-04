# 2026-08-06 — Design page rename menu

User report (`task_1785986998916`): *"add a menu to rename design pages"*.
Screenshot shows the sidebar tree with a `design` item expanded to
show three pages (`AI Chat View`, `Kanban Mode`, `Untitled`). Today
the only per-page affordance is a × delete button on hover; there is
no way to rename a page from the UI.

## Mental model

Each design page row in the sidebar tree gets a **⋮ three-dot menu**
(matching the kanban-column `⋮` menu from the kanban-sort-by plan,
2026-08-06). The menu contains:

- **Rename** — opens `RenameDesignPageModal.vue`, calls
  `workspacesStore.renameDesignPage`, which PATCHes the page's `name`
  via the existing `/api/workspaces/.../design/pages/:page_id`
  endpoint and optimistically updates the cache.
- **Delete** — same `deletePage` emit as the existing × hover button
  (both routes through the same `openDeleteConfirm` flow).

The × delete button stays as a direct hover affordance (one-click
deletion without opening the menu first).

## Architecture

### Backend (Zig) — 3 files

| File | Change |
|---|---|
| `src/ai_workflow/tui/design_model.zig` | `UpdateDesignPageInput` gains `name: ?[]const u8`; `updateDesignPage` validates non-empty when present, builds a dynamic UPDATE (width + height always; name optional). |
| `src/ai_workflow/tui/http_handlers/design_pages_update.zig` | `UpdatePageBody` gains `name: ?[]const u8`; `UpdatePageInput` mirrors; new error `BadPageName` maps to 400 with "name must not be empty". |
| `src/ai_workflow/tui/design_model.zig` (tests) | 3 new inline tests: back-compat (name=null), rename round-trip, BadPageName guard. |

### API layer (TypeScript)

| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | `updateDesignPage` accepts optional `name` in the patch. Wire shape unchanged otherwise. |

### Pinia store

| File | Change |
|---|---|
| `src/apps/desktop/src/stores/workspaces.ts` | New `renameDesignPage(workspaceId, itemId, pageId, newName)` action. Optimistic update on `designPagesByItemId[itemId][idx].name`; rolls back on PATCH failure; refetches are NOT triggered (the cache is the source of truth). |

### UI components

| File | Change |
|---|---|
| `src/apps/desktop/src/components/workspace/DesignPageRow.vue` | Adds a ⋮ menu trigger button (hover-revealed via the existing `group/page` modifier) between the page name and the × delete button. Menu has Rename + Delete items. Document-level `mousedown` listener closes the dropdown on outside clicks (mirrors the kanban-column ⋮ menu pattern). |
| `src/apps/desktop/src/components/workspace/WorkspaceItem.vue` | Adds `renameDesignPage` emit + pass-through `handleRenameDesignPage` handler. |
| `src/apps/desktop/src/components/workspace/WorkspaceList.vue` | Forwards `@rename-design-page` from WorkspaceItem → Sidebar. |
| `src/apps/desktop/src/components/shell/Sidebar.vue` | Adds `handleRenameDesignPage` (sets modal state) + `handleConfirmDesignPageRename` (calls `workspacesStore.renameDesignPage`, surfaces errors via `useNotificationStore`). Mounts `RenameDesignPageModal`. |
| `src/apps/desktop/src/components/dialogs/RenameDesignPageModal.vue` (new) | Mirrors `RenameTaskModal.vue` (single-input centered modal, Esc + Enter + Save/Cancel). |

### Tests (5 new files)

| File | Tests |
|---|---|
| `src/apps/desktop/src/__tests__/DesignPageRow.spec.ts` | +7 — ⋮ trigger renders, dropdown closed by default, click opens, click does NOT emit selectPage (stopPropagation), Rename emits `renamePage`, Delete emits `deletePage`, trigger does NOT emit either menu action. |
| `src/apps/desktop/src/__tests__/workspacesStoreRenameDesignPage.spec.ts` (new) | +5 — happy path with trimmed name + cache update + API call, rollback on failure, no-op on empty/whitespace, no-op on unchanged, no-op when page id is missing from cache. |
| `src/ai_workflow/tui/design_model.zig` (inline) | +3 — back-compat (name=null), rename round-trip via listPages, BadPageName for empty name. |

## Behavioural matrix

| Scenario | Result |
|---|---|
| Hover over a page row → ⋮ + × appear | Both visible on hover; not clickable through the row's click handler (stopPropagation on each). |
| Click ⋮ → dropdown opens, hover anywhere else → closes | Document mousedown listener fires; menuRef.contains(target) check. |
| Click "Rename" in ⋮ → modal opens with name pre-selected | Sidebar sets 4 target refs + opens modal; modal pre-fills name + auto-selects input. |
| Type new name + press Enter / Save | Modal emits `rename(name)`; Sidebar calls `workspacesStore.renameDesignPage`; cache updates immediately (optimistic); backend PATCH succeeds → no toast. |
| Backend PATCH fails | Cache rolls back; error toast via `useNotificationStore().notifyError('Failed to rename page', ...)`. |
| Empty / unchanged name | Modal disables the Save button; clicking it (if somehow forced) emits no event. |
| Click "Delete" in ⋮ | Opens the existing `<ConfirmDialog>` (same path as the × button). |
| Click × directly (without opening ⋮) | Same delete confirm flow (existing behaviour preserved). |

## Wire shapes

### Backend PATCH body (added `name`)

```diff
  PATCH /api/workspaces/:ws/items/:item/design/pages/:page_id
  {
    "width": 1440,
    "height": 1024,
+   "name": "Renamed Page"  // optional; absent/null = leave unchanged; "" = 400
  }
```

### Store action

```ts
workspacesStore.renameDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
  newName: string,
): Promise<void>
```

Optimistic update + rollback on PATCH failure. The cache is the
single source of truth — no refetch is needed after the rename.

## Pitfalls (record for future agents)

- **`freePages` does NOT work on stack arrays** — it ends with
  `allocator.free(pages)` which crashes on a stack-allocated `[1]DesignPage`.
  For `updateDesignPage` returning a single `DesignPage` struct, free
  each field manually: `alloc.free(p.id); alloc.free(p.name); ...`.
  See the `testing_update_page` block at the bottom of design_model.zig.

- **Dynamic SQL builder for the optional `name` field** — the existing
  `UPDATE design_pages SET width=?, height=?, updated_at=... WHERE id=?`
  is preserved verbatim when `name == null` (back-compat for callers
  that haven't been updated). When `name != null`, a second form is
  emitted that includes `name = ?`. The args array length also
  changes — DON'T reuse the same `args` slice for both paths.

- **`@click.stop` on the ⋮ trigger** — without it, clicking ⋮ fires
  the outer row's `selectPage` handler (the row is a `<div
  role="button">`, not a `<button>` so Vue's auto-prevention doesn't
  apply). Symptom: clicking ⋮ navigates to the page before opening the
  dropdown. Test: `DesignPageRow.spec.ts > "clicking the ⋮ trigger
  does NOT emit selectPage (stopPropagation)"`.

- **Document mousedown listener cleanup** — the listener is added on
  menu open and removed on menu close. Without the `removeEventListener`
  on close, every menu-open leaks a global listener. With many rows,
  this leaks across the whole sidebar tree. The cleanup is what makes
  the menu safe to mount N times (one per page row).

- **Modal state pattern (mirrors task rename)** — the modal's
  `emit('rename', name)` only carries the trimmed name. The 4 target
  refs (workspaceId, itemId, pageId, currentName) must persist across
  modal close + reopen cycles. Don't merge them into a single object —
  the `show` ref re-renders the modal's template via Vue's reactivity
  and a single-object ref pattern loses the previous values when the
  watcher resets.

- **No active-page fallback needed** — renaming is a pure metadata
  change. The canvas keeps rendering whatever page it was already on
  (DesignView reads from `activeDesignPageId`, not from the page's
  name). URL and sidebar re-render the new name; nothing else moves.

- **Page-name validation mirrors `setDesignPage`** — the `BadPageName`
  guard (empty string → 400) is intentionally the same as `setDesignPage`.
  An empty name would break the on-disk folder derivation in
  `design_io` (`<item.path>/.pabrik/design/<page_name>/...`).

## Verification

```bash
# Backend (Linux)
timeout 180 zig build test --summary all
# 2339 pass, 6 skip, 6 fail, 1 crash (2352 total)
# Baseline = 2336 pass; +3 new (this commit's model tests).
# Failures + crash = pre-existing baseline.

timeout 60 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig
# clean
timeout 60 zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig
# clean

# Frontend (Linux)
cd src/apps/desktop
timeout 90 node_modules/.bin/vue-tsc --build --force
# clean
timeout 60 node_modules/.bin/vitest run \
  src/__tests__/DesignPageRow.spec.ts \
  src/__tests__/workspacesStoreRenameDesignPage.spec.ts
# 18 pass / 0 fail
```

## Out of scope (deferred to follow-ups)

- **Inline rename** (click pencil → row turns into input → Enter
  saves, Esc cancels) — Notion / Linear pattern. Lighter weight than
  a modal but less consistent with the existing task-rename UX.
  Defer until the user asks for it.

- **Rename history / undo** — the rename is irreversible via the UI.
  Backend doesn't keep a history of names; reversing requires direct
  DB access. Out of scope unless the user asks.

- **Rename via the DesignView toolbar** — the active page's name is
  visible in DesignView's toolbar, but there's no rename affordance
  there yet. Same modal could mount in DesignView; out of scope.

- **Bulk rename** (rename multiple pages at once) — the store action
  is per-page; a batch action would need a new endpoint. Out of scope.

- **Persist the original name on rename for migration / rollback** —
  the database doesn't carry a `previous_name` column. Defer until a
  rollback requirement appears.

## Files (11 modified + 1 created)

Modified:

- `src/ai_workflow/tui/design_model.zig` (input struct + function +
  inline tests)
- `src/ai_workflow/tui/http_handlers/design_pages_update.zig`
  (UpdatePageBody + UpdatePageInput + error mapping)
- `src/apps/desktop/src/api/index.ts` (updateDesignPage accepts
  optional name)
- `src/apps/desktop/src/stores/workspaces.ts` (new
  renameDesignPage action)
- `src/apps/desktop/src/components/workspace/DesignPageRow.vue` (⋮
  menu + state + emits)
- `src/apps/desktop/src/components/workspace/WorkspaceItem.vue`
  (renameDesignPage emit + handler)
- `src/apps/desktop/src/components/workspace/WorkspaceList.vue`
  (forward @rename-design-page)
- `src/apps/desktop/src/components/shell/Sidebar.vue` (handler +
  modal state + mount)
- `src/apps/desktop/src/__tests__/DesignPageRow.spec.ts` (+7 tests)
- `AGENTS.md` (changelog entry)

Created:

- `src/apps/desktop/src/components/dialogs/RenameDesignPageModal.vue`
- `src/apps/desktop/src/__tests__/workspacesStoreRenameDesignPage.spec.ts`
- `docs/superpowers/plans/2026-08-06-rename-design-pages.md` (this)
</content>
</invoke>