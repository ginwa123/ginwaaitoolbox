# Vite HMR: computed-based sort changes can require a hard refresh

## Symptom

User opens the kanban in browser at `http://localhost:5173/...`,
picks a sort on a column. The Network panel shows the backend
fetch with the right `sort_by=...`, but the visual order doesn't
change for OTHER columns that should remain on Manual (their
default kanban_position asc sort).

## Root cause

Vite HMR (Hot Module Reload) updates the source modules in place
when files change. For pure template changes, HMR is invisible.
For `computed` changes that depend on **defines** (e.g. adding
a `.sort()` step to a `cardsInColumn` filter), the HMR update
can leave the previous cache or stale dependency graph in
place — the page still renders but the new comparator is not
invoked.

The page renders the OLD component logic until a hard refresh
(Ctrl+Shift+R / Cmd+Shift+R) reloads everything from scratch.

## Fix

When the user reports "fix doesn't work" after a sort / filter
change that touches a `computed`:

1. Verify the file is correct on disk (grep / read_file).
2. Verify the Vite dev server is serving the corrected file
   (`curl http://localhost:5173/src/...?direct | grep`).
3. Run the unit tests (`bunx vitest run <file>`) — they bypass
   HMR entirely and use the actual source.
4. Ask the user to **hard refresh** the browser tab.

If the unit tests pass and the Vite-served file is correct, the
fix IS deployed — the user's browser just needs a hard refresh.

## Why this matters

The user spent a few minutes looking at the Network panel
thinking the fix wasn't applied, when in fact the fix was
already served and the unit tests passed. The hard refresh
takes 2 seconds and resolves the issue.

## Detection recipe

```bash
# Verify the fix is in the source on disk
grep -c "compareBySortMode" src/apps/desktop/src/components/kanban/KanbanColumn.vue

# Verify the fix is in the Vite-served bundle
curl -s "http://localhost:5173/src/components/kanban/KanbanColumn.vue?direct" | grep -c "compareBySortMode"

# Run the unit tests (bypasses HMR)
timeout 60 bunx vitest run src/__tests__/KanbanColumn.sortIndependence.spec.ts
```

If all three checks pass, the fix is deployed. Tell the user to
hard refresh.

## Pitfalls

- **Don't restart the dev server** unless the user is on a
  production bundle (port 8081 / nalar-desktop). The dev server
  on 5173 auto-refreshes from source.
- **Don't rebuild the desktop binary** to fix Vite issues. The
  binary uses the OLD embedded bundle; the dev server uses the
  LIVE source.
- **Vite's `?direct` query param** bypasses the Vite client
  cache, so the served file is always the latest source. Useful
  for verifying what the browser SHOULD be seeing.
- **HMR error overlays** (red banner at the top of the browser
  window) are the clear signal that HMR failed. The dev
  console will also show "HMR update failed" or "Cannot find
  module" errors.

## Reference instance

task_1785730557641 (kanban-sort-independence) — the user
opened the Vite dev server after my fix was merged, Vite HMR
didn't apply the updated `cardsInColumn` computed, and the user
saw the old visual order. Fix: hard refresh.

## Related

- Vite HMR docs: https://vitejs.dev/guide/hmr.html
- `vue-3-horizontal-scroll-restore-on-remount` memory — another
  case where Vite HMR was a footgun.
- `vue-tsc-build-emits-js-files` — different but related
  Vite/frontend gotcha.
