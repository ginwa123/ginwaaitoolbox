# TASK 1 BRIEF — Migration 101 + `secrets_store.zig`

WORK DIRECTLY IN THIS EXISTING WORKTREE — do NOT call `set_git_worktree`, do NOT create a
new worktree, do NOT touch `/home/ginwa/ginwaaitoolbox`:

    /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930

`cd` there for every command. All paths below are relative to that directory.

Repo: **nalar**, Zig 0.16 backend. We are implementing a workspace-scoped "Secrets" feature.
Plan: `docs/superpowers/plans/2026-10-02-workspace-secrets.md` (rev 2) — read the
`## Wire Contract` and `### Task 1` sections before you start.

**Your task is Task 1 only.** Another agent is concurrently writing
`secrets_substitution.zig` (Task 2) in the same tree — do NOT create it, do NOT create
migrations beyond yours, do NOT touch `handle_tool.zig`, `workflow.zig`, tools, HTTP
handlers, or any frontend file.

---

## 1. Migration

`src/migrations/migration.zig` — add `Migration101CreateWorkspaceSecrets`, mirroring the
shape of `Migration098CreateDocuments` (struct at ~:3731) and `Migration100AddWorkspaceMembers`
(struct at ~:14779). Migration 100 is taken; **101 was re-verified free** in the merged tree.

```zig
pub const Migration101CreateWorkspaceSecrets = struct {
    pub const version: u32 = 101;
    pub const name = "create_workspace_secrets";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_secrets (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    name TEXT NOT NULL,
            \\    value TEXT NOT NULL,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        // + the two indexes below, ONE db.exec EACH
    }
};
```

**One SQL statement per `db.exec`** — `sqlite3_prepare_v2` compiles only the first. This is
documented at `migration.zig:3729-3730`. So the table and each index are separate `db.exec` calls.

Indexes (one `db.exec` each):

```
CREATE UNIQUE INDEX IF NOT EXISTS uq_workspace_secrets_name
  ON workspace_secrets(workspace_id, name)
```

```
CREATE INDEX IF NOT EXISTS idx_workspace_secrets_workspace
  ON workspace_secrets(workspace_id, name)
```

Naming convention: `idx_<table>_<cols>` plain, `uq_<table>_<cols>` UNIQUE (compare
`uq_skill_eval_facts` at `migration.zig:5535`).

Then add **one** entry to the `allMigrations` array. It is declared at `migration.zig:1790`
and the array literal now closes at `migration.zig:2052`; insert the new entry immediately
before that closing `};`, after the Migration 100 entry at `:2051`.

Copy the house style of the neighbouring entries INCLUDING their explanatory comment blocks.
A comment stating *why* each index exists is expected here, not optional. Note that
`FOREIGN KEY ... ON DELETE CASCADE` is documentation-only in this repo (`PRAGMA foreign_keys`
is off — see `migration.zig:3718-3721`), so say so.

**NO `user_id` COLUMN. NO `key_hint` COLUMN.** Access control is workspace membership via
`workspace_members` (PR #781), enforced upstream by `auth_common.canSeeWorkspace`. The value is
**plaintext** — reviewer decision, no master key, no encryption.

---

## 2. `src/agentic_loop/secrets_store.zig` — new module

**READ `src/agentic_loop/documents_store.zig` FIRST and mirror its structure exactly** —
module docstring style, row/args structs, validation guards, ownership comments, free
functions, inline tests at the bottom. That file is the template.

Public surface — every function takes `workspace_id` as a positional argument that appears in
the `WHERE` clause. Never a value the caller can choose to omit.

| Symbol | Notes |
|---|---|
| `SecretRow` | `{ id, workspace_id, name, created_at, updated_at }` — deliberately **no `value`** |
| `SecretValueRow` | `{ name, value }` — used ONLY by `loadSecretValues` |
| `listSecrets(allocator, db, workspace_id)` | ordered by `name` |
| `getSecret(allocator, db, workspace_id, secret_id)` | `NotFound` on foreign workspace |
| `createSecret(allocator, db, args)` | returns the created row |
| `updateSecret(allocator, db, args)` | updates `value` only; `name` is immutable |
| `deleteSecret(allocator, db, workspace_id, secret_id)` | |
| `listSecretNames(allocator, db, workspace_id)` | SELECT `name` ONLY — the only function the agent path may call |
| `loadSecretValues(allocator, db, workspace_id, names)` | returns `{name, value}` pairs for substitution; the ONLY function that ever returns a value |
| `freeSecretRow`, `freeSecretRows` | mirror documents_store |

Give `loadSecretValues` a comment stating it is the only value-returning function and that its
result must never be logged or persisted.

Error set (HTTP handlers map these later):

```
WorkspaceIdRequired, IdsRequired, NameRequired, ValueRequired, InvalidName,
NameTaken, NotFound, QueryFailed, InsertFailed, UpdateFailed, DeleteFailed, OutOfMemory
```

The module docstring must state the ONE rule (`workspace_id` is a parameter that appears in the
`WHERE` clause), and one line must say that access is workspace membership via `workspace_members`
so nobody later "fixes" it by adding an owner column.

---

## 3. HARD CONSTRAINTS — violating any is a task failure

- `SqliteBackend.exec` binds a zero-length slice as **SQL NULL**. Every `NOT NULL` TEXT column
  you write MUST use `COALESCE(NULLIF(?, ''), '')`. Search `documents_store.zig` for
  `COALESCE(NULLIF` and copy the exact idiom. A `value: ""` must be rejected as `ValueRequired`
  **before** it reaches the DB, not surface as a constraint error.
- Validate `name` against `[A-Za-z0-9_-]{1,64}` **in Zig before the INSERT**, returning
  `InvalidName`. Do not rely on SQL to reject it.
- Duplicate `(workspace_id, name)` → `NameTaken`. Either check first or map the unique-constraint
  error; it must be a clean error, not a 500 path.
- Cross-workspace access returns `NotFound`, never another workspace's row.
- **No `user_id` column.**
- **No `// NEW (plan: ...)` comments anywhere.** Explain WHY in one plain sentence, or not at
  all. The repo forbids those tags in source.

---

## 4. Tests

This repo has **no `*_test.zig` files anywhere** — every Zig test is an inline
`test "..."` block inside the implementation file. Tests live inline at the bottom of
`migration.zig` and of your new module.

**Write the failing test first, then implement.** Copy the in-memory fixture from the existing
tests in `migration.zig` (`setupDb`, around `:3654`).

In `migration.zig`, add:
- after `Migration101CreateWorkspaceSecrets.up`, `pragma_table_info('workspace_secrets')`
  contains exactly the 6 expected columns
- the unique index rejects a duplicate name in the SAME workspace but ALLOWS the same name in
  a DIFFERENT workspace
- the `Migration101 is registered in allMigrations` guard test (copy the shape of the existing
  Migration099 / Migration100 guard tests in that file)

In `secrets_store.zig`, add inline tests over in-memory SQLite for each function, including:
- create with empty name → `NameRequired`
- create with empty value → `ValueRequired`
- invalid name → `InvalidName`
- duplicate name in same workspace → `NameTaken`
- cross-workspace read → `NotFound`
- `listSecretNames` returns names, and **the SQL string it builds contains no `value`** — assert
  on the SQL string itself so a future edit that adds the column fails the test
- delete then list → empty

---

## 5. GATE

```bash
cd /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930
zig build test
```

Must be green before you commit. A background warm build may be running; if you hit a cache
lock, wait and retry.

Another agent is concurrently adding `src/agentic_loop/secrets_substitution.zig`. If the build
fails in a file you did not create, check whether the errors mention `secrets_substitution.zig`:
if they do, it is their in-progress work — retry after a pause, and if still broken, report it
rather than editing their file.

If `zig build test` reveals **pre-existing** failures unrelated to this work, say so explicitly
in your report and do not attempt to fix them.

Commit when green:

```
feat(secrets): migration 101 + workspace-scoped secret store
```

## REPORT BACK

Files changed, exact commit sha, `zig build test` result, and anything you deviated from in
this brief and why.