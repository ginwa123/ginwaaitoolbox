# Plan: Add `workspace_id` to task URLs (kanban / design mode)

**Date:** 2026-08-06
**Task:** task_1785774094183 (kanban: sprint bulan juni → "add workspace_id params")
**Status:** Implementation complete, ready for PR
**Worktree:** `worktree/add-workspace-id-params`

## Problem (user report, verbatim)

> *"add workspace_id params when view the task, like in kanbanmode or design mode"*

The URL bar showed `?view=task&task=task_X&itemId=item_Y` — no `workspaceId`.
The user wants the workspace context visible in the URL so:

1. Shareable — paste the URL to another tab / teammate and land on the
   correct kanban / design page.
2. Refreshable — `F5` restores the full kanban / design context.
3. Back-buttonable — `router.push` keeps the prior URL in history so
   the browser back button returns to the kanban naturally.

## Root cause

Seven call sites across `Sidebar.vue` and `AppLayout.vue` built
`?view=task` URLs without including `workspaceId` / `itemId` / `pageId`:

1. **`Sidebar.handleSelectTask`** (kanban / design → task click).
   Used `pickBreadcrumbFromQuery` to spread the current URL's breadcrumb,
   so workspaceId was included IF the source URL had it. Missing for
   deep-link or refresh scenarios where the URL was already stripped.
2. **`Sidebar.handleAddTaskPick` (auto-create "Standard Chat")** —
   wrote `?view=task&task=X` with no breadcrumb.
3. **`Sidebar.handleRunRoutine`** — wrote `?view=task&task=X&session=X`
   with no breadcrumb.
4. **`AppLayout.handleNavigate('task')`** — dead-code branch
   (kept for symmetry with the workspace branch; covered for future
   re-enable). Wrote `?view=task&task=X` ignoring the
   `workspaceId` / `itemId` / `pageId` positional args.
5. **`AppLayout.closeGitViewer` else-if-activeTask branch.**
6. **`AppLayout.closeSkillViewer` else-if-activeTask branch.**
7. **`AppLayout.closeCodeEditor` else-if-activeTask branch.**

Each of the 3 close-viewer branches already had the
`if (workspacesStore.activeWorkspaceItemId) { … } else if
(activeTask.value) { … } else { … }` priority chain — the
`else if (activeTask.value)` arm wrote a bare
`?view=task&task=X` without the breadcrumb.

## What landed

### 1. New helper — `src/apps/desktop/src/helpers/buildTaskUrlQuery.ts`

Centralises all `?view=task` URL building. Pure function (no Vue /
Pinia / vue-router imports) for trivially-testable behaviour.

Algorithm (resolution order for workspaceId + itemId):
1. Active store state (`activeWorkspaceId`, `activeWorkspaceItemId`)
   — authoritative source. If both are set, use them.
2. URL breadcrumb fallback (`route.query.workspaceId`,
   `route.query.itemId`) — for deep-link / share-link round-trips.
3. Else omit (chat-only task, unbound session).

Other params:
- `pageId` — only included when active item type is `'design'`
  (gate prevents cross-leak from a stale design page into a kanban URL,
  per `url-pageid-leak-design-to-non-design` plan, 2026-08-06).
  Source: `activeDesignPageId` from store, else URL breadcrumb.
- `sorts` — always preserved from URL (kanban view-specific, lives
  in the URL only; needed for `handleCloseTaskView`'s close-restore
  via `savedSortsParam`).
- `session` — included when caller passes `sessionId` (routine-run path,
  back-compat with the existing `task` + `session` shape).

Also exports `pickBreadcrumbFromQuery` (moved out of Sidebar.vue
where it was inlined as a non-reactive helper).

### 2. `Sidebar.vue` — 3 call sites updated

- `handleAddTaskPick` (auto-create Standard Chat) — passes active store
  state to `buildTaskUrlQuery`.
- `handleSelectTask` — passes active store state + `route.query`.
  Replaces the inlined `pickBreadcrumbFromQuery` spread with the helper.
  `parentItemId` local computation removed (the helper derives it
  from `activeWorkspaceItemId`).
- `handleRunRoutine` — passes active store state + `sessionId`.

The local `pickBreadcrumbFromQuery` function is deleted (moved to the
helper file). Replaced by a one-line "see file" comment.

### 3. `AppLayout.vue` — 4 call sites updated

- `handleNavigate('task')` — passes positional args (with store fallback).
- `closeGitViewer` `else if (activeTask.value)` branch.
- `closeSkillViewer` `else if (activeTask.value)` branch.
- `closeCodeEditor` `else if (activeTask.value)` branch.

Each passes the active store state (workspaceId, itemId, pageId, item
type) + `route.query` to `buildTaskUrlQuery`.

### 4. Tests — 4 new spec files / additions

| File | New | Status |
|---|---|---|
| `src/helpers/__tests__/buildTaskUrlQuery.spec.ts` (new) | 15 | All pass |
| `__tests__/sidebarHandleSelectTaskUrl.spec.ts` (existing) | +3 | All pass |
| `__tests__/AppLayout.urlPersist.spec.ts` (existing) | +4 | All pass |

The helper unit tests lock in the resolution order:
- Active store state always wins when both wsId + itemId are set.
- URL breadcrumb is the fallback.
- `pageId` is gated on `activeItemType === 'design'`.
- `sorts` is always preserved from the URL.
- `session` is included when passed.
- Whitespace / null / empty-string active ids all fall back to URL.

The `sidebarHandleSelectTaskUrl` additions lock in the user-facing
behaviour:

- "writes workspaceId from the active store even when the URL
  breadcrumb lacks it" — covers the user's actual scenario (URL
  refresh that landed on a task view without workspaceId).
- "always writes workspaceId for a kanban click" — the canonical
  `?view=task&task=X&workspaceId=W&itemId=K&sorts=S` shape.
- "writes workspaceId + itemId + pageId for a design click" — the
  design-mode variant with `pageId` preserved from URL.

The `AppLayout.urlPersist` additions lock in the close-viewer paths:

- `closeGitViewer` includes `workspaceId + itemId` when the active
  task belongs to a kanban.
- `closeGitViewer` falls to chat when no workspace item owns the
  task (defensive — no orphan context).
- `closeSkillViewer` includes `workspaceId + itemId + pageId` when
  the active task belongs to a design.
- `closeCodeEditor` falls through to chat when no workspace item
  owns the task.

## Why NOT a helper composable (e.g. `useTaskUrlQuery`)

The helper is a pure function — no Vue refs, no reactive state. Putting
it in `composables/` would mislead future contributors into thinking
it returns refs. `helpers/` matches the existing convention for
pure-function utilities (`unwrapToolOutput.ts`,
`stripTags.ts`, `autoStickGate.ts`).

## Why NOT a single `if (wsId) ... else use store` block

The 7 call sites have subtly different inputs:
- Some have positional `workspaceId` / `itemId` / `pageId` args
  (AppLayout.handleNavigate).
- Some have `currentQuery` (`route.query`) to fall back to
  (Sidebar.handleSelectTask).
- Some need `session` (Sidebar.handleRunRoutine).

A 7-call-site helper with a single input shape keeps the resolution
order in ONE place (the helper) and lets each call site describe its
specific inputs declaratively.

## Out of scope (deferred)

- LLM-side filtering — `task_workspaceId` isn't an agent tool yet.
- `kanban_move_task` agent tool — already records workspace_id server-side,
  no URL change needed (the SSE handler mirrors the local state).
- Per-task deep-link analytics — the user can already copy the URL,
  we don't need telemetry.
- Compaction — the `task_id == session_id` convention makes the
  chat task URL identical to a `view=chat` URL in most cases; the
  URL hygiene here is purely for the kanban / design case.

## Verification

- `bun run build` (vue-tsc + vite) — clean.
- `bunx vitest run src/helpers/__tests__/buildTaskUrlQuery.spec.ts` —
  15/15 pass.
- `bunx vitest run src/__tests__/sidebarHandleSelectTaskUrl.spec.ts` —
  8/8 pass (was 5/5; +3 new).
- `bunx vitest run src/__tests__/AppLayout.urlPersist.spec.ts -t
  'closeGitViewer|closeSkillViewer|closeCodeEditor'` — 7/7 pass.
- `bunx vitest run` (full suite) — 2070 pass / 19 fail. The 19
  failures are PRE-EXISTING on `main` (verified via `git stash`):
  - `AppLayout.memoriesGate.spec.ts` × 4
  - `AppLayout.urlPersist.spec.ts::handleNavigate('workspace', ...)`
    × 7 (all use `router.replace` mock but the actual code calls
    `router.push` — pre-existing test/code mismatch).
  - `DesignElement.spec.ts` static contract × 1
  - `DesignView.undoHidden.spec.ts` × 5
  - `AppLayout.translateResize.spec.ts` × 1
  - `DesignView.nudge.spec.ts` × 1

  No regressions introduced.

## Files

**New (2):**
- `src/apps/desktop/src/helpers/buildTaskUrlQuery.ts`
- `src/apps/desktop/src/helpers/__tests__/buildTaskUrlQuery.spec.ts`

**Modified (4):**
- `src/apps/desktop/src/components/shell/Sidebar.vue` (+38, -31 net)
- `src/apps/desktop/src/components/AppLayout.vue` (+59, -10 net)
- `src/apps/desktop/src/__tests__/sidebarHandleSelectTaskUrl.spec.ts`
  (+119, -5 net — added 3 new tests + updated 1 assertion to reflect
  new "workspaceId from store" behaviour)
- `src/apps/desktop/src/__tests__/AppLayout.urlPersist.spec.ts`
  (+151, -0 net — added 4 new tests in the existing
  `design item URL persistence` describe block)

**Doc (1):**
- `docs/superpowers/plans/2026-08-06-add-workspace-id-params.md` (this file)

## Branch / commit

- Branch: `worktree/add-workspace-id-params`
- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/add-workspace-id-params`