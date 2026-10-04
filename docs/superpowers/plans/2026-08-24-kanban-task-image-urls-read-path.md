# Kanban task image_urls — fix the read path + show images on board cards

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An image attached in the "New task" dialog must be visible in the "Task details" dialog after creation, and kanban board cards must render the attached image as a thumbnail.

**Architecture:** The persist path is already correct — `POST /api/workspaces/:wid/items/:iid/kanban/tasks` (all 3 modes) validates + INSERTs `image_urls` on `workspace_item_tasks`, and `create_and_run` / `create_session` also forward the `||`-joined string to the chat session. The bug is entirely on the READ path: the paginated task lister never SELECTs `t.image_urls`, the wire response struct has no `image_urls` field, and the create response doesn't echo it — so the frontend store never sees the images and the detail dialog's gallery (`props.task.imageUrls`) is always empty. On top of that, `PUT /api/workspaces/tasks/:task_id` parses `image_urls` but has no UPDATE branch (silently dropped), and no card component renders images at all.

**Tech Stack:** Zig 0.16 backend (`llm_history.zig`, `http_response.zig`, `tasks_list.zig`, `task_create.zig`, `task_update.zig`), Vue 3 + Pinia frontend (`WorkspaceItemTaskCard.vue`, `workspaces.ts` store). No migration — the `image_urls` column already exists (Migration 069).

## Global Constraints

- **Never kill the port 8081 server.** For any manual testing use port 8080 or another free port.
- **NO migration, NO schema change.** `workspace_item_tasks.image_urls` exists since Migration 069 (`TEXT NOT NULL DEFAULT ''`, `||`-delimited base64 data URLs).
- **Wire format stays `image_urls: string`** (`||`-joined) on every endpoint — matches `llm_history.image_url` convention. The frontend store's `normalizeTaskTags` already splits it into `string[]` at every fetch site; no store changes needed for the read path.
- **Empty-slice-binds-as-NULL rule:** any new SQL bind of `image_urls` must use the SQL `''` literal branch for the empty-string case (see memory `sqlite-backend-empty-slice-binds-as-null`). Follow the exact dynamic-SQL-builder pattern used by `tags` / `cwd` in the same files.
- **Per-request arena:** response slices are borrowed from `WorkspaceItemTaskInfo` (arena-owned) — no `defer free` in handlers.
- **SSE contract untouched:** `kanban_task` SSE events don't carry image data (and shouldn't — payloads are small). The existing SSE-triggered refetch (`kanbanSse.ts` → `fetchKanbanTasks`) picks up images automatically once the lister returns them.
- **Test convention:** static-contract tests in the same `*_test.zig` files (grep the source for the new SELECT column / struct field / wire field), plus the python functional harness for wire round-trips. `zig build test --summary all` must stay green (pre-existing failures documented in memory `mem_a1eabbc7daa573fa` are unrelated).
- **Commit after each task.**

## Files

| File | Action | Responsibility |
|---|---|---|
| `src/ai_workflow/tui/agentic_loop/llm_history.zig` | EDIT | `listWorkspaceItemTasksWithCursor`: add `t.image_urls` to SELECT (index 24), set `.image_urls` in the struct literal; static tests |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | EDIT | `WorkspaceItemTaskResponse`: add `image_urls: []const u8 = ""` field |
| `src/ai_workflow/tui/http_handlers/tasks_list.zig` | EDIT | Forward `task.image_urls` into the response literal; static test |
| `src/ai_workflow/tui/http_handlers/task_create.zig` | EDIT | `StandardResponse`: add `image_urls` field + echo `validated_image_urls` in the `.standard` response branch |
| `src/ai_workflow/tui/http_handlers/kanban_tasks_create.zig` | EDIT | `TaskCreateResponse` envelope: add `image_urls` + populate from `standard_result` |
| `src/ai_workflow/tui/http_handlers/task_update.zig` | EDIT | New `image_urls` UPDATE branch (validate via `image_urls_validation`, dynamic SQL builder); error mapping |
| `src/apps/desktop/src/components/workspace/WorkspaceItemTaskCard.vue` | EDIT | Image thumbnail strip on the card (first image, `+N` badge) |
| `src/apps/desktop/src/stores/workspaces.ts` | EDIT | `addKanbanTask`: normalize the create-response task's `image_urls` wire string before returning (so the optimistic task shows images immediately) |
| `src/apps/desktop/src/__tests__/kanbanCardImage.spec.ts` | NEW | Card thumbnail render tests |
| `tests/functional/kanban_task_image_urls_test.py` | NEW | Wire round-trip: create with image → list returns image_urls → PUT update image_urls |

---

## Root cause (verified 2026-08-24, main @ HEAD)

Persist path (all correct, no changes):
- `kanban_tasks_create.zig:180` forwards `parsed.image_urls` → `task_create.useCase` → `createStandardTask` validates (`image_urls_validation.validateImageUrls`) → `createWorkspaceItemTask` INSERTs the column (`llm_history.zig:4479-4488`).
- `create_and_run` / `create_session` also forward the `||`-joined string to `emit_run_agent` / the initial `llm_history` row (`kanban_tasks_create.zig:244,278,349`).

Read path (broken — this is the bug):
1. `llm_history.zig:5003` — `listWorkspaceItemTasksWithCursor`'s SELECT ends at `t.cwd` (index 23). `t.image_urls` is never selected.
2. `llm_history.zig:5078-5113` — the `WorkspaceItemTaskInfo` literal never sets `.image_urls`, so it stays the default `&.{}` even though the struct HAS the field (declared at `:4273`, freed correctly by `deinit` at `:4321`).
3. `http_response.zig:460-540` — `WorkspaceItemTaskResponse` has NO `image_urls` field, so even a populated `WorkspaceItemTaskInfo` couldn't reach the wire.
4. `tasks_list.zig:239` — the response literal forwards `tags` but has nothing for images.
5. `task_create.zig:207-226` — `StandardResponse` (the POST /tasks + kanban/tasks create response) has no `image_urls`, so the store's optimistic task object lacks images until a refetch (which, per 1-4, would never deliver them anyway).
6. `task_update.zig` — `TaskUpdateRequest.image_urls` is parsed (`http_response.zig:158`) but the useCase has no branch for it: image edits via PUT are silently dropped.

Frontend (feature gap, not a bug):
- `KanbanTaskDetailDialog.vue:930` — gallery reads `props.task?.imageUrls ?? []`; correct once the wire delivers the field (store normalizer `normalizeTaskImageUrlsInPlace` at `workspaces.ts:330` already splits `||` → `string[]` at every fetch site).
- `WorkspaceItemTaskCard.vue` / `KanbanCard.vue` — no image rendering at all.

---

## Task 1 — Backend read path: SELECT + struct + wire response

### Steps

- [ ] **1.1 Write failing static-contract tests** in `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` (follow the existing grep-the-source pattern):
  - Test "tasks_list llm_history SELECT includes t.image_urls": extract the `listWorkspaceItemTasksWithCursor` function body window from `llm_history.zig` (the `pub fn … pub fn` window trick used by existing tests), assert it contains `"t.image_urls"` and `"t.cwd"` (both must be in the same SELECT).
  - Test "tasks_list response forwards image_urls": assert `tasks_list.zig` source contains `.image_urls = task.image_urls`.
  - Test "WorkspaceItemTaskResponse declares image_urls": assert `http_response.zig` contains `image_urls: []const u8 = ""` inside the `WorkspaceItemTaskResponse` struct window.
  - Run: `zig build test --summary all 2>&1 | tail -n 20` — expect the 3 new tests FAIL.
- [ ] **1.2 Implement the SELECT change** in `llm_history.zig::listWorkspaceItemTasksWithCursor`:
  - Append `, t.image_urls` to the SELECT column list (AFTER `t.cwd`, index 24 — appending keeps every existing index stable; update the index doc-comment block at `:5038-5055` to document `24: image_urls (Migration 069 — ||-delimited base64 data URLs). NOT NULL DEFAULT ''`).
  - In the struct literal at `:5078`, add:
    ```zig
    // Migration 069 — image_urls (index 24). NOT NULL DEFAULT ''
    // so always present; empty string is the "no images" sentinel.
    // The frontend splits the ||-joined string into string[] via
    // normalizeTaskImageUrlsInPlace.
    .image_urls = try allocator.dupe(u8, row.values[24]),
    ```
- [ ] **1.3 Implement the wire field** in `http_response.zig::WorkspaceItemTaskResponse`:
  - Add after the `tags` field (keep `cwd` / `git_branch` after it to minimize diff noise):
    ```zig
    /// `||`-delimited base64 data URLs (Migration 069 — kanban
    /// image urls column). Empty string is the canonical "no
    /// images" sentinel (NOT NULL DEFAULT ''). Mirrors
    /// `WorkspaceItemTaskInfo.image_urls`. The frontend splits on
    /// `|` via normalizeTaskImageUrlsInPlace. Plan:
    /// docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md
    image_urls: []const u8 = "",
    ```
- [ ] **1.4 Forward it** in `tasks_list.zig` response literal (next to `.tags = task.tags` at `:239`):
  ```zig
  // Migration 069 — kanban image urls. `||`-delimited base64 data
  // URL string borrowed from WorkspaceItemTaskInfo.image_urls (the
  // per-request arena reaps it on request teardown).
  .image_urls = task.image_urls,
  ```
- [ ] **1.5 Run tests** — `zig build test --summary all`; the 3 new tests pass, no regressions (the `deinit` path already frees `image_urls` — no leak).
- [ ] **1.6 Commit** — `git commit -m "tasks list: SELECT + wire image_urls (Migration 069 read path)"`

---

## Task 2 — Create responses echo image_urls (optimistic UI)

### Steps

- [ ] **2.1 Write failing static tests** in `task_create_test.zig` + `kanban_tasks_create_test.zig`:
  - "StandardResponse declares image_urls" (grep `task_create.zig` for the field inside the `StandardResponse` struct window).
  - "standard branch echoes image_urls" (grep for `.image_urls = r.image_urls` in `task_create.zig`).
  - "kanban create response task carries image_urls" (grep `kanban_tasks_create.zig` for `.image_urls` inside the `TaskCreateResponse` construction window).
- [ ] **2.2 Implement in `task_create.zig`:**
  - `StandardResult` (the struct returned by `createStandardTask`): add `image_urls: []const u8 = ""` and populate it from `validated_image_urls` in the return at `:406`.
  - `StandardResponse` (`:207`): add `image_urls: []const u8 = ""` (doc comment: `||`-joined wire string, `''` = no images).
  - `.standard` response branch (`:816`): add `.image_urls = r.image_urls`.
- [ ] **2.3 Implement in `kanban_tasks_create.zig`:**
  - `http_response.TaskCreateResponse` (`:99`) gains `image_urls: []const u8 = ""`.
  - The envelope construction at `:395` becomes `.image_urls = standard_result.image_urls` (borrowed from the arena-owned `standard_result` — safe per the existing comment).
- [ ] **2.4 Frontend: normalize the create-response task** in `workspaces.ts::addKanbanTask` — wrap the successful return:
  ```ts
  const res = await api.createKanbanTask(workspaceId, itemId, wirePayload)
  // Migration 069 — the create response echoes image_urls as the
  // ||-joined wire string. Normalize in place so the optimistic
  // task object the caller receives already has imageUrls: string[]
  // (matches every other task shape in the store).
  if (res.task) normalizeTaskTags(res.task)
  return res
  ```
  (Note: `normalizeTaskTags` also normalizes dates + tags — harmless for the create response, which carries them as wire strings.)
- [ ] **2.5 Run tests** — `zig build test --summary all` + `cd src/apps/desktop && bun run test:run -- kanbanApiCreateTask workspacesStoreAddKanbanTask` (existing spec files cover the api/store layer; update their expected response literals if they assert exact wire shapes).
- [ ] **2.6 Commit** — `git commit -m "task create responses echo image_urls (optimistic gallery)"`

---

## Task 3 — PUT task_update: persist image_urls edits

### Steps

- [ ] **3.1 Write failing static test** in `task_update_test.zig`:
  - "task_update handles image_urls": assert `task_update.zig` contains `image_urls_validation` import and an `input.body.image_urls` branch.
  - "task_update maps InvalidImageUrls errors": assert the handler's error→status switch contains `error.InvalidImageUrls => 400` and `error.ImageUrlsTooLarge => 413`.
- [ ] **3.2 Implement** in `task_update.zig` (mirror the tags branch at `:234-261` exactly):
  - Import `image_urls_validation.zig`.
  - Add `InvalidImageUrls`, `ImageUrlsTooLarge` to `TaskUpdateError`.
  - New branch after the tags branch:
    ```zig
    // Image urls branch (Migration 069). Same shape as description
    // + tags: present (non-null) means overwrite; empty string is
    // the canonical "no images" sentinel and IS persisted (user
    // actively removed the images); null means "leave unchanged".
    if (input.body.image_urls) |raw_urls| {
        const validated = image_urls_validation.validateImageUrls(raw_urls) catch |err| return switch (err) {
            error.ImageUrlsTooLarge => error.ImageUrlsTooLarge,
            error.InvalidImageUrl => error.InvalidImageUrls,
        };
        // Dynamic SQL builder — empty string uses the SQL '' literal
        // (empty-slice-binds-as-NULL footgun).
        ...same shape as the tags branch...
    }
    ```
  - Handler error→status switch: `error.InvalidImageUrls => 400`, `error.ImageUrlsTooLarge => 413`; error→message switch entries matching the create handler's wording (`task_create.zig:760-761`).
- [ ] **3.3 Run tests** — `zig build test --summary all`.
- [ ] **3.4 Commit** — `git commit -m "task update: persist image_urls edits (PUT /workspaces/tasks/:id)"`

---

## Task 4 — Kanban board card shows the image

### Steps

- [ ] **4.1 Write failing component tests** in NEW `src/apps/desktop/src/__tests__/kanbanCardImage.spec.ts`:
  - Mount `WorkspaceItemTaskCard` with `task.imageUrls = ['data:image/png;base64,AAA']` → `find('[data-testid="task-image-thumb"]')` exists with `:src` = the data URL.
  - 3 images → thumb shows the FIRST image + `[data-testid="task-image-more"]` renders `+2`.
  - `imageUrls: []` / undefined → no thumb node.
  - Clicking the thumb emits `viewTaskDetail` (opens the detail dialog — same affordance as the `+N more` tags link).
- [ ] **4.2 Implement** in `WorkspaceItemTaskCard.vue`:
  - Script: `const firstImage = computed(() => props.task.imageUrls?.[0] ?? null)` and `const extraImagesCount = computed(() => Math.max(0, (props.task.imageUrls?.length ?? 0) - 1))`.
  - Template: insert a thumbnail strip between the description preview (`:560`) and the tags row (`:566`) — a single 48px-tall rounded thumb + `+N` overlay chip:
    ```vue
    <div
      v-if="firstImage"
      class="relative w-full rounded overflow-hidden shrink-0"
      style="max-height: 3rem;"
      data-testid="task-image-thumb-wrap"
    >
      <img
        :src="firstImage"
        alt=""
        class="w-full h-12 object-cover rounded cursor-pointer"
        data-testid="task-image-thumb"
        @click.stop="emit('viewTaskDetail', task.id)"
      />
      <span
        v-if="extraImagesCount > 0"
        class="absolute bottom-1 right-1 text-[10px] px-1.5 py-0.5 rounded font-medium"
        style="background: rgba(0,0,0,0.6); color: #fff;"
        data-testid="task-image-more"
      >+{{ extraImagesCount }}</span>
    </div>
    ```
  - `KanbanCard.vue` needs NO change — it wraps `WorkspaceItemTaskCard` and forwards the whole `task` prop.
- [ ] **4.3 Run tests** — `cd src/apps/desktop && bun run test:run -- kanbanCardImage` + `bun run typecheck`.
- [ ] **4.4 Commit** — `git commit -m "kanban card: image thumbnail strip (first image + N badge)"`

---

## Task 5 — Functional wire round-trip + verification

### Steps

- [ ] **5.1 Write the functional test** `tests/functional/kanban_task_image_urls_test.py` (harness at `tests/functional/harness.py`; NEVER port 8081):
  - `test_create_with_image_then_list_returns_image_urls`: create workspace + kanban item → POST `/api/workspaces/:ws/items/:item/kanban/tasks` with `{"mode":"create_session","name":"img task","image_urls":"data:image/png;base64,iVBORw0KGgo=","description":""}` → GET `/api/workspaces/:ws/items/:item/tasks?limit=10` → assert `tasks[0]["image_urls"] == "data:image/png;base64,iVBORw0KGgo="`.
  - `test_put_image_urls_updates_row`: same create → PUT `/api/workspaces/tasks/:task_id` with `{"image_urls":"data:image/jpeg;base64,/9j/4AAQ"}` → re-GET list → assert new value; PUT with `{"image_urls":""}` → assert cleared.
  - `test_create_response_echoes_image_urls`: assert the POST response body's `task.image_urls` equals the sent string (Task 2 contract).
- [ ] **5.2 Run the full verification suite:**
  ```bash
  zig build test --summary all 2>&1 | tail -n 5
  PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 \
    python3 -m pytest tests/functional/kanban_task_image_urls_test.py -v
  cd src/apps/desktop && bun run test:run && bun run typecheck
  ```
- [ ] **5.3 Manual smoke (optional, port 8080 only):** create a task with a pasted image via the New task dialog → click the card → Task details shows the gallery; the board card shows the thumbnail.
- [ ] **5.4 Commit** — `git commit -m "functional tests: kanban image_urls wire round-trip"`

---

## Pitfalls

- **Index shift:** appending `t.image_urls` at index 24 (AFTER `t.cwd`) keeps indices 0-23 stable. NEVER insert mid-SELECT — three other consumers read these indices positionally.
- **Empty-slice binds as NULL:** `SqliteBackend.exec` binds `""` as SQL NULL → NOT NULL violation. The `''` literal branch is mandatory for the empty case (Task 3).
- **Don't touch `listWorkspaceItemTasks`** (the legacy non-cursor lister at `:4729`) — it has NO production callers (only tests reference it). Leave it alone; the cursor lister is the only live path (`tasks_list.zig:137`).
- **`normalizeTaskTags` on the create response** mutates in place — call it only when `res.task` is non-null (the partial-success path returns `{task: null}`).
- **10 MB cap:** `image_urls_validation` enforces the total joined cap; the card renders only the FIRST image as a thumb, so a 10 MB payload doesn't N× the card render cost.

## Verification

- `zig build test --summary all` — new static-contract tests green, no new failures vs. the documented pre-existing baseline.
- `python3 -m pytest tests/functional/kanban_task_image_urls_test.py -v` — 3/3 pass.
- Frontend: `bun run test:run` + `bun run typecheck` green.
- Manual: image attached at create → visible in Task details dialog AND as a board-card thumbnail after refresh AND immediately (optimistic) without refresh.
