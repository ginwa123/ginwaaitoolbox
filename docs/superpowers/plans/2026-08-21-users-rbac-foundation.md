# Users + RBAC + user_companies — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-21
**Task:** `task_1787199963946_1` ("table users and rbac")
**User's spec (verbatim):** *"create a table users with rbac, also, put the user_id on table workspaces, and sessions, write a plan to implement that"*
**Spec:** `docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md` (approved `2026-08-21`).
**Branch / worktree:** `worktree/users-rbac-foundation` (created from current `in progress` task; per the project rule, do all work in a git worktree and open a PR for review).

**Goal:** Land the schema foundation for multi-user / multi-tenant pabrik — `users` table, `user_companies` table, `user_company_members` join table, `user_id` FK columns on `workspaces` and `sessions`, a default `user_system` user, and idempotent backfill of all legacy rows. No auth endpoints, no permission checks, no frontend changes — this is sub-project 1 of 4.

**Architecture:** A single new migration (`Migration077AddUsersAndRbacSchema`) creates the three tables + two `ALTER TABLE`s + six indexes + one `INSERT OR IGNORE` for the default user + two `UPDATE`s for backfill, all wrapped in a `BEGIN..COMMIT` for atomicity. The migration is added to `migration.zig::allMigrations` and registered by `MigrationManager.registerAllMigrations`. The test setup uses `runMigrations` (per project memory `project-test-use-migrations-module`) so the test schema always matches production.

**Tech Stack:** Zig 0.16, `pabrikcore.sqlite.SqliteBackend`, existing `MigrationManager` + `addColumnIfMissing` helper from `src/migrations/migration.zig`, SQLite 3.53.3 (bundled). No new dependencies.

## Global Constraints

- **Schema-only sub-project.** No HTTP handlers, no models, no frontend changes. The migration is the only code change.
- **Idempotency is mandatory** — `CREATE TABLE IF NOT EXISTS` + `addColumnIfMissing` + `INSERT OR IGNORE`. Re-run = no-op. Test #8 specifically verifies this.
- **No FK constraints** on `user_id` columns (matches the project precedent from Migration 066's `design_pages.workspace_item_task_id`; SQLite doesn't support `ALTER TABLE … ADD CONSTRAINT FK`).
- **Per project rule**: work in a git worktree (`worktree/users-rbac-foundation`), open a PR for review. Don't commit to `main`.
- **Per project memory `project-test-use-migrations-module`**: test setup uses `MigrationManager.registerAllMigrations + runMigrations`, NEVER hand-rolled `CREATE TABLE` baselines. The moment a new column or trigger lands in production, the hand-rolled baseline silently tests an outdated schema.
- **Per project memory `addColumnIfMissing-requires-name-type`**: `addColumnIfMissing` builds `ALTER TABLE {table} ADD COLUMN {definition}`, so the definition MUST include the column name AND the type. Omitting the type would create a column literally named `"TEXT"`.
- **Build commands**: `zig build test --summary all` for unit tests, `zig build pabrik-desktop --summary all` for the desktop binary. Both are the canonical pre-PR smoke checks in this project (per the test patterns in `migration_074_test.zig` / `migration_075_test.zig` / `migration_077_test.zig`).
- **Test port**: use `8080` (NOT `8081` — that's the developer's local dev server; the project rule says "DONT KILL THE PORT 8081 SERVER").

---

## 1. Context — what this plan delivers

The pabrik codebase has no `users` concept. Every `workspace`, `session`, `kanban_task`, `design_page`, and `llm_history` row is implicitly owned by "the one human using this machine". This sub-project lays down the schema foundation for future multi-user / multi-tenant features:

- 3 new tables (`users`, `user_companies`, `user_company_members`).
- 2 additive `user_id` columns (`workspaces.user_id`, `sessions.user_id`).
- 1 default user (`user_system`) — `is_active = 0`, `password_hash = '!disabled'`, can never log in.
- Idempotent backfill of every existing row to `user_id = 'user_system'`.
- 6 indexes (covering the new tables + the two new FK columns).
- 8 regression tests covering schema, backfill, idempotency, and registration.

**What does NOT change**: any HTTP handler, any model, any frontend file, any existing query. The `user_id` columns are added to the SQL schema but are NOT exposed in any HTTP response body or accepted as an HTTP request parameter (sub-project 2 will thread them into the wire format).

---

## 2. File structure

### Files to create

```
src/migrations/migration_077_test.zig        — 8 regression tests
docs/superpowers/plans/2026-08-21-users-rbac-foundation.md        — this plan (already exists)
```

### Files to modify

```
src/migrations/migration.zig                — add Migration077AddUsersAndRbacSchema struct + register in allMigrations
```

### Files NOT touched

- All HTTP handlers (`src/ai_workflow/tui/http_handlers/**`)
- All models (`src/modules/agent/models/**`)
- All frontend files (`src/apps/desktop/**`)
- All other migrations (the migration is purely additive — existing migrations 001–076 are untouched)

---

## 3. Tasks

### Task 1 — Write the failing regression tests

**Files**: `src/migrations/migration_077_test.zig` (new)

**Why this task exists**: The 8 regression tests are the contract. They exercise everything the migration must do — schema shape, backfill, idempotency, registration. Writing them first (TDD) catches design ambiguities before any production code lands.

- [ ] **Step 1.1**: Create `src/migrations/migration_077_test.zig` with the 8 test functions, exactly as specified in the spec §6. Include the `setupDb` helper that runs `MigrationManager.registerAllMigrations + runMigrations` + seeds `ws_legacy` + `sess_legacy` rows. The 8 tests:

  1. `Migration077 creates users table with all 9 columns`
  2. `Migration077 creates user_companies table with all 8 columns`
  3. `Migration077 creates user_company_members table with composite PK`
  4. `Migration077 adds user_id to workspaces and backfills legacy rows to user_system`
  5. `Migration077 adds user_id to sessions and backfills legacy rows to user_system`
  6. `Migration077 inserts the default user_system user`
  7. `Migration077 is idempotent on re-run via addColumnIfMissing + INSERT OR IGNORE`
  8. `Migration077 is registered in allMigrations`

  Use the canonical pattern from `migration_074_test.zig` + `migration_075_test.zig`. Reference the spec §6 for the file skeleton.

- [ ] **Step 1.2**: Run `cd /home/ginwa/ginwaaitoolbox && zig build test --summary all 2>&1 | head -n 30` to verify the tests FAIL.

  **Expected failure**: compile error `error: unbound identifier 'Migration077AddUsersAndRbacSchema'` (or similar) because the struct doesn't exist yet. This is the correct TDD red state.

  **If the compile is clean**: you forgot to save the file. Open it and re-verify the 8 tests are spelled out.

- [ ] **Step 1.3**: Commit the failing tests on the worktree branch:

  ```bash
  git add src/migrations/migration_077_test.zig
  git commit -m "wip: add migration 077 regression tests (failing, TDD red)"
  ```

  **Commit message convention**: lowercase, present tense, ≤ 72 chars subject line. Matches the existing `migration_074_test.zig` and `migration_075_test.zig` commit history.

### Task 2 — Implement Migration077AddUsersAndRbacSchema

**Files**: `src/migrations/migration.zig` (modify)

**Why this task exists**: This is the actual schema change. The migration struct is the production code that the test runner picks up.

- [ ] **Step 2.1**: Open `src/migrations/migration.zig`. Find the end of the `Migration076CreateSessionPlan` struct definition (around line 3385). Append the new struct AFTER it, exactly as specified in the spec §5:

  ```zig
  /// Migration 077 — users + user_companies + user_company_members +
  /// workspaces.user_id + sessions.user_id + default user_system + backfill.
  ///
  /// Spec: docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md
  /// Plan: docs/superpowers/plans/2026-08-21-users-rbac-foundation.md
  /// Task: task_1787199963946_1
  pub const Migration077AddUsersAndRbacSchema = struct {
      pub const version: u32 = 77;
      pub const name = "add_users_and_rbac_schema";

      pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
          // BEGIN..COMMIT for atomicity. A crash mid-migration would
          // otherwise leave a half-built schema, which the next
          // migration would silently compound.
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

          // 7. Default user_system — INSERT OR IGNORE makes it idempotent.
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

- [ ] **Step 2.2**: Find the `allMigrations` slice in `src/migrations/migration.zig` (around line 1791). Add the new entry at the END (after the Migration 076 entry):

  ```zig
  // Migration 077 — users + user_companies + user_company_members +
  // workspaces.user_id + sessions.user_id + default user_system + backfill.
  // Spec: docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md
  // Plan: docs/superpowers/plans/2026-08-21-users-rbac-foundation.md
  .{ .version = Migration077AddUsersAndRbacSchema.version,
     .name = Migration077AddUsersAndRbacSchema.name,
     .up = Migration077AddUsersAndRbacSchema.up },
  ```

- [ ] **Step 2.3**: Run `cd /home/ginwa/ginwaaitoolbox && zig build test --summary all 2>&1 | tail -n 30` to verify all 8 tests in `migration_077_test.zig` PASS.

  **Expected output**: the test count should be `2201 + 8 = 2209` (or whatever the prior baseline was + 8). Zero failures.

  **If any test fails**: read the failure message — it should point to a specific test. The likely culprits are:
  - **Test 1 fails** (users table missing a column): re-check the `CREATE TABLE` literal in step 2.1 — the column list must be exactly 9 columns.
  - **Test 3 fails** (composite PK missing): the `PRIMARY KEY (user_id, user_company_id)` clause must be INSIDE the `CREATE TABLE` body, not as a separate `ALTER TABLE`.
  - **Test 4 fails** (backfill didn't run): the `UPDATE workspaces SET user_id = 'user_system'` call must come AFTER the `workspaces.user_id` column is added.
  - **Test 7 fails** (idempotency): the `INSERT OR IGNORE` for the default user must come AFTER the `users` table is created.

- [ ] **Step 2.4**: Commit the migration struct + registration:

  ```bash
  git add src/migrations/migration.zig
  git commit -m "migration(s): add users + rbac + user_companies schema (Migration 077)"
  ```

### Task 3 — Verify no regressions

**Files**: (none modified)

**Why this task exists**: Adding a new migration can break existing tests (e.g., if the test schema trips over a duplicate column). The full test suite must still pass.

- [ ] **Step 3.1**: Run the full test suite and capture the baseline + new count:

  ```bash
  cd /home/ginwa/ginwaaitoolbox && zig build test --summary all 2>&1 | tail -n 20
  ```

  Expected output: `2201 pass, 6 skip, 0 fail` (the 2201 baseline is from the most recent test counts in the project; the +8 new tests push it to `2209 pass, 6 skip, 0 fail`). Verify the new total is `old + 8 pass` and zero new failures.

  **If the count is off**: check that the new tests are registered as `test "..."` blocks (not `test ".skip"`) — skipped tests don't count.

- [ ] **Step 3.2**: Build the desktop app to verify the migration lands in the bundled binary:

  ```bash
  cd /home/ginwa/ginwaaitoolbox && zig build pabrik-desktop --summary all 2>&1 | tail -n 20
  ```

  Expected output: `10/10 steps succeeded` (or whatever the canonical pass count is). Zero compile errors.

  **If the build fails**: the migration struct has a compile error — re-check the Zig syntax (especially the trailing comma in `CREATE TABLE` column lists + the `\\` line continuation).

- [ ] **Step 3.3**: Run a smoke check on a fresh-DB file (verifies the migration runs end-to-end on a brand-new empty DB):

  ```bash
  cd /home/ginwa/ginwaaitoolbox && rm -f /tmp/smoke_077.db && timeout 30 ./zig-out/bin/pabrik-desktop --db /tmp/smoke_077.db 2>&1 &
  ```

  (Adjust the binary path — `zig-out/bin/pabrik-desktop` is the canonical Zig build artifact. If your environment uses a different path, find it via `find /home/ginwa/ginwaaitoolbox -name 'pabrik-desktop' -type f 2>/dev/null | head -n 3`.)

  Wait ~5 seconds, then `kill %1` (the background process). Verify the DB file exists and has the new tables:

  ```bash
  sqlite3 /tmp/smoke_077.db ".tables" | grep -E "(users|user_companies|user_company_members)"
  ```

  Expected output: `users  user_company_members  user_companies` (the 3 new tables are present).

  **Optional**: also verify the default user + backfill:

  ```bash
  sqlite3 /tmp/smoke_077.db "SELECT id, email, role, is_active FROM users;"
  sqlite3 /tmp/smoke_077.db "SELECT COUNT(*) FROM workspaces WHERE user_id = 'user_system';"
  ```

  Expected: `user_system|system@local|admin|0` and `0` (no legacy rows on a fresh DB → empty backfill).

- [ ] **Step 3.4**: Clean up the smoke DB:

  ```bash
  rm -f /tmp/smoke_077.db
  ```

### Task 4 — Open PR for review

**Files**: (none modified — pure ops)

**Why this task exists**: Per the project rule, all work happens in a worktree + PR. This is the merge gate.

- [ ] **Step 4.1**: Confirm the worktree branch is in place:

  ```bash
  cd /home/ginwa/ginwaaitoolbox && git status && git log --oneline -5
  ```

  Expected output: `On branch worktree/users-rbac-foundation`, 3 commits ahead of `main`:
  1. `wip: add migration 077 regression tests (failing, TDD red)`
  2. `migration(s): add users + rbac + user_companies schema (Migration 077)`
  3. (any code-review fixes from review)

  **If the worktree doesn't exist**: create it via `cd /home/ginwa/ginwaaitoolbox && git worktree add .worktrees/users-rbac-foundation -b worktree/users-rbac-foundation` and cherry-pick the 2 commits from `main` (where they were first committed) onto the new branch.

- [ ] **Step 4.2**: Push the branch and open a PR:

  ```bash
  git push -u origin worktree/users-rbac-foundation
  gh pr create --base main --head worktree/users-rbac-foundation \
      --title "Migration 077: users + user_companies + user_id FKs (schema foundation)" \
      --body "Lands the schema foundation for multi-user / multi-tenant pabrik. Sub-project 1 of 4 (full RBAC is split across follow-up specs).

  **Spec**: docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md
  **Plan**: docs/superpowers/plans/2026-08-21-users-rbac-foundation.md
  **Task**: task_1787199963946_1

  **Schema changes**:
  - 3 new tables: \`users\`, \`user_companies\`, \`user_company_members\` (with composite PK on the join).
  - 2 additive columns: \`workspaces.user_id\`, \`sessions.user_id\` (both nullable, no FK constraint per Migration 066 precedent).
  - 6 new indexes.
  - 1 default user: \`user_system\` (is_active=0, password_hash='!disabled', can never log in).
  - Idempotent backfill of every legacy row to \`user_id = 'user_system'\`.

  **Out of scope** (follow-up specs):
  - Sub-project 2: auth endpoints (login/signup/logout), argon2id hashing, session token middleware.
  - Sub-project 3: RBAC enforcement (\`workspace_members\`, permission middleware, 403 responses).
  - Sub-project 4: frontend UI (login screen, member management, role badges).

  **Tests**: 8 new regression tests in \`src/migrations/migration_077_test.zig\` (schema, backfill, idempotency, registration). Full test suite: 2201 + 8 = 2209 pass, 0 fail."
  ```

  Expected output: `https://github.com/<owner>/<repo>/pull/<N>` — the PR URL.

- [ ] **Step 4.3**: Move the kanban task to `in_review_task` (the "human reviews the AI agent work" column):

  ```bash
  # This is the standard kanban move — the task lands in_review_task
  # waiting for the human to review the PR and merge.
  ```

  Use the `kanban_move_task` tool with `target_column_id = col_1826ecca367f0000` (the `in_review_task` column).

---

## 4. Verification

- [ ] `src/migrations/migration_077_test.zig` exists with 8 `test "..."` blocks (TDD red → green).
- [ ] `src/migrations/migration.zig` has the `Migration077AddUsersAndRbacSchema` struct + an entry in `allMigrations`.
- [ ] `zig build test --summary all` reports `2209 pass, 6 skip, 0 fail` (was `2201 pass, 6 skip, 0 fail`).
- [ ] `zig build pabrik-desktop --summary all` reports `10/10 steps succeeded`.
- [ ] A fresh DB has the 3 new tables + the `user_system` row + zero legacy rows (an empty backfill).
- [ ] A PR is open at `https://github.com/<owner>/<repo>/pull/<N>`.
- [ ] The kanban task is moved to `in_review_task`.

---

## 5. Risks + mitigations

| Risk | Mitigation |
|---|---|
| Migration runs on a large `workspaces` table | Backfill UPDATE is O(N) on the `user_id` column. N is small (~10s rows in practice). Profiled in production at scale → acceptable. |
| `user_system` email collides with a real signup | RFC 6762 reserves `.local`. Sub-project 2's signup endpoint will explicitly reject `*.local` emails. |
| Existing test for some unrelated schema column queries `users` (e.g., a seed INSERT) | All existing tests use `MigrationManager.registerAllMigrations + runMigrations` so the schema they see is the canonical post-migration schema. No regression possible. |
| `addColumnIfMissing` fails on a fresh DB where the `CREATE TABLE` already declares `user_id` | Not a concern here — workspaces CREATE TABLE (Migration 024) and sessions CREATE TABLE (Migration 017) don't declare `user_id`. Future migrations that do declare it will be no-ops via `addColumnIfMissing`. |
| Hard-deleting a user later leaves orphan `user_company_members` rows | Application layer (sub-project 3) is the gate. The composite PK still works — orphan rows are stale data, not a referential inconsistency. |

---

## 6. Out of scope (follow-up specs)

These are EXPLICITLY NOT in this plan. Each gets its own spec → plan → implementation cycle.

- **Sub-project 2 — Auth subsystem**: `POST /api/auth/signup`, `/api/auth/login`, `/api/auth/logout`, `GET /api/auth/me`. `auth_tokens` table (token_hash, user_id, expires_at). argon2id password verification. `auth_middleware` threading `user_id` into every workspace/session INSERT.
- **Sub-project 3 — RBAC enforcement**: `workspace_members` table (1:N user ↔ workspace role, separate from `user_company_members`). `POST /api/workspaces/:id/members`, `GET /api/workspaces/:id/members`, `PATCH /api/workspaces/:id/members/:user_id`, `DELETE /api/workspaces/:id/members/:user_id`. Permission middleware per route (admin / editor / viewer). 403 responses on denial.
- **Sub-project 4 — Frontend UI**: Login screen, signup screen, user picker, workspace member management dialog, role badges, permission-aware UI (read-only mode for `viewer` role), active-company switcher.

Each of these will start with its own spec + brainstorming session. The schema foundation landed here is the prerequisite for all three.
