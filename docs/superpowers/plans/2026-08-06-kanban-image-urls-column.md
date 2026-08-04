# Kanban image urls column (Migration 069, 2026-08-06)

## Goal

Replace the broken filesystem-backed attachment endpoints with a
self-contained `workspace_item_tasks.image_urls` TEXT column that
stores `||`-delimited base64 data URLs. Self-contained, no filesystem,
no upload endpoint, no broken GET route. Images render directly via
`<img :src="task.imageUrls[0]">`.

## User feedback

Verbatim (task `task_1785795051796`):
*"kanban task not saving the images or base 64 in kanban description,
after create a task or run aent"*

Follow-up:
*"dont use attachments, i thnk better new column to store images,
for kanban detail"*

Hint:
*"like column image_urls on llm_history"* — adopt the same
`||`-delimited convention used by `llm_history.image_url`.

## What landed

### Schema (Migration 069)

```sql
ALTER TABLE workspace_item_tasks ADD COLUMN image_urls TEXT NOT NULL DEFAULT ''
```

Idempotent via `addColumnIfMissing`. Empty string is the canonical
"no images" sentinel (matches `description` / `tags` patterns from
Migrations 062 / 067).

### Backend

| File | Change |
|---|---|
| `src/migrations/migration.zig` | New `Migration069AddTaskImageUrls` + registered in `allMigrations` |
| `src/ai_workflow/tui/llm_history.zig` | Added `image_urls` field to `WorkspaceItemTaskInfo`; `createWorkspaceItemTask` takes a new `image_urls` arg; the SELECT in `listWorkspaceItemTasksWithCursor` reads `t.image_urls` |
| `src/ai_workflow/tui/http_handlers/image_urls_validation.zig` (NEW) | `validateImageUrls(joined)` validates each `data:image/<mime>;base64,...` prefix + 10 MB cap |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | `TaskCreateRequest.image_urls`, `TaskUpdateRequest.image_urls`, `WorkspaceItemTaskResponse.image_urls` added |
| `src/ai_workflow/tui/http_handlers/task_create.zig` | Validates + persists `image_urls` on standard-task branch. Error mapping: `InvalidImageUrls → 400`, `ImageUrlsTooLarge → 413` |
| `src/ai/work_flow/tui/http_handlers/task_update.zig` | PATCH branch for `image_urls` (same dynamic SQL builder pattern as `description` / `tags`) |
| `src/ai_workflow/tui/http_handlers/tasks_list.zig` | Propagates `task.image_urls` into `WorkspaceItemTaskResponse.image_urls` |
| `src/main.zig` | **REMOVED** the `POST/GET /...attachments` routes |
| `src/ai_workflow/tui/http_handlers/task_attachment_post.zig` + `_get.zig` | **DELETED** |
| `src/ai_workflow/tui/http_handlers/mod.zig` | Replaced `pub const` for the deleted handlers with a comment explaining the removal |
| `src/migrations/migration_069_test.zig` (NEW) | 5 behavioural tests: column exists, idempotent re-run, backfill, round-trip, registered |
| `src/modules/agent/tools/create_kanban_task.zig` | Pass `null` for the new 9th arg |

### Frontend

| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | `Task.imageUrls?` added; `createTask`/`updateTaskSimple` accept `imageUrls` and `||`-join for the wire; `uploadTaskAttachment` REMOVED |
| `src/apps/desktop/src/stores/workspaces.ts` | Local `Task.imageUrls?` added; `normalizeTaskTags` now also folds in `normalizeTaskImageUrlsInPlace`; `addTask` + `updateTaskDetails` accept `imageUrls` |
| `src/apps/desktop/src/components/kanban/KanbanDescriptionEditor.vue` | Edit mode no longer uploads — stages in `pendingFiles` like create mode. Host PATCHes the column on Save |
| `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | New `<div class="kanban-task-detail-image-gallery">` above the description, renders `<img>` per URL. New `imageUrls` computed tracks `props.task?.imageUrls` |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | `handleCreateTaskSave` calls `updateTaskDetails({ imageUrls })` AFTER `moveTaskToColumn`. Plain `create` mode was the critical fix (images were previously lost). `create_and_run` mode ALSO forwards to `runAgentOnNewTask` |
| `src/apps/desktop/src/__tests__/KanbanView.createWithImages.spec.ts` (NEW) | 3 tests replacing the old `createWithAttachments.spec.ts` |
| `src/apps/desktop/src/__tests__/KanbanView.createWithAttachments.spec.ts` | DELETED |
| `src/apps/desktop/src/__tests__/KanbanDescriptionEditor.spec.ts` | Rewrote edit-mode test (was asserting "uploads inline", now asserts "stages in pendingFiles for the host to PATCH") |

### Behaviour (3 modes)

| Mode | Editor | Host | Result |
|---|---|---|---|
| **create** | Stage in `pendingFiles` | `addTask` → `convert` → `moveTaskToColumn` → `updateTaskDetails({ imageUrls })` | `image_urls` populated; kanban card + detail dialog show images |
| **create & run** | Same | Same + forward `imageUrls` to `runAgentOnNewTask` | Same + chatview's first user message shows thumbnails |
| **edit** | Stage add/remove in `pendingFiles` | `updateTaskDetails({ imageUrls })` (overwrite) | `image_urls` replaced |

### Verification

- `zig build test --summary all` → 2299/2305 pass (2 pre-existing leaks)
- `zig build-obj -target x86_64-windows-gnu` → clean
- `zig build-obj -target aarch64-macos` → clean
- `rm -rf zig-out/bin && zig build` → all 3 binaries compile
- `bunx vitest run` → 2074 pass / 16 fail (all 16 failures pre-existing on main per AGENTS.md baseline)

## Out of scope (deferred)

- Kanban card thumbnail
- Image resize / rotation / crop in the gallery
- Drag-and-drop reorder
- Per-task image count-limit
- Live "uploading..." indicator (FileReader is synchronous enough)
