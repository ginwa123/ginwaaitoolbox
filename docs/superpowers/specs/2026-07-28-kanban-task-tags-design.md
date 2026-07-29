# Kanban Task Tags — Design

> **For agentic workers:** This is a design spec. After the user approves, the next step is to invoke the `superpowers:writing-plans` skill to create a bite-sized implementation plan.

**Goal:** Add free-form `tags` to kanban tasks. Tasks can carry 0+ tags (each a short lowercase string). Tags render on the kanban card as colored chips and can be edited in the task detail dialog. No managed vocabulary, no tag management UI, no filtering — forward-compatible with a future managed-tag migration.

**Architecture:** One new column on `workspace_item_tasks` storing a JSON-encode array of strings (matching the existing `description` Migration 062 pattern). Validate at the HTTP boundary (trim, dedupe case-insensitive, reject forbidden chars). Render as a chip input in `KanbanTaskDetailDialog` and as a row of chips on `WorkspaceItemTaskCard`. Chip color = hash of lowercase tag name → 6-color palette (deterministic, no precomputed lookup).

**Tech Stack:** Zig 0.16 (backend), SQLite (via `nalarcore.sqlite.SqliteBackend`), Vue 3 + TypeScript + Vitest (frontend). No new dependencies. No new packages.

## 1. Why now — the problem

Kanban tasks have no categorization today. The only way to "group" tasks is by kanban column. Users have asked for the ability to tag cards like "bug", "urgent", "frontend" — visible at a glance on the board, editable in the detail dialog. The current `task_type` column (`standard` | `routine` | `memory`) is a fixed enum, not a user-facing label.

## 2. Current state — what exists today

- `workspace_item_tasks` table (Migration 034) with: `id, name, workspace_item_id, created_at, updated_at`
- `task_type` (Migration 044), `description` (Migration 062), `kanban_column_id`/`position` (Migration 048), `last_human_touched_at` (Migration 065)
- `WorkspaceItemTaskInfo` struct in `src/ai_workflow/tui/llm_history.zig` (DB layer) — carries the row data
- `WorkspaceItemTaskResponse` in `src/ai_workflow/tui/http_handlers/http_response.zig` (wire) — exposed via `GET /api/workspaces/:ws/items/:item/tasks`
- `Task` interface in `src/apps/desktop/src/stores/workspaces.ts` (frontend store)
- `KanbanTaskDetailDialog.vue` (create + edit modes) renders: name, metadata strip, description (with editor + preview), unattended-mode toggle
- `WorkspaceItemTaskCard.vue` (the card on the board) renders: type badge, pin icon, title, description preview, meta row, notification icon
- `KanbanColumn.vue` reads from `item.tasks` (lazy-loaded via `workspacesStore.fetchKanbanTasks`)

## 3. Design — schema, wire, UX

### 3.1 Schema

**Migration 067** — `add_task_tags`:

```sql
ALTER TABLE workspace_item_tasks ADD COLUMN tags TEXT NOT NULL DEFAULT '';
```

Stored as a JSON-encode string of an array of strings:

- `''` (empty string) — no tags
- `'["bug","urgent","frontend"]'` — three tags

**Why JSON string, not a separate table:**
- No managed vocabulary in v1 (no need for tag IDs, colors, renaming)
- The user explicitly chose "free-form string list" (Option A from the brainstorm)
- Forward-compatible: a future migration can (1) add a `tags` table, (2) `INSERT INTO tags … FROM json_each(tasks.tags)`, (3) add a `task_tags` join table, (4) drop the column. The column's JSON shape is the natural source of truth for the migration.

**Why no `tags` index in v1:** No SQL-level filtering by tag in v1 (substring search comes later when the board needs a filter chip). Indexing a JSON-encoded string would be expensive and not queryable by JSON paths without SQLite's JSON1 extension (which we don't use).

### 3.2 Validation rules

Applied in `task_create.zig` AND `task_update.zig` (extracted into a shared `validate_tags.js`-style helper or inlined in both):

| Rule | Behavior |
|---|---|
| Empty input (`null` or `""`) | OK — task has no tags |
| Non-empty input | Parse JSON; must be a JSON array of strings |
| Tag values | Trim whitespace; reject empty after trim |
| Trimmed values | Restrict chars to `[a-zA-Z0-9_-]` (GitHub-style) — reject if any tag contains other chars |
| Length per tag | ≤ 50 chars |
| Duplicate within same task | Dedupe case-insensitively (preserve case of first occurrence) |
| Duplicates surviving validation | If after dedupe the array is empty, return 400 `InvalidTags` |
| Validation error | 400 status, message lists the offending index (e.g. `"tags[2] contains forbidden character ' '"`) |

**Why per-tag (50 chars) not per-task:** keeps the JSON column size reasonable; matches GitHub label limits.

**Why dedupe case-insensitively:** "Bug" and "bug" are the same tag, semantically. The first occurrence wins (preserves the user's original casing for display).

### 3.3 Wire shape

**`WorkspaceItemTaskInfo` (DB layer, `llm_history.zig`):**

```zig
tags: []u8 = &.{},  // JSON-encoded array, free + deinit; empty slice means "no tags"
```

**`WorkspaceItemTaskResponse` (wire, `http_response.zig`):**

```zig
/// JSON-encoded array of tag strings. Empty string = no tags.
/// Added by Migration 067 (kanban task tags feature).
tags: []const u8 = "",
```

**`TaskCreateRequest` (wire, `http_response.zig`):** add `tags: ?[]const u8 = null` (null = no tags supplied, same as empty `[]`).

**`TaskUpdateRequest` (wire, `http_response.zig`):** add `tags: ?[]const u8 = null` (null = don't change; `""` = clear all tags; `'[…]'` = replace).

**`Task` interface (frontend, `stores/workspaces.ts`):**

```ts
tags?: string[]  // optional for backwards compat with legacy task literals
```

**Frontend JSON encoding:** the frontend serializes `string[]` to JSON string before putting it on the wire (so the backend sees a string, not an array — single source of truth for JSON shape). Decoding on the frontend is a `JSON.parse(tags)` call.

### 3.4 UX

**`KanbanTagsInput.vue` (new component) — chip input:**

```
┌─────────────────────────────────────────────┐
│ [bug ✕]  [urgent ✕]  [frontend ✕]           │
│ Add tags (letters, digits, hyphens)...      │
└─────────────────────────────────────────────┘
```

- **Add a tag:** type in the input, press Enter (or comma) → chip appears, input clears
- **Remove a tag:** click the chip's ✕, OR press Backspace on an empty input → removes the last chip
- **Duplicate prevention:** typing an existing tag (case-insensitive) and pressing Enter → no-op (no duplicate chip)
- **Forbidden char prevention:** chars outside `[a-zA-Z0-9_-]` are either blocked at input (keydown filter) or rejected with a subtle inline error message (`data-testid="kanban-tags-input-error"`)
- **Color determinism:** `hashCode(tag.toLowerCase()) % 6` → 1 of 6 colors. Same tag = same color across the board.
- **No max count** — list grows downward. The dialog grows accordingly (not a fixed-height component).

**`KanbanTaskDetailDialog.vue` (existing dialog, edit):**

Adds a new section between the description and the unattended-mode toggle:

```
Description
[editor ...]
[Preview] button

Tags
[<KanbanTagsInput>]

Unattended mode
[toggle]
```

**`KanbanTaskDetailDialog.vue` (existing dialog, create):**

Same section, just empty. Default tag list = `[]`.

**`WorkspaceItemTaskCard.vue` (existing card):**

Adds a row of chips below the task title (above the description preview):

```
┌─────────────────────────────┐
│ [📌] bug fix                │  ← title (existing)
│ [bug] [urgent] [frontend]   │  ← NEW: tags row (max 3 visible, +N more)
│ Fix login flow...           │  ← description preview (existing)
└─────────────────────────────┘
```

- Up to 3 chips visible. If `task.tags.length > 3`, render `+N more` as a thin text link that opens the detail dialog (re-uses the existing `viewTaskDetail` emit).
- Empty tags → row doesn't render (no empty state).
- Chip styling: same as the input, 9px font, smaller padding.

### 3.5 Color palette (deterministic)

6 colors, indexed by `hashCode(tag.toLowerCase()) % 6`:

| Index | Name | Light bg (alpha 0.18) | Border (alpha 0.45) | Text |
|---|---|---|---|---|
| 0 | violet | `rgba(139, 92, 246, 0.18)` | `rgba(139, 92, 246, 0.45)` | `#a78bfa` |
| 1 | blue | `rgba(59, 130, 246, 0.18)` | `rgba(59, 130, 246, 0.45)` | `#60a5fa` |
| 2 | green | `rgba(34, 197, 94, 0.18)` | `rgba(34, 197, 94, 0.45)` | `#4ade80` |
| 3 | amber | `rgba(245, 158, 11, 0.18)` | `rgba(245, 158, 11, 0.45)` | `#fbbf24` |
| 4 | orange | `rgba(249, 115, 22, 0.18)` | `rgba(249, 115, 22, 0.45)` | `#fb923c` |
| 5 | red | `rgba(239, 68, 68, 0.18)` | `rgba(239, 68, 68, 0.45)` | `#f87171` |

Hash function: djb2 (`hash = ((hash << 5) + hash) + char` → unsigned 32-bit). Deterministic across runs, no random seed.

## 4. API surface — endpoints

### 4.1 `POST /api/workspaces/:ws/items/:item/tasks`

Body gains `{ tags?: string[] }`. Backend re-encodes to JSON string, validates, persists. Already-present `description` field uses the same pattern.

### 4.2 `PUT /api/workspaces/:ws/items/:item/tasks/:task_id` (full update)

Body gains `{ tags?: string[] }` (same as create). Backend decodes existing value, validates, replaces.

### 4.3 `PUT /api/workspaces/tasks/:task_id` (simple update)

Body gains `{ tags?: string[] }`. Same validation + replacement.

### 4.4 `GET /api/workspaces/:ws/items/:item/tasks` (list)

Response gains `tags: string` field on each task (JSON-encoded array). Same decode pattern as `description` (already-empty `'""'` becomes `[]` on the frontend).

## 5. What does NOT change (out of scope)

- **Tag filtering on the kanban board** — not in v1. The user can search tags by substring later when they need to.
- **Tag management page** — no list of all tags, no rename, no merge.
- **Tag autocomplete** — the chip input does not suggest existing tags. Users can still re-type any tag freely.
- **Tag rename propagation** — if a user has 5 tasks with "bug" and renames one to "Bug", they're now 2 distinct tags. This is the expected behavior for free-form strings.
- **Tags on routine / memory tasks** — the editor accepts tags for all task types. The card on the kanban board (the only place tags render in v1) only shows up when the parent is a kanban; non-kanban tasks carry tags in the DB but don't render them. Future feature: show tags on the chat sidebar's task list.
- **SSE event for tag changes** — not in v1. Tags render on next kanban refresh (existing kanban SSE reconciliation already handles this). If a user clicks "Save" in the detail dialog, the SSE event fires for the kanban-task update with `tags` in the payload (extending `KanbanTaskEventPayload`).

## 6. Acceptance criteria

1. Migration 067 runs cleanly on a fresh DB AND on an existing DB (legacy DBs without the column get `''` defaults).
2. `POST /tasks` with `tags: ["bug","urgent"]` persists and the response includes the tags as a JSON-encoded array.
3. `POST /tasks` with `tags: [""]` returns 400 `InvalidTags` (after trim, empty).
4. `POST /tasks` with `tags: ["bug","Bug"]` deduplicates → stores `["bug"]`.
5. `POST /tasks` with `tags: ["with space"]` returns 400 `InvalidTags` (forbidden char).
6. `POST /tasks` with `tags: ["x".repeat(51)]` returns 400 `InvalidTags` (too long).
7. `PUT /tasks/:id` with `tags: [{"$ne":[]}]` (or any non-array) returns 400 `InvalidTags`.
8. `WorkspaceItemTaskCard` renders up to 3 tag chips; renders `+N more` if `tags.length > 3`.
9. `KanbanTaskDetailDialog` (edit mode) shows existing tags as removable chips, allows adding new ones.
10. `KanbanTaskDetailDialog` (create mode) starts with empty tags, accepts new tags.
11. Typing a tag in the chip input and pressing Enter adds the chip; backspace on empty input removes the last chip.
12. Chip colors are deterministic: same tag string = same color across the board.
13. The `tags` row doesn't render on the card when the task has no tags (no empty state).

## 7. Decisions taken (with rationale)

1. **Free-form string list (Option A from brainstorm)** — chose simplicity over managed vocabulary. Forward-compatible: a future migration can read the JSON array and create proper tag rows.
2. **JSON string column, not a separate table** — no SQL-level filtering needed in v1; matches the existing `description` pattern (also a TEXT column with arbitrary content).
3. **No tag filter on the board in v1** — out of scope, easy to add later (a `?tag=bug` query param + a chip row above the board).
4. **No `tags` index in v1** — strings in the column are JSON arrays; SQLite can't index JSON paths without JSON1 extension. Filtering happens at the application layer (after deserialize).
5. **Per-tag char whitelist `[a-zA-Z0-9_-]`** — matches GitHub label rules. No spaces, no commas (the user's input is naturally space/comma-separated via Enter key).
6. **Per-tag length cap 50 chars** — same as GitHub labels. Reasonable for a free-form tag.
7. **Case-insensitive dedupe** — "Bug" and "bug" are the same tag. Preserves first-occurrence casing for display.
8. **Djb2 hash for color** — deterministic, no precomputed map, fast enough for ≤ 30 tags per task.
9. **6-color palette** — same colors already used by the project (`--color-violet`, `--color-blue`, `--color-green`, `--color-amber`, `--color-orange`, `--color-red`). Reuses existing CSS vars.
10. **Tags render on the card AND in the dialog** — gives instant visual feedback AND an editing surface. Not OR.

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Migration 067 fails on a legacy DB | Use `addColumnIfMissing` (the project's safe helper) + idempotent `IF NOT EXISTS` (already in every migration). |
| Empty `[]const u8` bound as SQL NULL (breaks NOT NULL) | Empty string is the default. Use SQL `''` literal, not a `?` bind (mirrors `description` pattern from Migration 062). |
| Tags array in JSON exceeds TEXT limit (SQLite default ~1GB) | 50-char cap × unbounded count, but typical use is 1-30 tags. No realistic limit. |
| Vue's `v-model` on `string[]` causes re-renders on every keystroke | Use a `ref<string[]>` + chip input pattern (no v-model on the input itself). Chip add/remove is a discrete event. |
| TypeScript legacy task literals (8+ test files) break on `tags?: string[]` | Optional field — missing `tags` is treated as `undefined`, behaves the same as `[]`. |
| `vue-tsc --build` doesn't catch template-type errors | Test render with `vitest` + manual smoke against port 8080 (NEVER 8081). |
| Lazy analysis in `zig build test` misses a callsite | Run `zig build install:linux:system` + `rm -rf zig-out/bin && zig build` after every change. |
| `parseFromSlice` deinit footgun (borrowed slices) | Use `parseFromSliceLeaky` (per-request arena reaps everything). Already the project convention. |
| `ts` indexOutOfBounds on `tags` field if backend returns missing field | Defensive: `task.tags ?? []` everywhere. Same pattern as `description ?? ''`. |
| User writes the same tag with different casing (e.g. "Bug" and "bug") | Backend dedupe case-insensitively. Preserves first-occurrence casing for display. |
| Cross-platform build (Windows/macOS) breaks on the new tag code | Use `nalarcore.helpers.*` everywhere (no `std.posix.*`). `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` and `aarch64-macos` to verify. |

## 9. File touch map (preview — final list in the plan)

Backend (6 files):
- `src/migrations/migration.zig` — register Migration 067 in `allMigrations`
- `src/migrations/migration_067_test.zig` — NEW — migration tests
- `src/ai_workflow/tui/llm_history.zig` — `WorkspaceItemTaskInfo.tags` + `createWorkspaceItemTask` + `getWorkspaceItemTask` + `listWorkspaceItemTasksWithCursor` + `updateWorkspaceItemTask`
- `src/ai_workflow/tui/http_handlers/http_response.zig` — `WorkspaceItemTaskResponse.tags` + `TaskCreateRequest.tags` + `TaskUpdateRequest.tags`
- `src/ai_workflow/tui/http_handlers/task_create.zig` — accept + validate `tags` + persist
- `src/ai_workflow/tui/http_handlers/task_update.zig` — accept + validate `tags` + persist (or `task_update_simple.zig` if separate)

Frontend (5 files):
- `src/apps/desktop/src/stores/workspaces.ts` — `Task.tags?: string[]` + `createTask` accepts `tags` + `updateTaskSimple` accepts `tags`
- `src/apps/desktop/src/api/index.ts` — `createTask` and `updateTaskSimple` accept `tags?: string[]`, encode to JSON
- `src/apps/desktop/src/components/kanban/KanbanTagsInput.vue` — NEW
- `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` — add tags section + parse incoming `task.tags` on edit
- `src/apps/desktop/src/components/workspace/WorkspaceItemTaskCard.vue` — render tags row

Tests (4 files):
- `src/migrations/migration_067_test.zig` — NEW
- `src/ai_workflow/tui/http_handlers/task_create_tags_test.zig` — NEW
- `src/ai_workflow/tui/http_handlers/task_update_tags_test.zig` — NEW
- `src/apps/desktop/src/__tests__/KanbanTagsInput.spec.ts` — NEW
- `src/apps/desktop/src/__tests__/WorkspaceItemTaskCard.tags.spec.ts` — NEW
- `src/apps/desktop/src/__tests__/workspacesStore.tags.spec.ts` — NEW

Total: ~15 files, 4 NEW backend, 5 NEW frontend, 3 existing EDIT backend, 3 existing EDIT frontend.

## 10. References

- Project memory: `nalar-data-and-routines.md` §"Migration #009-#052 fresh-DB cascade is fragile" (the `addColumnIfMissing` + transactional pattern)
- Project memory: `migration-registration-trap.md` (must update `allMigrations` slice + add a regression test)
- Project memory: `sqlite-backend-empty-slice-binds-as-null` (why we use SQL `''` literal for empty strings)
- Project memory: `kanban-create-shape-mismatch-untitled-project.md` (the wire-shape docstring + regression test discipline)
- Existing migration patterns: Migration 062 (description) — the closest analogue for column semantics + persistence pattern
- Existing field patterns: `last_human_touched_at` (Migration 065) — the most recent column-add migration, useful template
- Existing dialog patterns: `KanbanTaskDetailDialog.vue` — the host for the new tags input
- Existing card patterns: `WorkspaceItemTaskCard.vue:492` — the `v-if="task.description"` pattern we mirror for tags
