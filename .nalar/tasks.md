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
