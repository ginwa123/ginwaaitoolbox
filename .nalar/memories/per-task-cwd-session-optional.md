# Per-task cwd_session (Migration 070, kanban-cwd-session-optional plan, 2026-08-06)

## Mental model

Each kanban **task** can carry its own `cwd_session` (different repos per task). The kanban's `path` is now a **fallback** (not a requirement). A cwd-less kanban no longer forces ALL tasks to be cwd-less.

## Resolution priority chain (in `session_create.zig::useCase`)

```
1. RequestSession.cwd_session     ← explicit per-call override (frontend sends)
2. workspace_item_tasks.cwd       ← NEW column, per-task (Migration 070)
3. workspace_items.path           ← kanban-level cwd (pre-existing)
4. createSandbox($TMPDIR/session_<id>/)  ← per-session sandbox (pre-existing)
```

The frontend computes the same chain at `KanbanView.handleCreateTaskSave` (3-level: `payload.cwdSession || props.item.path || ''`). Both layers doing the same chain is intentional defense-in-depth — Vue path is the primary contract; the backend chain protects curl / LLM tool callers.

## Naming choice (per user feedback)

- **Column**: `cwd` (NOT `cwd_session`) — avoids name-clash with the legacy HTTP `cwd_session` field on `RequestSession`.
- **Wire field**: matches the column name (`cwd` on `TaskCreateRequest` / `TaskUpdateRequest` / `WorkspaceItemTaskResponse`).
- **Frontend emit payload**: `cwdSession` (slightly different from the wire field to disambiguate "the create-time picker value" from "the persisted column").

## Frontend UX

- **AddKanbanDialog**: project_root picker is **OPTIONAL**. Hint: `(optional — used as cwd for chat sessions)`. Placeholder when empty: `Skip (no project root)`. Submit enables on `!name.trim()` only.
- **KanbanTaskDetailDialog** (create mode): **NEW** folder picker pre-populated from the parent kanban's `cwd` prop. Picker writes `cwdSession` to the emit payload. Edit mode shows a read-only strip (cwd change is out of scope for v1).

## Backend shape

```zig
// Migration 070 (idempotent — pre-existing rows backfill to '')
ALTER TABLE workspace_item_tasks ADD COLUMN cwd TEXT NOT NULL DEFAULT '';

// createWorkspaceItemTask accepts cwd: ?[]const u8 as 10th arg.
// Same dynamic SQL builder as description / tags / image_urls:
//   - null → omit column, DEFAULT '' applies
//   - ""   → SQL '' literal (NOT NULL constraint — can't bind empty slice)
//   - non-empty → bind via ?

// task_create.zig::validated_cwd: absolute path, ≤ 4 KiB, no control chars.
//   Errors: CwdTooLong, CwdNotAbsolute, CwdContainsControlChar → 400.

// session_create.zig::useCase: 3-level fallback.
// resolveCwdFromTaskOrItem returns the first non-empty of:
//   workspace_item_tasks.cwd JOIN workspace_items.path.
// Returns '' when no matching task/row — caller falls back to createSandbox.
```

## Pitfalls (record for future agents)

- **`cwd` (NOT `cwd_session`)** for the new column — name-clash with the legacy HTTP `cwd_session` field on `RequestSession`.
- **`cwd` is NOT in `imageUrls`'s `||`-joined string convention** — `cwd` is a single absolute path; no parsing/splitting at fetch sites.
- **`cwd` is persisted at creation time** via the createTask POST body — no second `updateTaskDetails` patch needed (unlike `imageUrls` which uses an update-then-imageUrls pattern).
- **Frontend 3-level fallback in `runAgentOnNewTask`** — same chain as backend. Both layers doing the chain is intentional defense-in-depth.
- **Test setup `setupDb` must include `task_type TEXT NOT NULL DEFAULT 'standard'`** — `createWorkspaceItemTask` always INSERTs task_type; missing column fails with `no such column: task_type`.
- **Returned `cwd` slice from `resolveCwdFromTaskOrItem` is borrowed from the per-request arena** — same lifetime pattern as `tags` / `image_urls` / `git_worktree_cwd`. Caller MUST NOT free it.
- **Empty-string cwd uses SQL `''` literal branch** — same bind-safety caveat as description / tags / image_urls. Don't `defer allocator.free("")` (it's a no-op but documents intent).

## Test counts

- Backend: `migration_070_test.zig` — 5 column tests + 3 `createWorkspaceItemTask` round-trip tests.
- Frontend: 3 updated emit tests (`emits create`, `emits create with unattended`, `emits create-and-run with mode create_and_run`) to include `cwdSession: ''` in the expected payload.
- AddKanbanDialog: 3 new tests for the optional-path behavior (button enabled without folder, "Skip (no project root)" placeholder, "(optional)" hint shown).

## Plan / branch

- Plan: `docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md`
- Branch: `worktree/kanban-cwd-session-optional`
- User feedback drove the design choice: pre-write plan → user-approved open questions → implement with git worktree.

## Related

- AGENTS.md changelog entry: `### 2026-08-06: Per-task cwd_session + optional kanban cwd (Migration 070)`
- Plan doc: `docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md`
- Cross-references: Migration 067 (per-task tags), Migration 069 (per-task image_urls) — both follow the same per-task column + dynamic SQL builder + `||`-for-image_urls convention. Migration 070 follows the same pattern but uses a single absolute path (no `||` separator).