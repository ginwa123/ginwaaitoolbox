# Users + RBAC + user_companies — Foundation Design

> **For agentic workers:** This is a design spec. After the user approves, the next step is to invoke the `superpowers:writing-plans` skill to create a bite-sized implementation plan.

**Goal:** Lay down the schema foundation for a multi-user / multi-tenant pabrik — `users` table, `user_companies` table, `user_company_members` join, and `user_id` FKs on `workspaces` + `sessions`. Backfill all legacy rows to a default `user_system` user. **No auth flow, no permission checks, no frontend changes** — every existing endpoint continues to work. This is sub-project 1 of 4; sub-projects 2 (auth), 3 (RBAC enforcement), and 4 (frontend UI) get their own follow-up specs.

**Architecture:**
- **Schema-first.** One new migration (`Migration077AddUsersAndRbacSchema`) creates the three tables, adds the two `user_id` columns, creates the indexes, inserts the default `user_system` user, and backfills legacy rows. Wrapped in a single `BEGIN..COMMIT` for atomicity.
- **Backfill is mechanical.** `user_id IS NULL` rows become `user_id = 'user_system'`. The system user has `is_active = 0` and a sentinel `password_hash = '!disabled'` so it can never log in (sub-project 2's auth layer will reject both).
- **No foreign key constraints** on `user_id` columns (workspaces, sessions, user_companies.created_by, user_company_members.invited_by). SQLite doesn't support `ALTER TABLE … ADD CONSTRAINT FK`, and the project precedent (Migration 066 `design_pages.workspace_item_task_id`) is "no FK + application-layer enforcement". The join table does use a `PRIMARY KEY (user_id, user_company_id)` because that's a composite PK, not a constraint.
- **Idempotent.** `CREATE TABLE IF NOT EXISTS` + `addColumnIfMissing` for the two ALTERs + `INSERT OR IGNORE` for the default user. Re-run = no-op.

**Tech Stack:** Zig 0.16, existing `migration.MigrationManager` + `addColumnIfMissing` / `dropColumnIfExists` / `renameColumnIfExists` helpers in `src/migrations/migration.zig`. SQLite 3.53.3 (bundled). No new dependencies.

## Global Constraints

- **Sub-project scope is schema ONLY.** No auth endpoints, no password hashing, no session tokens, no permission middleware, no frontend changes. These are explicitly out of scope and live in sub-projects 2–4.
- **Compound UNIQUE / PK / CHECK constraints** are fine; they're part of the `CREATE TABLE` statement. FK constraints are NOT (see "FK decision" below).
- **Naming convention** for `users.id` is `user_<unix_nanoseconds>` (matches `task_<nanos>`, `ws_<nanos>`, `sess_<nanos>` project-wide convention). The reserved id `user_system` is the backfill target.
- **Email normalization**: stored lowercased + trimmed. Uniqueness enforced by `UNIQUE` constraint on the column. Format `email TEXT NOT NULL UNIQUE` — application layer (sub-project 2) will lowercase before insert.
- **`password_hash` is `NOT NULL`** because the auth model is local-password-only for v1 (the user picked option 1 in the brainstorm). The `user_system` row gets a sentinel `!disabled` hash that cannot match any real argon2id output.
- **Idempotency** is mandatory. The migration must be safe on re-run via `runMigrations` (the `schema_migrations` table already gates this) and also safe to call `Migration077AddUsersAndRbacSchema.up(...)` directly a second time (so test #8 verifies the `addColumnIfMissing` + `INSERT OR IGNORE` patterns).
- **Per project rule:** all migration code lands in `src/migrations/migration.zig` (the migration struct + register in `allMigrations`) and `src/migrations/migration_077_test.zig` (the regression tests). Use `MigrationManager.registerAllMigrations + runMigrations` for test setup, NEVER hand-rolled `CREATE TABLE` baselines (per project memory `project-test-use-migrations-module`).

---

## 1. Why now — the problem

The codebase has no `users` concept. Every `workspace`, `session`, `kanban_task`, `design_page`, and `llm_history` row is implicitly "the one human using this machine". Adding `users` + `user_companies` + `user_id` FKs is the necessary foundation for:

- **Future multi-user support** (multiple humans on the same DB, each with their own workspaces + sessions).
- **Future multi-tenant grouping** (users can belong to one or more `user_companies` — orgs, teams, deployments).
- **Audit trails** ("who created this workspace", "who last logged in", "who owns this kanban card").
- **Forward-compatible RBAC** (role on `users` + role on `user_company_members` + future per-workspace role).

The user's request was literal: "create a table users with rbac, put the user_id on table workspaces and sessions". This sub-project delivers exactly that — nothing more, nothing less.

## 2. Current state — what exists today

**Schema baseline (post Migration 076):**

```sql
-- From Migration 024 + 027 + 030 + 043:
CREATE TABLE workspaces (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    created_at DATETIME, updated_at DATETIME,
    position INTEGER NOT NULL DEFAULT 0
);

-- From Migration 017 + 022 + 025 + 029 + 040 + 046 + 063:
CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    workspace_id TEXT,
    cwd TEXT,
    created_at DATETIME, updated_at DATETIME,
    selected_profile_model TEXT,
    git_worktree_cwd TEXT,
    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
    last_finish_reason TEXT
);
```

Neither table has a `user_id` column. No `users` table. No `user_companies` table. No `user_company_members` table.

**Existing migration patterns the new one follows:**

- `addColumnIfMissing(db, alloc, table, column, "name TYPE …")` — when adding a column to a table that may already declare it (mirrors Migrations 020, 028, 052, 065, 066, 067, 074). For our two `user_id` columns, the workspaces table's canonical CREATE TABLE (Migration 024) and sessions table's canonical CREATE TABLE (Migration 017) do NOT declare `user_id`, so plain `ALTER TABLE … ADD COLUMN` would also work — but using `addColumnIfMissing` is consistent with the project convention and zero-cost.
- `CREATE TABLE IF NOT EXISTS` for new tables (the canonical idempotent pattern).
- `INSERT OR IGNORE` for the default user (idempotent re-insert).
- `BEGIN..COMMIT` wrap around multi-step destructive changes (used by Migration 072's kanban table extract, 075's rename) — our migration is not destructive but is multi-step, so we wrap for atomicity.
- `ANALYZE` at the end to refresh query-planner stats (mirrors Migrations 041/042/043/051/052/070/072).

**Existing precedent for "no FK constraint"** (Migration 066 docstring):

> "SQLite does NOT support `ALTER TABLE … ADD CONSTRAINT FK`. The canonical alternatives — triggers or recreate-table — both add complexity that's out of scope for v1. The UNIQUE index + application-level validation is the second line of defense."

We follow the same precedent for `workspaces.user_id`, `sessions.user_id`, `user_companies.created_by`, `user_company_members.invited_by`. The application's `?` joins on these columns at read time, and the soft check is the `user_id NOT NULL` constraint after backfill.

## 3. Design — schema, backfill, contract

### 3.1 The `users` table

```sql
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,                         -- user_<unix_nanoseconds>, or 'user_system'
    email TEXT NOT NULL UNIQUE,                  -- lowercased + trimmed
    name TEXT NOT NULL DEFAULT '',                -- display name (can be empty for system)
    password_hash TEXT NOT NULL,                 -- argon2id encoded; sentinel '!disabled' for system
    role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user', 'bot')),
    is_active INTEGER NOT NULL DEFAULT 1,        -- 0 = cannot log in; system user is 0
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_login_at DATETIME DEFAULT NULL
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_active ON users(is_active);
```

**Role vocabulary**: `admin` / `user` / `bot`. The CHECK constraint is enforced at the DB layer (the only one in the schema — cheap upgrade path for RBAC sub-project 3). `bot` is reserved for future service accounts (cron workers, automated importers).

**`is_active = 0` for `user_system`**: even if a future auth layer has a bug that bypasses the password check, the `is_active` flag is the final gate. The system user can never log in.

**`last_login_at` is nullable**: NULL = "never logged in" (the canonical "absent" sentinel, matching `last_finish_reason` from Migration 063). Sub-project 2 will `UPDATE users SET last_login_at = CURRENT_TIMESTAMP WHERE id = ?` on every successful login.

### 3.2 The `user_companies` table

```sql
CREATE TABLE IF NOT EXISTS user_companies (
    id TEXT PRIMARY KEY,                         -- user_company_<unix_nanoseconds>
    name TEXT NOT NULL,                          -- human-readable
    slug TEXT NOT NULL UNIQUE,                   -- URL-safe lowercase, e.g. 'acme-corp'
    description TEXT NOT NULL DEFAULT '',        -- free-form note
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    created_by TEXT                              -- FK to users.id (no constraint, see below)
);

CREATE INDEX IF NOT EXISTS idx_user_companies_slug ON user_companies(slug);
CREATE INDEX IF NOT EXISTS idx_user_companies_active ON user_companies(is_active);
```

**`slug` is the URL-safe identifier** (matches the project convention used by `workspace_items.path` and `kanban_columns.name`). Sub-project 4 (frontend) will use `slug` for human-readable URLs; sub-project 3 (RBAC) will use it for the active-company context.

**`created_by` has no FK constraint.** Same precedent as `workspaces.user_id` above. Application-layer enforcement.

### 3.3 The `user_company_members` join table

```sql
CREATE TABLE IF NOT EXISTS user_company_members (
    user_id TEXT NOT NULL,                       -- FK to users.id (no constraint)
    user_company_id TEXT NOT NULL,               -- FK to user_companies.id (no constraint)
    role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member', 'guest')),
    joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    invited_by TEXT,                             -- FK to users.id (nullable, no constraint)
    PRIMARY KEY (user_id, user_company_id)        -- composite PK enforces "no duplicate membership"
);

CREATE INDEX IF NOT EXISTS idx_user_company_members_user ON user_company_members(user_id);
CREATE INDEX IF NOT EXISTS idx_user_company_members_company ON user_company_members(user_company_id);
```

**Role vocabulary within a company**: `owner` / `admin` / `member` / `guest`. Mirrors the 4-tier model common in SaaS apps (GitHub: owner / maintainer / collaborator; Slack: owner / admin / member / guest).

- `owner` — creator, cannot be removed, exactly one per company (UNIQUE partial index can enforce this in a future migration if needed).
- `admin` — can invite/remove members, create/delete workspaces within the company.
- `member` — can create workspaces, participate in memberships.
- `guest` — read-only access to company workspaces.

**The composite PK `(user_id, user_company_id)`** is the second line of defense against duplicate membership. The `EXISTS` clause in any RBAC query combines the PK with an `idx_user_company_members_user` lookup for O(log N) resolution.

**No `ON DELETE CASCADE`** because: (a) no FK constraint, (b) the project convention is that user deletion is a soft-delete (set `is_active = 0`) — hard-deleting a user should require a separate cleanup pass on `user_company_members`. Sub-project 3 will define the on-delete behavior.

### 3.4 The `workspaces.user_id` column (additive)

```sql
ALTER TABLE workspaces ADD COLUMN user_id TEXT;   -- FK to users.id (no constraint)
CREATE INDEX IF NOT EXISTS idx_workspaces_user_id ON workspaces(user_id);
```

Nullable at the DB layer (the `ALTER TABLE` doesn't have `NOT NULL`). Backfilled to `'user_system'` for every existing row. New rows inserted by sub-project 2's auth-aware session_create will thread `user_id` from the auth token.

**Schema state after migration:**

```
workspaces: ..., user_id TEXT (no FK, no NOT NULL, all rows = 'user_system')
```

### 3.5 The `sessions.user_id` column (additive)

```sql
ALTER TABLE sessions ADD COLUMN user_id TEXT;   -- FK to users.id (no constraint)
CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id);
```

Same shape as `workspaces.user_id`. Backfilled to `'user_system'` for every existing row.

### 3.6 The default `user_system` user

```sql
INSERT OR IGNORE INTO users (id, email, name, password_hash, role, is_active)
    VALUES ('user_system', 'system@local', 'System', '!disabled', 'admin', 0);
```

- `id = 'user_system'` — the reserved, well-known id that legacy rows backfill to.
- `email = 'system@local'` — `.local` is the RFC 6762 reserved TLD for mDNS / local-only names, so the email can never collide with a real DNS-routable address. Sub-project 2's signup endpoint will reject `system@local` (or any `*.local` email) to prevent collision.
- `password_hash = '!disabled'` — sentinel string. Sub-project 2's password verification will reject any input that doesn't start with `$argon2id$` (the standard argon2id encoded hash prefix). The `!disabled` value is a one-character prefix that can never match.
- `role = 'admin'` — the system user has admin role so any future RBAC check that resolves to it (e.g. a legacy workspace whose owner was the system user) gets the widest permission.
- `is_active = 0` — the system user can never log in. Sub-project 2's auth middleware will reject any `user_id` with `is_active = 0` even if a token somehow resolved to it.

The `INSERT OR IGNORE` makes the row creation idempotent. If the user `user_system` already exists (e.g. a re-run after partial success), the INSERT is a no-op.

### 3.7 Backfill

```sql
UPDATE workspaces SET user_id = 'user_system' WHERE user_id IS NULL;
UPDATE sessions SET user_id = 'user_system' WHERE user_id IS NULL;
```

`UPDATE … WHERE user_id IS NULL` is the canonical idempotent backfill pattern. On a fresh DB (no legacy rows), the UPDATE is a no-op. On a legacy DB, every NULL becomes `user_system`. After the UPDATE, every row has a non-NULL `user_id`, so the application's "soft check" that `user_id IS NOT NULL` is satisfied for all legacy rows.

**Why `user_system` and not everyone = NULL?** Two reasons:

1. The user explicitly chose Option A (personal-first). Under A, every workspace has a concrete owner id. NULL would mean "no owner" which is semantically different — every legacy row would need future sub-project 2 to backfill to a real user.
2. Sub-project 3's RBAC queries will use `WHERE workspaces.user_id = current_user_id`. If legacy rows had `user_id IS NULL`, the RBAC query would have to special-case the NULL branch — extra code, easy to forget. With `user_system` as the universal owner, the query is uniform.

### 3.8 FK decision (explicit)

**Decision: NO foreign key constraints** on `workspaces.user_id`, `sessions.user_id`, `user_companies.created_by`, `user_company_members.invited_by`, `user_company_members.user_id`, `user_company_members.user_company_id`.

SQLite does not support `ALTER TABLE … ADD CONSTRAINT FK`. The two canonical alternatives are:

1. **Triggers** (`BEFORE INSERT/UPDATE/DELETE` + `ON DELETE CASCADE`).
2. **Recreate-table pattern** (rename → recreate → copy → drop).

Both add complexity that's out of scope for v1. The application layer is the second line of defense (referential integrity is enforced by the JOIN clauses at read time; the `user_company_members` composite PK enforces "no duplicate membership" at the SQL layer).

**Project precedent** (Migration 066 docstring, `design_pages.workspace_item_task_id`): "FK constraint intentionally omitted (decision). The UNIQUE index + application-level validation in `design_model.setDesignPage` is the second line of defense; revisit if migration friction appears."

**Sub-project 2 will HARDEN the FK story** by adding a `user_company_members` BEFORE INSERT/UPDATE trigger that validates `user_id` and `user_company_id` exist. This is a follow-up — mentioned here for awareness, not implemented in this sub-project.

### 3.9 Wire-format preservation

**No HTTP / JSON / model changes** in this sub-project. The `user_id` column is added to the SQL schema but is NOT exposed in any HTTP response body or accepted as an HTTP request parameter. Sub-project 2 will thread it into the auth-middleware resolution path and expose it to the wire format once the auth layer is in place.

The migration's additive ALTER TABLE inserts a column into the existing row format. Any existing SELECT that does `SELECT * FROM workspaces` will now include `user_id` in the projection — but the application code uses explicit column lists (`SELECT id, name, created_at, ... FROM workspaces`), so the new column is invisible to the wire.

## 4. File structure

```
src/migrations/
    migration.zig                       — add Migration077AddUsersAndRbacSchema struct;
                                          add to `allMigrations` slice (after Migration 076).
    migration_077_test.zig              — NEW: 8 regression tests.

(Existing files untouched. No changes to http_handlers, models, frontend, or any other module.)
```

## 5. Implementation — `Migration077AddUsersAndRbacSchema`

```zig
pub const Migration077AddUsersAndRbacSchema = struct {
    pub const version: u32 = 77;
    pub const name = "add_users_and_rbac_schema";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // BEGIN..COMMIT for atomicity. A crash mid-migration would
        // otherwise leave a half-built schema (e.g. users exists but
        // user_companies doesn't), which the next migration would
        // silently compound.
        try db.exec(allocator, "BEGIN", &.{});
        errdefer {
            db.exec(allocator, "ROLLBACK", &.{}) catch {};
        }

        // 1. users
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS users (
            \\    id TEXT PRIMARY KEY,
            \\    email TEXT NOT NULL UNIQUE,
            \\    name TEXT NOT NULL DEFAULT '',
            \\    password_hash TEXT NOT NULL,
            \\    role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user', 'bot')),
            \\    is_active INTEGER NOT NULL DEFAULT 1,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    last_login_at DATETIME DEFAULT NULL
            \\)
        , &.{});

        // 2. user_companies
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS user_companies (
            \\    id TEXT PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    slug TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    is_active INTEGER NOT NULL DEFAULT 1,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    created_by TEXT
            \\)
        , &.{});

        // 3. user_company_members
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS user_company_members (
            \\    user_id TEXT NOT NULL,
            \\    user_company_id TEXT NOT NULL,
            \\    role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member', 'guest')),
            \\    joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    invited_by TEXT,
            \\    PRIMARY KEY (user_id, user_company_id)
            \\)
        , &.{});

        // 4. workspaces.user_id
        try addColumnIfMissing(
            db, allocator,
            "workspaces", "user_id",
            "user_id TEXT",
        );

        // 5. sessions.user_id
        try addColumnIfMissing(
            db, allocator,
            "sessions", "user_id",
            "user_id TEXT",
        );

        // 6. Indexes
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)", &.{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_users_active ON users(is_active)", &.{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_companies_slug ON user_companies(slug)", &.{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_companies_active ON user_companies(is_active)", &.{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_company_members_user ON user_company_members(user_id)", &.{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_company_members_company ON user_company_members(user_company_id)", &.{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspaces_user_id ON workspaces(user_id)", &.{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id)", &.{});

        // 7. Default user — INSERT OR IGNORE makes it idempotent.
        try db.exec(allocator,
            "INSERT OR IGNORE INTO users (id, email, name, password_hash, role, is_active) " ++
                "VALUES ('user_system', 'system@local', 'System', '!disabled', 'admin', 0)",
            &.{});

        // 8. Backfill legacy rows. Idempotent — re-running on a DB
        //    where every row already has user_id set is a no-op.
        try db.exec(allocator,
            "UPDATE workspaces SET user_id = 'user_system' WHERE user_id IS NULL", &.{});
        try db.exec(allocator,
            "UPDATE sessions SET user_id = 'user_system' WHERE user_id IS NULL", &.{});

        try db.exec(allocator, "COMMIT", &[_][]const u8{});

        // 9. ANALYZE so the query planner sees the new indexes on
        //    pre-existing databases (mirrors Migration 041/042/043/051/070/072 pattern).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
```

**Add to `migration.zig::allMigrations` slice** (after the Migration 076 entry):

```zig
.{ .version = Migration077AddUsersAndRbacSchema.version,
   .name = Migration077AddUsersAndRbacSchema.name,
   .up = Migration077AddUsersAndRbacSchema.up },
```

## 6. Tests — `migration_077_test.zig`

8 regression tests, following the canonical pattern from `migration_074_test.zig` + `migration_075_test.zig`:

```zig
//! Behavioural regression checks for Migration 077
//! (users + user_companies + user_company_members + workspaces.user_id +
//!  sessions.user_id + default user_system + backfill).
//! ...
//! Plan: docs/superpowers/plans/2026-08-21-users-rbac-foundation.md
//! Task: task_1787199963946_1

const std = @import("std");
const testing = std.testing;
const sqlite = @import("pabrikcore").sqlite;
const migration = @import("migration.zig");

const Migration077AddUsersAndRbacSchema = migration.Migration077AddUsersAndRbacSchema;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    // Seed pre-migration workspaces + sessions so the backfill test
    // can verify the legacy-to-user_system transformation.
    try db.exec(alloc,
        "INSERT INTO workspaces (id, name) VALUES ('ws_legacy', 'Legacy')", &.{});
    try db.exec(alloc,
        "INSERT INTO sessions (id, name, status) VALUES ('sess_legacy', 'Legacy', 'active')", &.{});

    return .{ .db = db, .threaded = threaded };
}
```

**Test list:**

1. **Migration077 creates `users` table** — `pragma_table_info` has all 9 columns (id, email, name, password_hash, role, is_active, created_at, updated_at, last_login_at) with the right types and defaults.

2. **Migration077 creates `user_companies` table** — `pragma_table_info` has all 8 columns (id, name, slug, description, is_active, created_at, updated_at, created_by) with the right types.

3. **Migration077 creates `user_company_members` join table** — `pragma_table_info` has 5 columns + `PRIMARY KEY (user_id, user_company_id)`. The composite PK is verified via `pragma_index_list` or `pragma_table_info` with `pk > 0`.

4. **Migration077 adds `user_id` to `workspaces`** — column exists, type=TEXT, nullable. Query `SELECT user_id FROM workspaces WHERE id='ws_legacy'` returns `'user_system'` (the backfill already ran as part of migration).

5. **Migration077 adds `user_id` to `sessions`** — column exists, type=TEXT, nullable. Query `SELECT user_id FROM sessions WHERE id='sess_legacy'` returns `'user_system'`.

6. **Migration077 inserts the default `user_system` user** — `SELECT id, email, role, is_active FROM users WHERE id='user_system'` returns the canonical row.

7. **Migration077 is idempotent on re-run** — run `runMigrations` twice (schema_migrations tracking makes Migration 077 a no-op), then call `Migration077AddUsersAndRbacSchema.up(...)` directly twice (verifies `addColumnIfMissing` + `INSERT OR IGNORE` are safe). Verify the schema is still correct.

8. **Migration077 is registered in `allMigrations`** — iterate the slice, find the entry with `version == 77` + matching `name`. Belt-and-suspenders: a struct alone doesn't run.

## 7. Risk assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| Migration on a large `workspaces` table is slow | Low — N is small (~10s rows in practice) | Backfill UPDATEs are O(N) on indexed column. Acceptable. |
| `user_system` email collides with a real signup | Zero — `*.local` is reserved by RFC 6762 | Sub-project 2 signup endpoint will reject `*.local` emails explicitly. |
| Hard-deleting a user later leaves orphan `user_company_members` rows | Medium — no FK cascade | Application layer (sub-project 3) is the gate. The composite PK still works — orphan rows are just stale data, not a referential inconsistency. |
| `workspaces.user_id` is nullable at the DB layer but should be NOT NULL after backfill | Low — backfill covers all legacy rows | Sub-project 2 may add `NOT NULL` constraint via table-recreate pattern if needed. |
| Tests fail to compile against the new schema | Low — `registerAllMigrations + runMigrations` guarantees the test sees the canonical schema | Per project memory `project-test-use-migrations-module`. |
| `email TEXT NOT NULL UNIQUE` rejects the system user's email if a future migration inserts a second `user_system` | Zero — `INSERT OR IGNORE` is idempotent | The `UNIQUE` constraint enforces "one row per email"; INSERT OR IGNORE skips the duplicate. |

## 8. Out of scope — follow-up sub-projects

These are deliberately NOT in this sub-project. Each gets its own spec → plan → implementation cycle.

### Sub-project 2 — Auth subsystem

- `POST /api/auth/signup` — argon2id hash, create user, return session token.
- `POST /api/auth/login` — verify hash, create session token, set `last_login_at`.
- `POST /api/auth/logout` — invalidate token.
- `GET /api/auth/me` — return current user from token.
- `auth_tokens` table (token_hash, user_id, expires_at).
- `auth_middleware` — resolves `Authorization: Bearer <token>` to `user_id`, injects into `RequestContext`.
- Thread `user_id` into every INSERT path that creates `workspaces` / `sessions` / `workspace_items` / `workspace_item_tasks`.
- Reject `user_system` + `is_active = 0` users at the auth layer.

### Sub-project 3 — RBAC enforcement

- `workspace_members` table (1:N user ↔ workspace role) — separate from `user_company_members` (which is 1:N user ↔ company).
- `POST /api/workspaces/:id/members` — invite user to workspace.
- `GET /api/workspaces/:id/members` — list members.
- `PATCH /api/workspaces/:id/members/:user_id` — change role.
- `DELETE /api/workspaces/:id/members/:user_id` — remove.
- Permission middleware per route (admin / editor / viewer).
- 403 responses on permission denial.
- Audit log of permission changes.

### Sub-project 4 — Frontend UI

- Login screen (email + password).
- Signup screen.
- User picker (top-bar dropdown).
- Workspace member management dialog.
- Role badges on workspace cards.
- Permission-aware UI (read-only mode for `viewer` role).
- Active-company switcher (uses `user_companies`).

---

## Appendix A — Conversations that led to this design

1. **Q: Single-user or multi-user?** A: Multi-user (scope C), broken into 4 sub-projects.
2. **Q: What does RBAC mean?** A: Real auth + role-based permissions, scoped to sub-projects 2 + 3.
3. **Q: Auth source?** A: Local password (argon2id), admin-reset for forgot-password.
4. **Q: Tenant model?** A: Personal-first (Option A). Users can be members of 0+ `user_companies`; workspaces belong to users, not companies.
5. **Q: FK constraints?** A: No FKs on `user_id` columns (project precedent: Migration 066). Composite PK on `user_company_members` for the second line of defense.

## Appendix B — Project memory references

- `project-test-use-migrations-module` — use `MigrationManager.registerAllMigrations + runMigrations` for test setup.
- `addColumnIfMissing-requires-name-type` — `addColumnIfMissing` builds `ALTER TABLE … ADD COLUMN {definition}`, so the definition MUST include the column name + type.
- `pabrik-fresh-db-migration-cascade` — the fresh-DB install path runs every migration in order; a fresh-DB replay-safe migration must be idempotent.
- `nats-frontend-log-dedup` (irrelevant here, but precedent for `INSERT OR IGNORE` re-insert safety).
- Project memory `sqlite-backend-empty-slice-binds-as-null` — irrelevant here, we use literals not binds.
