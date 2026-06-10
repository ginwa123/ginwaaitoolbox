## [active] 20260610_170600 — fix scroll ratcheting (59% ↔ 57% oscillation) in ChatView

Plan: `docs/plans/2026-06-10-scroll-ratcheting-fix.md`
Branch: (not yet started — diagnostic + plan only this session)

### Diagnosis
- The user's log shows `scrollTop` and `scrollHeight` ratcheting in
  lockstep (Δ ±1265 px ≈ 6.3 items at defaultItemHeight=200) while
  `distanceFromBottom` stays constant at 17227 px.
- Smoking gun: this is **CSS scroll-anchoring** (overflow-anchor: auto,
  the browser default) reacting to topSpacer mutations from
  `VirtualScroller.measureItems()` re-measuring buffer items.
- The 2026-06-07 plan (`docs/plans/2026-06-07-virtual-scroller-fixed-height.md`)
  is the structural fix but clips long bubbles. This new plan is a
  surgical 2-line fix: hysteresis on `measureItems` (4 px dead-band) +
  `overflow-anchor: none` on `.virtual-scroller`.

### Tasks
- [x] Task 1: Add `HYSTERESIS_PX = 4` constant + 2-line check change
      in `VirtualScroller.vue` `measureItems()` ✅
- [x] Task 2: Add `overflow-anchor: none;` to `.virtual-scroller` CSS ✅
- [x] Task 3: `bun run build` clean (per project memory, NOT build-only) ✅
      180s build, exit 0, no TS errors
- [x] Task 3.5: `bunx vitest run` regression check ✅
      163/163 tests pass across 20 files
- [ ] Task 4: Manual test — open long chat, scroll to middle, observe
      scrollLogger for 5s — should see zero `direction-change` lines
      (deferred to user — runs in browser, not in this sandbox)
- [ ] Task 5: Resize-window test — no bounce after resize settles
      (deferred to user)
- [ ] Task 6: Stream test — no bounce during long assistant response
      (deferred to user)
- [ ] Task 7: Optional — extract `measureItems` to pure function and
      add `src/apps/desktop/src/__tests__/helpers/VirtualScroller.spec.ts`
      (skipped — change is small and surgical; existing tests cover
      the parent ChatView/VirtualScroller surface)

## [active] 20250606_175000 — workspace item task pagination (click-to-load)

Plan: `docs/plans/2026-06-06-workspace-item-task-pagination.md`
Worktree: `/home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-workspace-item-task-pagination`
Branch: `feature/workspace-item-task-pagination`

### Tasks
- [x] Task 1.1: Add `listWorkspaceItemTasksWithCursor` to llm_history.zig (commit 85c1930)
- [x] Task 1.2: Extend `WorkspaceItemTaskListResponse` + `makeWorkspaceItemTaskListResponse` in http_response.zig (commit 8533d96)
- [x] Task 1.3: Rewrite tasks_list.zig handler to use cursor pagination (commit 71c3f45; smoke-tested with 166-task DB, all edge cases pass)
- [x] Task 1.4: Add tasks_list_test.zig integration tests (commit 08369e3; 5 new tests pass, 272/275 total)
- [x] Task 2.1: Extend getTasks() API helper with limit/cursor (commit 64d0730; 1 test mock updated for new contract; 59/59 tests pass)
- [x] Task 2.2: Add per-item pagination state + loadMoreTasks action in workspaces store (commit eb2c7bb)
- [x] Task 2.3: Add workspacesStoreLoadMoreTasks.spec.ts unit tests (commit 05717b4; 7 new tests pass, 66/66 total)
- [x] Task 3.1: Add "Load More" button to WorkspaceItem.vue (commit e675e7d)
- [x] Task 3.2: Wire loadMoreTasks event through WorkspaceList + parent (commit cc92f99)
- [x] Task 3.3: Add workspaceItemTaskLoadMore.spec.ts component tests (commit a6c625c; 7 new tests pass, 73/73 total)

## [done] 20260609_103000 — remove skill_name parameter from get_skill tool ✅ MERGED to main at 00033c9

Plan: `docs/superpowers/plans/2026-06-09-remove-get-skill-name-parameter.md`
Worktree: `/home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/remove-get-skill-name`
Branch: `refactor/remove-get-skill-name`

### Tasks
- [x] Chunk 1: Schema, struct, and dead-code removal (Tasks 1-3, get_skill.zig) ✅
  - [x] Task 1: Drop `skill_name` from `GetSkillInput` struct
  - [x] Task 2: Drop `skill_name` property from JSON schema
  - [x] Task 3: Drop `loadSkillByName` branch + function (commits a567569, f43a97b)
  - [x] Spec review for Chunk 1 ✅
  - [x] Code quality review for Chunk 1 ✅
- [x] Chunk 2: Test updates (Tasks 4-7, get_skill_test.zig) ✅
  - [x] Task 4: Update property-count + default-field assertions
  - [x] Task 5: Delete `skill_name`-only tests; rename InvalidInput test
  - [x] Task 6: Delete `loadSkillByName`-only tests
  - [x] Task 7: Rewrite "loaded skill" test to use `path` (commit 1ae61f0)
  - [x] Spec review for Chunk 2 ✅
  - [x] Code quality review for Chunk 2 ✅
- [ ] Chunk 3: Prompt text updates (Tasks 8-10, 3 prompt files)
  - [ ] Task 8: Update `agentic.zig` prompt example
  - [ ] Task 9: Update `specialized.zig` prompt examples
  - [ ] Task 10: Update `research.zig` prompt examples
  - [ ] Spec review for Chunk 3
  - [ ] Code quality review for Chunk 3
- [x] Final verification: 269/272 tests pass (3 skipped, 0 failed); no stray get_skill("...") in src/
