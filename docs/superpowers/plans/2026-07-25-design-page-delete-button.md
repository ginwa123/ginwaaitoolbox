# 2026-07-25 — Design mode tab × button is a no-op

## Symptom

In the design canvas tab strip (`DesignPageTabs.vue`), each tab shows a
`×` delete affordance. Clicking it does nothing — the page stays in
the tab strip, no API call, no toast, no error.

The user has 4 pages (Desktop App Mockup / Card Click — Task Detail /
Untitled / Chat with AI) and cannot remove any of them through the UI.

## Root cause

The × button **emits a `deletePage` event** that bubbles up
`DesignPageTabs → DesignView → AppLayout`, but **nobody consumes it
on the way to the network**. The wire is dead end-to-end:

| Layer | What it does today | What it should do |
|---|---|---|
| `DesignPageTabs.vue` (L46-51) | Stops propagation, emits `deletePage` upward | ✅ Already correct |
| `DesignView.vue` (L643-645) | Re-emits `deletePage` upward | ✅ Already correct |
| **`AppLayout.vue`** | **No `@delete-page` listener, no handler** | **← MISSING — this is the first dead end** |
| **`src/apps/desktop/src/api/index.ts`** | **No `deleteDesignPage()` function** | **← MISSING — second dead end** |
| **`src/apps/desktop/src/stores/workspaces.ts`** | **No `deleteDesignPage()` action** | **← MISSING — third dead end** |
| **`src/ai_workflow/tui/http_handlers/`** | **No `design_pages_delete.zig` handler** | **← MISSING — backend dead end** |
| **`src/ai_workflow/tui/design_model.zig`** | **No `deletePage()` function** | **← MISSING — model layer dead end** |

So even if the user-supplied wiring reached the network, the backend
would 404 because there's no route and no model function.

A `git grep -n 'deleteDesignPage\|delete-page'` across the frontend
returns **zero matches** — confirming the wire is unwired at every hop.

The `×` was visible because the button was styled (`opacity-60
hover:opacity-100`) but functionally empty.

## Why now (not earlier)

The page-tab UI shipped in the design-mode-redesign plan
(`docs/superpowers/plans/2026-07-08-design-mode-redesign.md`, Chunk 5).
The user-facing affordance was added but the network path was never
closed. The same plan shipped `deleteElement` end-to-end (model +
handler + route + api + store + AppLayout handler), so `×` on
elements works. `×` on pages was a near-mirror that was missed.

## Fix design (5 chunks)

Mirror the proven `deleteElement` path end-to-end:

### Chunk 1 — Backend: model + HTTP handler + route + tests

**`src/ai_workflow/tui/design_model.zig`** — add `deletePage`
function right after `deleteElement` (L1194):

- Look up `workspace_item_id`, `item_path`, `page_name` BEFORE the
  SQL DELETE (so we can both emit the SSE event AND rmdir the on-disk
  page directory).
- Delete the `design_pages` row. The FK `ON DELETE CASCADE` on
  `design_page_elements.page_id` (migration 055/056) handles the
  element rows — same pattern as `deleteElement`.
- Defer-pattern: `design_io.deleteDirectoryRecursively(allocator, io,
  "<item_path>/.nalar/design/<sanitized_page_name>")` AFTER the SQL
  succeeds. Swallow errors (folder may already be missing). Use the
  same helper that `workspace_items_delete.zig` already uses.
- Emit `design_page_deleted` SSE event via a new
  `onEventSendDesignPageDeleted` (mirrors `onEventSendDesignElementDeleted`).
- Return `true` if a row was deleted, `false` if the page_id didn't exist.

**`src/ai_workflow/tui/on_event_design.zig`** — add
`DesignPageDeletedData` struct mirroring `DesignElementDeletedData`:
`{ action: "deleted", workspace_id, item_id, page_id }`.

**`src/ai_workflow/tui/on_event_sent_design.zig`** — add
`onEventSendDesignPageDeleted` function. Event type string:
`"design_page_deleted"`. event_bus routing key: `"design_page"`
(new key, parallel to `"design_element"`).

**`src/ai_workflow/tui/http_handlers/design_pages_delete.zig`** — new
file, ~100 LoC. Mirrors `design_elements_delete.zig` exactly:

- `DesignPageDeleteError = error{ PageIdRequired, PageNotFound, DbError, OutOfMemory }`.
- `useCase(allocator, db, page_id) !void` validates the id and
  delegates to `design_model.deletePage`.
- `designPagesDeleteHandler` is the thin orchestrator: parse
  `:page_id` path param, call `useCase`, map errors to status codes
  (400 / 404 / 500) via two exhaustive switches, return
  `200 + {"success": true}` envelope.

**`src/ai_workflow/tui/http_handlers/design_pages_delete_test.zig`**
— new file, 4 static-contract tests mirroring
`design_elements_delete_test.zig`:

1. handler calls `design_model.deletePage`
2. handler returns 200 + `success: bool = true` envelope
3. handler maps `PageNotFound` to 404
4. handler validates the `page_id` path param

**`src/ai_workflow/tui/http_handlers/mod.zig`** — add
`pub const designPagesDeleteHandler = @import("design_pages_delete.zig").designPagesDeleteHandler;`
right after the existing `designPagesUpdateHandler` export (L139).

**`src/main.zig`** — register the new route at L430 (after the
existing page update `try gs.router.patch(...)` line). Comment-table
header updated to include the new `DELETE /design/pages/:pid` row.

**`src/ai_workflow/tui/test_runner.zig`** — add `_ =
@import("http_handlers/design_pages_delete_test.zig");` next to the
other design_pages imports.

**`src/ai_workflow/tui/on_event_sent_design_test.zig`** — add the new
event type to the static-contract assertions:
- `onEventSendDesignPageDeleted` fn present
- `"design_page_deleted"` event_type string present

### Chunk 2 — Frontend API + store action

**`src/apps/desktop/src/api/index.ts`** — add `deleteDesignPage`
function right after `updateDesignPage` (around L1443). Mirror the
existing `deleteDesignElement` shape:

```ts
/**
 * DELETE /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId
 * UI-only — no LLM tool exposes this endpoint, only the DesignView
 * tab-strip × button. Returns 200 with `{success:true}`; 404 if the
 * page didn't exist (idempotent — caller treats 404 as success).
 */
export async function deleteDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`,
    { method: 'DELETE' },
  )
}
```

**`src/apps/desktop/src/stores/workspaces.ts`** — add
`deleteDesignPage` action alongside `deleteDesignElement` (around
L1192). Pattern from the existing element delete:

```ts
async function deleteDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
): Promise<void> {
  await deleteDesignPageApi(workspaceId, itemId, pageId)
}
```

Also export it from the store's `return { ... }` block (around L2181
where `deleteDesignElement` is exposed).

### Chunk 3 — Frontend wiring in AppLayout + DesignView + delete confirmation

**`src/apps/desktop/src/components/AppLayout.vue`** — add the
`@delete-page` listener on both `<DesignView>` invocations (L1624
and L1673, parallel to `@delete-element`). New handler
`handleDesignDeletePage`:

```ts
const handleDesignDeletePage = async (pageId: string): Promise<void> => {
  try {
    await workspacesStore.deleteDesignPage(workspaceId, itemId, pageId)
  } catch (e) {
    console.error('[handleDesignDeletePage] failed:', e)
    notifyError('Failed to delete page', String(e instanceof Error ? e.message : e))
  }
}
```

**Confirmation prompt.** Figma's tab `×` deletes immediately; ours
should match (single-click UX). BUT the design workspace currently
has no built-in undo, and pages contain elements + on-disk HTML.
Skipping the confirm trades safety for speed. Decision: **confirm
the delete with a native `confirm()`** (the same primitive used in
`WorktreeMenu.vue:64`) for safety — the user can dismiss and try
again. The confirm is cheap and matches the pattern other destructive
ops in the codebase use (`window.confirm` in `WorktreeMenu`).

If the user wants instant delete later, that's a one-line change —
remove the `confirm()` call.

### Chunk 4 — Frontend tests

**`src/apps/desktop/src/__tests__/apiDesign.spec.ts`** — add
`deleteDesignPage` mock-based test (mirroring the existing
`deleteDesignElement` test in the same file):

- Import `deleteDesignPage` at top
- New `describe('deleteDesignPage', ...)` block with:
  1. `DELETEs the right URL and returns {success:true}` — assert
     `init.method === 'DELETE'`, the URL contains
     `/design/pages/<pageId>`, and the result has `success: true`.
  2. `throws ApiError on 4xx` — assert
     `.rejects.toMatchObject({ status: 404 })`.

**`src/apps/desktop/src/__tests__/workspacesStoreDeleteDesignPage.spec.ts`**
— new file (parallel to any existing delete spec) OR add a test to
the existing `workspacesStore*` suite. Pin the contract:

- `workspacesStore.deleteDesignPage(ws, item, page)` calls
  `api.deleteDesignPage` with the same args.
- Surfaces API errors via the notification store on failure.

### Chunk 5 — Documentation + memory

**`docs/superpowers/plans/2026-07-25-design-page-delete-button.md`** —
this plan file.

**`.nalar/memories/nalar-frontend-patterns.md`** — add a memory entry
"design tab × button needs full end-to-end wire — partial wiring is
silent". The pattern: a tab-strip UI affordance without a backend
handler / API / store action emits an event that no one listens to.
`window.confirm()` + `notifyError` is the project-standard for
destructive ops.

## Tasks (TDD order)

1. **RED test:** add the 4 static-contract tests in
   `design_pages_delete_test.zig`. `zig build test` should show
   `FileNotFound` for the import → **RED**.
2. **GREEN:** implement `design_model.deletePage` + the handler +
   the route registration. `zig build test` should show 4 passing +
   the new test runner import green.
3. **RED test:** add `deleteDesignPage` to the api design spec.
   `bunx vitest run __tests__/apiDesign.spec.ts` should fail with
   "deleteDesignPage is not exported from api".
4. **GREEN:** add the API function + store action. The spec passes.
5. **Add the AppLayout wire.** No new test needed; the path is
   covered by the api + store tests.
6. **Manual smoke test** against `localhost:8080` (NOT 8081 — see
   project memory `project-working-patterns.md`):
   ```bash
   cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox_worktrees/design-page-delete-button
   timeout 180 zig build install:linux:system 2>&1 | tail -n 5
   timeout 180 zig build test --summary all 2>&1 | tail -n 5
   # In src/apps/desktop:
   cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
   cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 5
   # Restart the dev server, navigate to design mode, click × on a tab
   ```

## Pitfalls to avoid

- **Don't use `request.params.get("page_id")` — the codebase uses
  `req.params.get("page_id")` (it's a `StringHashMap`, not
  `path_params`).** See `nalar-backend-architecture.md` HTTP handler
  thin-wrapper pattern.
- **Don't add a confirm-style modal component** — the codebase uses
  `window.confirm()` for cheap destructive flows (see
  `WorktreeMenu.vue:64`). A modal would be overkill for this case.
- **Don't forget the SSE event** — without it, multi-tab design
  clients (the chat-side tab and the canvas-side tab are two views of
  the same item) won't sync the deletion. The
  `design_element_deleted` event is the proven pattern; mirror it.
- **Don't try to delete in-place without the directory rmdir** —
  orphan `<item_path>/.nalar/design/<page>/` folders accumulate
  (visible after the workspace_items_delete rmdir code path on L64-97).
  Use `design_io.deleteDirectoryRecursively` (already exists, used by
  `workspace_items_delete.zig`).
- **Don't skip the `on_event_design.zig` payload struct** — the SSE
  event payload MUST be a JSON-serializable struct; raw `[]const u8`
  slices get serialized as byte arrays (see memory
  `zig-0.16-stdlib-changes.md` `std.json.fmt emits invalid-UTF-8 as
  byte arrays`).

## Verification (final)

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox_worktrees/design-page-delete-button

# 1. Type-check + unit tests (frontend)
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 5
timeout 120 bunx vitest run 2>&1 | tail -n 5

# 2. Backend tests
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox_worktrees/design-page-delete-button
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
rm -rf zig-out/bin
timeout 360 zig build 2>&1 | tail -n 5

# 3. Manual smoke test
./zig-out/bin/nalar --port 8080 &
sleep 3
curl -sS http://127.0.0.1:8080/api/health
# Open the design item, click × on a tab → confirm dialog → page removed
```

## Why this matters

1. **Silent affordances destroy trust.** A button that looks
   interactive but does nothing is worse than no button at all.
2. **The bug is invisible to type-checks.** `vue-tsc` doesn't
   complain about a `deletePage` emit with no consumer — it's a
   perfectly valid Vue API surface. Only manual testing catches it.
3. **The fix is mechanical.** Every layer (model → handler → route
   → API → store → component) already has the proven
   `deleteElement` blueprint. This is the kind of "wire up the
   mirror" work that's cheap to do and expensive to leave undone.

## Plan-file path

`/home/ginwa/agentic_coding_zig/ginwaaitoolbox_worktrees/design-page-delete-button/docs/superpowers/plans/2026-07-25-design-page-delete-button.md`
