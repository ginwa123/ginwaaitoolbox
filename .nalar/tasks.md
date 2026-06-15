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
