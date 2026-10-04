# Task Ledger — Kanban: Embed ChatView inside KanbanView

**Plan:** `docs/superpowers/plans/2026-08-06-kanban-embed-chatview.md`
**Spec:** `docs/superpowers/specs/2026-08-06-kanban-embed-chatview-design.md`
**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-embed-chatview`
**Branch:** `worktree/kanban-embed-chatview`
**Started:** 2026-08-06
**Completed:** 2026-08-06 (all 6 tasks ✅)

## Tasks

- [x] **Task 1** — Move `activeTaskWorkspaceItemId` into `workspaces` store
       Commit: `6f107894 refactor(stores): move activeTaskWorkspaceItemId getter into workspaces store`
       Test: 3/3 pass in `workspaces.store.activeTaskWorkspaceItemId.spec.ts`
- [x] **Task 2** — Add chat-pane branch skeleton in `KanbanView` (no resize yet)
       Commit: `76f30216 feat(kanban): KanbanView renders chat pane when active task belongs to it`
       Test: 5/5 chat-pane tests pass (full-width, chat-pane visible, not visible, emit closeChat, chat-id)
- [x] **Task 3** — Move resize state machine into `KanbanView`
       Commit: `8fcaeb81 feat(kanban): move kanban resize state machine + handle into KanbanView`
       Test: 3/3 resize tests pass (drag updates width, mouseup persists to localStorage, 40% default fall-back)
- [x] **Task 4** — Wire `@close-chat` emit from `KanbanView` → `AppLayout`
       (Integrated with Task 3 commit — `closeChat` emit declared in defineEmits, ChatView's `@close` forwarded as `@close-chat`.)
- [x] **Task 5** — Delete 3-column block + resize state from `AppLayout`; unify mount; update test selectors
       Commit: `327bb43e refactor(applayout): delete 3-column block + kanban resize state, unify KanbanView mount`
       Test: 7/7 AppLayout.kanban.spec.ts pass after stub update + 4 resize tests deleted
- [x] **Task 6** — Final verification (vue-tsc, vitest, zig build, cross-compile, manual smoke, AGENTS.md changelog)
       Commit: `3e14c734 docs(agents): changelog entry for kanban-embed-chatview relocation`

## Verification gates

| Gate | Result |
|---|---|
| `node vue-tsc/bin/vue-tsc.js -b` | clean |
| `bun run build` | clean (1 pre-existing bundle warning) |
| `bunx vitest run` | 1809/1810 pass + 1 pre-existing `DesignView.nudge.spec.ts` flake (documented in AGENTS.md) |
| `zig build test --summary all` | 2145 pass + 6 skip + 2 leaks (same as main baseline; backend untouched) |
| `zig build-obj` Windows | clean |
| `zig build-obj` macOS | clean |
| Manual smoke (port 8080) | `POST /api/workspaces` + `GET /api/workspaces` both work — API still serving correctly |

## Net diff (my 5 commits vs previous worktree tip)

```
12 files changed, +793, -960
```

| File | Delta |
|---|---|
| `AppLayout.vue` | **-269** (3-column block + resize state + standalone mount) |
| `KanbanView.vue` | **+251** (chat-pane branch + resize state + handle JSX) |
| `workspaces.ts` | +26 (`activeTaskWorkspaceItemId` getter) |
| `KanbanView.chatPane.spec.ts` (NEW) | +269 (8 behavioural tests) |
| `workspaces.store.activeTaskWorkspaceItemId.spec.ts` (NEW) | +119 (3 behavioural tests) |
| `AppLayout.kanban.spec.ts` | -203 (4 deleted resize tests + stub update + selector updates) |
| `AppLayout.kanbanScrollPreservation.spec.ts` (DELETED) | -381 |
| `DesignChatCollapse.spec.ts` (DELETED — static-contract) | -174 |
| `DesignChatToggle.spec.ts` | -18 (deleted 1 static-contract test) |
| `AGENTS.md` | +14 (changelog entry) |
| `.pabrik/tasks-kanban-embed-chatview.md` (NEW) | +27 (this file) |

**Net: AppLayout.vue shrunk by 269 lines; KanbanView.vue grew by 251 lines; ~870 lines of test code added/deleted.**

## Branch status

Ready for review. PR not yet created (the user typically opens the PR after reviewing the commits).

The worktree can be merged to main with `git merge worktree/kanban-embed-chatview` (or via PR).
