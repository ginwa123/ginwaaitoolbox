# Kanban task tags — free-form string list (Migration 067)

## Wire shape is JSON-encoded string, not array

Lowest-effort interop between SQLite TEXT columns and the
TypeScript `string[]` frontend interface: keep the column as
TEXT, store a JSON-encoded array string (e.g. `'["bug","urgent"]'`),
and decode on the frontend.

The api functions do the JSON encoding:

```ts
if (params.tags && params.tags.length > 0) {
  body.tags = JSON.stringify(params.tags)  // wire: string
}
```

The frontend normalizeTaskTags helper decodes:

```ts
function normalizeTaskTags(task: Task): Task {
  if (typeof task.tags === 'string') {
    try {
      const parsed = JSON.parse(task.tags) as unknown
      task.tags = Array.isArray(parsed) ? (parsed as string[]) : []
    } catch {
      task.tags = []
    }
  }
  return task
}
```

Apply normalizeTaskTags at every fetch site (4 spots in
workspaces.ts) so the rest of the codebase can treat tags as a
plain array.

## Why JSON-string-on-the-wire and not JSON-array

The wire format is intentionally a JSON-encoding string, not a
JSON array. Three reasons:

1. **Single source of truth for JSON shape.** The DB column is
   TEXT (a string). The wire type is `?[]const u8` (a string).
   The handshake is one less transformation: the backend reads
   the JSON string, parses it, validates, re-encodes (dedup,
   preserve casing), and writes to the column. The frontend
   parses the JSON string into `string[]` once per fetch.

2. **Defensive against malformed JSON.** The frontend's
   `normalizeTaskTags` treats `tags` as defensive — if the
   parse fails, it falls back to `[]`. The chip render path
   never crashes on malformed input.

3. **Forward-compatible with a managed-tag migration.** The
   JSON-encoded array is the natural source of truth for a
   future migration that reads `json_each(t.tags)` and creates
   proper tag rows + a join table.

## Endpoints that needed wire-shape updates

Two list endpoints bypass `WorkspaceItemTaskInfo` and project
`WorkspaceItemTaskResponse` directly. They need their own
SELECT + column assignment:

- `tasks_list.zig` — uses `WorkspaceItemTaskInfo` (tags already
  at index 21); just append `.tags = task.tags` to the
  constructor.
- `workspaces_list.zig` — uses its own SELECT. Add `t.tags` at
  index 9 in the column list and `.tags = row.values[9]` in the
  constructor. Otherwise GET returns `tags: ""` even though POST
  persisted correctly.

## Validation is shared between two handlers

`tags_validation.zig::validateAndNormalizeTags` is called by
both `task_create.zig` and `task_update.zig`. The empty-string
case MUST use a SQL `''` literal (not a `?` bind) because
`SqliteBackend.exec` binds empty `[]const u8` as SQL NULL —
which would fail the NOT NULL DEFAULT '' constraint. Same
root cause as the `description` column in Migration 062.

## Permissive tag format

- Chars: `[a-zA-Z0-9_-]` (GitHub-label style).
- Length cap: 50 chars per tag.
- No cap on the number of tags per task.
- Case-insensitive dedupe: `["Bug","bug"]` → `["Bug"]`.
- Empty string `""` → 400 (after trim/dedupe, if all tags were
  duplicates, the result is also `""` and the row is updated to
  the no-tags sentinel).

## Branch: `worktree/kanban-task-tags`

The feature is complete and on a feature branch. To merge:

```bash
# Test once more, then merge
cd /home/ginwa/.../kanban-task-tags
timeout 180 zig build test --summary all
cd src/apps/desktop && timeout 60 bunx vitest run && timeout 60 node node_modules/vue-tsc/bin/vue-tsc.js --build
cd /home/ginwa/.../kanban-task-tags && git checkout main && git merge --no-ff worktree/kanban-task-tags
```
