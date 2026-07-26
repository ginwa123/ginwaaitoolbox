# design tab × button needs full end-to-end wire — partial wiring is silent

## Symptom

In the design canvas tab strip (`DesignPageTabs.vue`), each tab renders a
`×` delete affordance. Clicking it does nothing — the page stays in
the strip, no API call, no toast, no error.

The visual treatment is fine (`opacity-60 hover:opacity-100`), so the
user reasonably assumes the button works. It's only "discoverable" as a
bug when they try to clean up their pages.

## Root cause

The `×` button is a `<span role="button">` that emits `deletePage`. That
event bubbles up `DesignPageTabs → DesignView → AppLayout`. At every
layer the emit / re-emit happens correctly — but **nobody consumes it
on the way to the network**.

```
TDD mirror that DOES work:
deleteElement — modeled fully:
  - emit `deleteElement` (component)
  - re-emit `deleteElement` (DesignView)
  - handler in AppLayout delegates to useDesignHandlers composable
  - composable calls workspacesStore.deleteDesignElement
  - store action calls api.deleteDesignElement
  - api wraps DELETE /api/.../design/pages/:pid/elements/:eid
  - handler in design_elements_delete.zig calls design_model.deleteElement
  - model DELETEs the row + unlinks on-disk HTML + emits SSE event
  - handler returns 200 + {success:true}

deletePage — partial:
  - emit `deletePage` ✅
  - re-emit `deletePage` ✅
  - handler in AppLayout ❌
  - composable function ❌
  - store action ❌
  - api function ❌
  - backend route ❌
  - backend handler ❌
  - backend model function ❌
```

`git grep -n 'deleteDesignPage\|delete-page'` returned zero matches
across the frontend before the fix — confirming the wire was unwired
at every hop. TypeScript and zig build did NOT flag this (a `deletePage`
emit with no listener is a perfectly valid Vue surface, and Zig only
type-checks what's reachable from `main.zig`).

## Fix shape (mechanical mirror of deleteElement)

1. **Backend model** — `design_model.zig::deletePage(...)` that:
   - JOIN-locates `workspace_id + item_id + item_path + page_name`
     BEFORE the SQL DELETE (so we have both the SSE event context AND
     the on-disk folder path).
   - `DELETE FROM design_pages WHERE id = ?` (FK `ON DELETE CASCADE`
     on `design_page_elements.page_id` cleans up child rows).
   - Defer-pattern: `design_io.deleteDirectoryRecursively(allocator,
     io, "<item_path>/.nalar/design/<sanitized_page_name>")` AFTER
     the SQL succeeds. Use the same helper that
     `workspace_items_delete.zig` already uses.
   - Emits `design_page_deleted` SSE event via
     `on_event_sent_design.onEventSendDesignPageDeleted(...)` for
     multi-tab sync. Routing key `"design_page"` (parallel to
     `"design_element"`).
   - Returns `true` on success, `false` if the page_id was missing
     (idempotent — caller treats 404 as success).

2. **Backend handler + route** — `http_handlers/design_pages_delete.zig`
   + `try gs.router.delete("/api/.../design/pages/:page_id", ...)` in
   `main.zig`. 4 static-contract tests (mirrors
   `design_elements_delete_test.zig`):
   - handler calls `design_model.deletePage`
   - handler returns 200 + `success: bool = true` envelope
   - handler maps `PageNotFound` to 404
   - handler validates the `page_id` path param

3. **Frontend API** — `api/index.ts::deleteDesignPage(ws, item, page)`
   wrapping `method:'DELETE'` on the existing `apiFetch`.

4. **Frontend store** — `workspacesStore.deleteDesignPage(ws, item, page)`
   that calls the api and resets `activeDesignPageId` when the deleted
   page was the active one. **Note:** `WorkspaceItem` does NOT have a
   `design_pages` field — DesignView manages its own local `pages`
   array via `listDesignPages`. The store only owns the cross-component
   `activeDesignPageId` ref.

5. **AppLayout wire** — `handleDesignDeletePage(pageId)` on both
   `<DesignView>` invocations. Delegates to a new `deletePage`
   function in the `useDesignHandlers` composable that owns the
   `window.confirm()` safety guard + error notification, matching the
   `deleteElement` pattern.

## Why this matters

1. **Silent affordances destroy trust.** A button that looks interactive
   but does nothing is worse than no button at all.
2. **The bug is invisible to type-checks.** `vue-tsc` doesn't complain
   about a `deletePage` emit with no consumer — it's a perfectly valid
   Vue API surface. Only manual testing catches it.
3. **The fix is mechanical.** Every layer already has the proven
   `deleteElement` blueprint. This is "wire up the mirror" work —
   cheap to do, expensive to leave undone.
4. **vue-tsc, vue-test-utils, and zig build ALL pass on a half-wired
   button** — the test discipline has to be "every UI affordance has
   a matching backend route + handler + model function + store
   action + AppLayout handler". `git grep` for the affordance name
   is the cheapest invariant to check.

## Pitfalls

- **`workspaceItem.design_pages` does NOT exist.** I initially wrote a
  store action that mutated `item.design_pages` — TypeScript caught
  this on `bun run build`. The store's only job is to reset
  `activeDesignPageId`; DesignView owns the page list via
  `listDesignPages`. Verify with `bun run build` (NOT `bunx vitest
  run` — see project memory `vue-tsc-build-emits-js-files.md`).
- **Don't forget the SSE event.** Without `design_page_deleted`,
  multi-tab design clients (chat-side tab + canvas-side tab are two
  views of the same item) won't sync the deletion. The
  `design_element_deleted` event is the proven pattern; mirror it.
- **`req.params.get("page_id")` not `req.path_params.get(...)`.** The
  codebase uses `StringHashMap`-style `req.params`. See
  `nalar-backend-architecture.md`.
- **Use `design_io.sanitizeFilename` to build the on-disk path.**
  Page names can contain spaces / unicode / `/`; the directory on
  disk uses the sanitized form. Skipping sanitization → rmdir targets
  the wrong folder.
- **On-disk folder rmdir AFTER SQL DELETE (defer-pattern), best-effort.**
  Same shape as `deleteElement`. Failure to rmdir logs a warning but
  doesn't fail the delete.

## Verification

End-to-end smoke test against `localhost:8080` (NOT 8081 — see
`project-working-patterns.md`):

```bash
# Create a test page
NEW=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages \
  -H 'content-type: application/json' -d '{"name":"smoke-test"}' | jq -r .id)

# Delete it
curl -sS -X DELETE http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages/$NEW
# {"success":true}

# Second delete (idempotent — 404 is fine)
curl -sS -X DELETE http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/design/pages/$NEW
# {"error":"Page not found"} (404)
```

Confirmed passing 2026-07-25: 4/4 backend static-contract tests, 2/2
frontend api mock tests, 4/4 store action tests, 1437/1437 total vitest,
1838/1847 backend tests (3 pre-existing workflow_retry_delay failures
unrelated to this change).

## Reference

- Plan: `docs/SPEC.md` §3.8 (Design Canvas — page delete button)
- Branch: `worktree/design-page-delete-button`
- Worktree: `/home/ginwa/agentic_coding_zig/ginwaaitoolbox_worktrees/design-page-delete-button`
- Mirror: every layer pattern matches the existing `deleteElement`
  end-to-end wire (see `nalar-backend-architecture.md` "HTTP handler
  thin-wrapper pattern" for the thin-handler convention).
