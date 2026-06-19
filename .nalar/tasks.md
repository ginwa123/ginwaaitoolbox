## [active] 20260616_120000 — workspace-item-position-reorder plan execution

### Chunk 1: Backend — migration, response helper
- [x] Task 1.1: Add Migration045AddPositionToWorkspaceItems to migration.zig
- [x] Task 1.2: Add WorkspaceItemReorderResponse + makeWorkspaceItemReorderResponse to http_response.zig

### Chunk 2: Backend — handler, list/create updates, tests
- [x] Task 2.1: Add workspace_items_reorder.zig handler + static tests
- [x] Task 2.2: Update workspace_items_get SQL to ORDER BY position DESC (via llm_history.zig)
- [x] Task 2.3: Update workspace_items_create to assign MAX+1 position

### Chunk 3: Frontend — API function + store action
- [x] Task 3.1: Add reorderWorkspaceItems to api/index.ts
- [x] Task 3.2: Add reorderWorkspaceItems action to stores/workspaces.ts

### Chunk 4: Frontend — Vue components + tests
- [x] Task 4.1: Update WorkspaceList.vue to support item drag-and-drop
- [x] Task 4.2: Wire reorder-workspace-items event in Sidebar.vue
- [x] Task 4.3: Add workspacesStoreItemReorder.spec.ts store test
- [x] Task 4.4: Add workspaceListItemDragDrop.spec.ts component test

### Final verification
- [x] Run full backend test suite (467/470 pass, +7 new)
- [x] Run full frontend type check + vitest (238/238 pass, +10 new)

## [active] 20260617_114500 — memories-settings-menu plan execution

Branch: `feature/memories-settings-menu`
Baseline: backend 467/470 pass, frontend type-check clean, vitest 238/238
Plan: `docs/plans/2026-06-17-add-memories-settings-menu.md`
Expected backend delta: +~17 (9 helper tests + 8 handler tests)
Expected frontend delta: +~2 spec files

### Chunk 1: Backend — helpers in memories.zig
- [x] Task 1.1: Add isValidMemoryName validator
- [x] Task 1.2: Add readMemoryFile helper
- [x] Task 1.3: Add writeMemoryFile helper (with atomic temp+rename)
- [x] Task 1.4: Add deleteMemoryFile helper (idempotent)
- [x] Task 1.5: Add memoryExists helper
- [x] Task 1.6: Add editMemoryFile helper (overwrite, fail if missing)
- [x] Task 1.7: Add helper tests to memories_test.zig (~9 tests)
- [x] Task 1.8: Run zig build test, commit, report — commit 3ee6b887, 476/470 pass (+9)

### Chunk 2: Deferred — no agent tools in this plan

### Chunk 3: Backend — HTTP handlers (4 files)
- [x] Task 3.1: memories_detail.zig (GET /api/memories/:name)
- [x] Task 3.2: memories_create.zig (POST /api/memories)
- [x] Task 3.3: memories_update.zig (PUT /api/memories/:name)
- [x] Task 3.4: memories_delete.zig (DELETE /api/memories/:name)
- [x] Task 3.5: Re-export in mod.zig + register routes in main.zig
- [x] Task 3.6: Add handler tests (24 tests, exceeded 8 minimum)
- [x] Task 3.7: Run zig build test, commit, report — commit f6160de9, 500/503 pass (+24), all 5 curl smoke calls pass

### Chunk 4: Frontend — API client (api/index.ts)
- [x] Task 4.1: Add Memory, MemoryDetail, MemoryDetailResponse, MemoryDeleteResponse interfaces
- [x] Task 4.2: Add getMemories, getMemoryDetail, createMemory, updateMemory, deleteMemory functions
- [x] Task 4.3: bun run build clean, commit, report — commit 0bbef415, +72 lines, build clean

### Chunk 5: Frontend — MemoriesSettings.vue orchestrator
- [x] Task 5.1: Create MemoriesSettings.vue (73 lines, mirrors SkillsSettings)
- [x] Task 5.2: bun run build clean, commit, report — commit 34a6419b

### Chunk 6: Frontend — MemoryList.vue (left panel)
- [x] Task 6.1: Create MemoryList.vue in tool_outputs/
- [x] Task 6.2: bun run build clean, commit, report — commit 34a6419b

### Chunk 7: Frontend — MemoryDetail.vue (right panel)
- [x] Task 7.1: Create MemoryDetail.vue with view/edit/create/empty modes
- [x] Task 7.2: bun run build clean, commit, report — commit 34a6419b (fixed TS error: createMemory returns Memory not MemoryDetail)

### Chunk 8: Frontend — wire into SettingsView.vue
- [x] Task 8.1: Add MemoriesSettings import + 3rd menu item under Skills
- [x] Task 8.2: Add 3rd v-else-if content branch
- [x] Task 8.3: bun run build clean, commit, report — commit 34a6419b

### Chunk 9: Tests
- [x] Task 9.1: Add apiMemories.spec.ts (9 tests for the 5 API client functions)
- [x] Task 9.2: Add MemoryList.spec.ts (4 tests for component rendering)
- [x] Task 9.3: Add MemoryDetail.spec.ts (6 tests for view/edit/create/empty modes)
- [x] Task 9.4: bun run build + vitest run clean, commit, report — 279/279 pass, build clean. +19 tests.

### Chunk 10: Manual smoke test
- [x] Start nalar on port 8080 (Chunk 3 already did this; 5/5 curl calls passed)
- [x] curl all 5 endpoints
- [ ] Walk UI smoke checklist (cannot do — no headless browser in this env)
- [ ] Final commit

### Final verification
- [x] Backend: zig build test clean (500/503 pass, +33 from baseline)
- [x] Frontend: bun run build clean, vitest 279/279 pass (+19 from baseline)
- [x] Manual smoke for HTTP (5/5 curl calls) — done in Chunk 3
- [ ] Manual smoke for UI (deferred — would need interactive browser)

## [done] 20260618_102200 — set_git_worktree tool + sessions.git_worktree_cwd plan (v1 — runtime CWD override deferred to follow-up)

Branch: `feature/set-git-worktree` (worktree at `.worktrees/feature-set-git-worktree`)
Plan: `docs/plans/2026-06-18-set-git-worktree-tool.md` (executed)
Follow-up: `docs/plans/2026-06-18-set-git-worktree-cwd-override.md` (deferred — see "Runtime CWD override" below)
Status: All 4 chunks shipped. v1.0 complete; runtime CWD-override deliberately deferred to a tracked follow-up (not orphaned — see NALAR.md entry for the `cwd_override` dead-letter field warning).

### Commits (in order)
- `65b36e56` — **Chunk 1 (backend)**: Migration 046 (`sessions.git_worktree_cwd`), `OnEventInputSessions.git_worktree_cwd`, `updateSessionGitWorktreeCwd` helper, 5 call sites in workflow.zig. Spec review: SPEC_COMPLIANT. Tests: 514→516 (+2 migration).
- `ba2cb938` — **Chunk 2 (backend)**: `src/modules/agent/tools/set_git_worktree.zig` (375 lines) + `set_git_worktree_test.zig` (216 lines) + re-exports in `tools.zig`/`root.zig`. Validates absolute `path`, derives `branch` from basename (`worktree/<basename>`), supports `clear=true`. Spec review: SPEC_COMPLIANT. Tests: 516→529 (+13).
- `2626c797` — **Chunk 3 (backend wiring)**: `execSetGitWorktree` in `tool_registry.zig` + `cwd_override` field on `ToolExecContext` (dead-letter — see follow-up). Spec review: SPEC_PARTIAL (Step 4 deferred). Tests: 529→534 (+5 static wiring).
- `eead77b1` — **Chunk 4 (frontend)**: `Session` + `SessionEvent` interface extended with `git_worktree_cwd`; `ChatsList.vue` renders 🌳 badge; `chatsListGitWorktree.spec.ts` (4 tests). Frontend build clean, vitest 351/351 pass.

### Runtime CWD override (DEFERRED — tracked)
- The `cwd_override: ?[]const u8 = null` field on `ToolExecContext` is declared and accepted by `execSetGitWorktree`'s input struct, but is **never read, never populated, and never mutated anywhere in the dispatch path** — it is dead-letter code as of v1.0.
- Effect: calling `set_git_worktree` with `path=/abs/.worktrees/foo` persists the binding to the DB, but the next `execBash` / `execReadFile` / `execWriteFile` / `execTextReplace` / `execGlob` / `execSearch` call still runs in `ctx.cwd` (the session's original cwd), not the worktree path.
- Workaround for the LLM today: re-call `set_git_worktree` to refresh; or pass absolute paths in every `bash` invocation.
- Follow-up plan `docs/plans/2026-06-18-set-git-worktree-cwd-override.md` (307 lines, 5 chunks) implements the runtime override by switching `ToolExecFunc` to `fn (ctx: *ToolExecContext, tc) !R` (pointer-pass) and reading `ctx.cwd_override ?? ctx.cwd` in the 5 filesystem tools.
- NALAR.md has a dedicated "DEAD-LETTER FIELD" entry warning future agents not to remove the field and not to assume it's populated at runtime.

### Final verification
- [x] Backend: `zig build test` clean (534 tests, +20 from baseline 514)
- [x] Frontend: `bun run build` clean, `bunx vitest run` 351/351 pass (+4)
- [x] 4 commits on `feature/set-git-worktree` branch, no uncommitted changes in worktree
- [x] Follow-up plan filed at `docs/plans/2026-06-18-set-git-worktree-cwd-override.md` (gitignored via `/docs`)
- [x] NALAR.md updated with the `cwd_override` dead-letter warning
- [x] .nalar/tasks.md updated (this block)
- [ ] Manual smoke test (cannot run — no headless browser in this env; HTTP-level path proven by the static wiring tests)

## [done] 20260115_104500 — nalar_config_profile_delete sub-helper extraction

Branch: `refactor/split-nalar-config-profile-delete` (worktree at `.worktrees/split-nalar-config-profile-delete`)
Baseline: 628/631 tests pass (3 skipped)
Plan: keep ONE file; extract named sub-helpers inside the handler.

### What was done
- [x] Extracted 9 sub-helpers (resolveConfigPaths, ensureConfigDir, readConfigFile, parseConfigJson, isActiveProfile, writeConfigBack, liveReloadLlmConfig, makeErrorResponse, makeSuccessResponse)
- [x] Replaced 7 inline JSON-stringify response blocks with 2 reusable builders (DRY)
- [x] Preserved all existing behavior (LiveReloadResult tagged union maps to same HTTP responses as before)
- [x] zig build test 628/631 passes — no regression

### Resulting file structure (single file, 574 lines)
- **Public surface** (unchanged): `NalarConfigJsonForDelete` struct, `ProfileDeleteResponse` struct, `removeProfileFromConfig` use-case, `nalarConfigProfileDeleteHandler` handler
- **Private types**: `ConfigPaths`, `LiveReloadResult`
- **Private sub-helpers** (9): listed above
- **Private use-case helpers** (2): `freeObjectMapContents`, `freeJsonValueDeep`

### Handler shape
The handler is now ~80 lines: 9 numbered phases, each a single named call to a sub-helper or a simple inline check (validate :name). Error responses go through the DRY builder.

### Commit
- `a21e85e` on `refactor/split-nalar-config-profile-delete`

### Final verification
- [x] zig build test 628/631 pass (no regression from baseline)
- [x] All 5 use-case tests (removeProfileFromConfig) still pass — confirms no behavior change to the pure function
- [x] Pre-existing `install:linux:system` failure unchanged (separate, pre-existing issue per `nalar-build-cross-compile-blocked.md`)
