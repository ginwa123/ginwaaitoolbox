# Shared workspaces — replacing `workspaces.user_id` with a `workspace_members` join table

Status: **implemented** in PR #781. Migration 100 shipped; `zig build`,
`zig build test` (4228 tests) and the functional suites are green.

Sections 4-6 below are the design as written. **Section 12 (As-built notes)**
records what the implementation actually deviated on — read it before trusting
a claim in the middle of this document.

Task: `task_1790967164653_0` (kanban AGENTIC_KANBAN).

---

## 1. Answer in one paragraph

A single column can only ever hold one user, so stop putting the user on
`workspaces`. Add a **`workspace_members(workspace_id, user_id, role)` join
table**, mirroring the `user_company_members` table that Migration 077 already
created for exactly this purpose, and make workspace visibility a query against
that table instead of a column comparison. Keep `workspaces.user_id` in place
(deprecated, still written) for one release so the change is reversible; drop it
in a follow-up migration once nothing reads it.

The migration is additive and the backfill is one `INSERT … SELECT`, so the
whole thing is reversible by dropping the table. The blast radius is small:
**one new function, 8 mechanical one-line call-site swaps, 2 handler changes,
1 migration.**

---

## 2. Current state

### 2.1 The schema

```
workspaces(
    id         TEXT PRIMARY KEY,               -- Migration 024  (migration.zig:420)
    name       TEXT NOT NULL DEFAULT '',       -- Migration 027  (migration.zig:460)
    created_at DATETIME DEFAULT NULL,          --               (migration.zig:499)
    updated_at DATETIME DEFAULT NULL,          --               (migration.zig:500)
    position   INTEGER NOT NULL DEFAULT 0,     --               (migration.zig:726)
    user_id    TEXT                            -- Migration 077  (migration.zig:4594-4600)
)
```

`user_id` is nullable, FK-less, and indexed (`idx_workspaces_user_id`,
`migration.zig:4631`). The project's `PRAGMA foreign_keys` is deliberately OFF
in production (`migration.zig:3714`, `:5321-5323`), so the column has **no
referential integrity at all** — only the application layer keeps it honest.

### 2.2 Everything funnels through one function

`src/http_handlers/auth_common.zig:128`:

```zig
pub fn ownerVisibilityClause(comptime alias: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "(? = '{s}' OR {s}.user_id IS NULL OR {s}.user_id = '' OR {s}.user_id = '{s}' OR {s}.user_id = ?)",
        .{ system_user_id, alias, alias, alias, system_user_id, alias },
    );
}
```

It is a comptime-formatted constant, so it costs nothing at runtime and is
used as `"SELECT … WHERE " ++ ownerVisibilityClause("workspaces")`.

**Contract: the owner is bound twice** — once for the leading
`? = 'user_system'` sentinel test, once for the trailing `w.user_id = ?`. Eight
call sites depend on that arity.

### 2.3 The eight call sites

| # | file:line | function | kind |
|---|---|---|---|
| 1 | `auth_common.zig:183` | `canSeeWorkspace` | read (authz) |
| 2 | `workspaces_list.zig:102` | `fetchWorkspacesList` | read (list filter) |
| 3 | `workspace_get.zig:71` | `useCase` | read (authz) |
| 4 | `workspace_update.zig:95` | `useCase` | read (authz) |
| 5 | `workspace_update.zig:109` | `useCase` | write (UPDATE) |
| 6 | `workspace_delete.zig:66` | `useCase` | read (authz) |
| 7 | `workspace_delete.zig:82` | `useCase` | write (DELETE) |
| 8 | `workspaces_reorder.zig:160` | `reorderWorkspaces` | write (UPDATE) |

Plus the single writer of the column:
`workspaces_create.zig:164` (`INSERT INTO workspaces (…, user_id) VALUES (…)`).

And one indirect gate that covers ~55 child routes:
`auth_middleware.zig:75` calls `canSeeWorkspace` for any route carrying a
`:workspace_id` path param.

### 2.4 The identity source

`resolveRequestUserId` (`auth_common.zig:236`) resolves `pabrik_session` cookie →
sha256 → `auth_sessions` row → `users.id`. It **never returns null** — every
failure path returns the sentinel `"user_system"` (`auth_common.zig:242-244`).

---

## 3. Why the single column is the wrong shape

The column is currently doing **two unrelated jobs at once**, and that is the
real reason it cannot be extended:

1. **Ownership** — "who created this" (1 workspace : 1 user).
2. **The shared legacy bucket** — `user_id IS NULL`, `= ''`, or `= 'user_system'`
   means "visible to every authenticated user". These three disjuncts exist so
   that flipping `--auth` on never hides the machine owner's data
   (`auth_common.zig:110-126`; decision recorded 2026-09-25).

Job 2 is a **visibility** property and has nothing to do with job 1. Storing it
in the user column means "shared" is expressed as a magic *value* of a
*person* column, which is why:

- A second user cannot be added without either overwriting the first or
  inventing a comma-joined list (which no query can use with an index).
- `user_system` is simultaneously (a) the auth-off identity, (b) the
  "shared/public" marker, and (c) the backfill target for pre-`--auth` rows.
  Three meanings, one string.
- A workspace cannot be both *owned by Alice* and *visible to everyone* unless
  you give up one of them.

Separate the two: **membership rows** answer "who", a **marker row** answers
"shared".

---

## 4. The design

### 4.1 Schema

```sql
-- Migration 100
CREATE TABLE IF NOT EXISTS workspace_members (
    workspace_id TEXT NOT NULL,
    user_id      TEXT NOT NULL,
    role         TEXT NOT NULL DEFAULT 'viewer'
                 CHECK (role IN ('owner', 'admin', 'editor', 'viewer')),
    joined_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
    invited_by   TEXT,
    PRIMARY KEY (workspace_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_workspace_members_user
    ON workspace_members(user_id, workspace_id);
```

This is a deliberate copy of `user_company_members`
(`migration.zig:4579-4588`): composite PK for no-duplicate-membership, no FK
(SQLite cannot `ALTER TABLE … ADD CONSTRAINT`, and the pragma is off anyway),
`joined_at` + `invited_by` audit columns, `CHECK`-constrained role.

Note the PK column order is `(workspace_id, user_id)` — the direction the hot
visibility query needs — with a separate `(user_id, workspace_id)` index for the
"my workspaces" direction. `user_company_members` has two single-column indexes
(`migration.zig:4625-4628`); here they are composite so both directions are
covering.

### 4.2 Backfill — one statement

```sql
INSERT OR IGNORE INTO workspace_members (workspace_id, user_id, role, joined_at)
SELECT id,
       COALESCE(NULLIF(user_id, ''), 'user_system'),
       'owner',
       datetime('now')
FROM workspaces;
```

Every workspace gets **at least one** member row:

| Legacy `workspaces.user_id` | Backfilled membership | Who can see it after |
|---|---|---|
| `'user_a'` | `('ws_x','user_a','owner')` | Alice only — unchanged |
| `'user_system'` | `('ws_x','user_system','owner')` | **everyone** — unchanged |
| `NULL` or `''` | `('ws_x','user_system','owner')` | **everyone** — unchanged |

`NULLIF(…, '')` handles the empty-string bucket; `COALESCE` maps it to the
sentinel so the NOT NULL column is satisfied. Both are SQL literals, not binds,
so the "empty slice binds as NULL" hazard (`SqliteBackend.exec`) does not apply
here — but it *absolutely* applies to the runtime write path, see §5.3.

**`INSERT OR IGNORE` is load-bearing twice over:** it makes re-runs no-ops
(fresh-install replay safety), and it means re-running the backfill after users
start sharing **cannot clobber** member rows that were added later, nor
downgrade an `owner`.

### 4.3 The new visibility clause

Add a sibling to `ownerVisibilityClause` — do **not** change the existing one,
because `worker_list.zig:81` and `llm_history.zig:353` use it against `worker`
and `sessions`, which are *not* workspace-scoped.

```zig
/// src/http_handlers/auth_common.zig — new
pub fn workspaceVisibilityClause(comptime alias: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "(? = '{s}' OR EXISTS (SELECT 1 FROM workspace_members m " ++
            "WHERE m.workspace_id = {s}.id AND (m.user_id = ? OR m.user_id = '{s}')))",
        .{ system_user_id, alias, system_user_id },
    );
}
```

Two disjuncts that mean exactly what they say:

- `? = 'user_system'` → auth is off → the caller is the installation → sees
  everything. Short-circuits before the subquery runs.
- `EXISTS (… m.user_id = ? OR m.user_id = 'user_system')` → the caller is a
  member, **or** the workspace carries the sentinel member row (i.e. it is
  shared).

**The arity is unchanged: still exactly two binds.** That is the whole trick —
all 8 call sites keep binding `{ …, owner, owner }` and none of them need a
parameter-order edit.

**Bonus property:** adding a `user_system` member row *is* the "make this
workspace shared" operation. No second flag, no second concept, no chance of the
flag and the membership disagreeing.

### 4.4 Roles: present but not enforced (yet)

Migration 100 writes the `role` column and **does not enforce it**. Every
member has full access, which is exactly today's behaviour for every existing
workspace. Enforcement is a separate change, because:

- The spec's role set for workspaces (`admin / editor / viewer`,
  `docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md:464`) is
  **disjoint** from the company set (`owner / admin / member / guest`,
  `migration.zig:4583`).
- A SQLite `CHECK` constraint is effectively immutable without a table recreate
  (the Migration 026 dance, `migration.zig:445-453`). Picking the wrong role set
  costs a recreate later, so it deserves its own decision and its own migration.
- Shipping visibility and permission enforcement together makes a regression in
  either indistinguishable from the other.

`DEFAULT 'viewer'` is least-privilege, so any row written by a path that forgets
to set a role is read-only rather than read-write.

---

## 5. Change plan

### 5.1 Migration 100 — `Migration100AddWorkspaceMembers`

Additive only. Wrapped in a single transaction (the Migration 077 precedent,
`migration.zig:4534-4540`: `var tx = try db.begin(); … tx.commit()`) because the
table and its backfill must be atomic together.

```
1. CREATE TABLE IF NOT EXISTS workspace_members (…)      -- idempotent
2. CREATE INDEX IF NOT EXISTS idx_workspace_members_user …  -- idempotent
3. INSERT OR IGNORE INTO workspace_members SELECT …        -- idempotent
4. tx.commit()
5. ANALYZE                                            -- repo convention
   (migration.zig:4665; also 041/042/043/048-052/070/072)
```

**No `ALTER TABLE workspaces`.** The column stays, and `workspaces_create.zig:164`
keeps writing it. That is what makes rollback trivial: `DROP TABLE
workspace_members` + revert the clause function, and the old code works again
against an untouched `workspaces` table.

### 5.2 Call-site swaps (8 mechanical edits)

In each of the 8 sites, replace `ownerVisibilityClause(` with
`workspaceVisibilityClause(`. The bind list is untouched.

```
src/http_handlers/auth_common.zig:183        canSeeWorkspace
src/http_handlers/workspaces_list.zig:102    fetchWorkspacesList
src/http_handlers/workspace_get.zig:71       useCase
src/http_handlers/workspace_update.zig:95    useCase
src/http_handlers/workspace_update.zig:109   useCase
src/http_handlers/workspace_delete.zig:66    useCase
src/http_handlers/workspace_delete.zig:82    useCase
src/http_handlers/workspaces_reorder.zig:160 reorderWorkspaces
```

`workspaces_reorder.zig:87` currently does `resolveRequestUserId(...) catch ""`.
An empty owner matches the `= ''` disjunct today. Under the new clause an empty
owner matches only `m.user_id = ?` with `''`, i.e. nothing. **Fix that while
there** — `isSharedOwner("")` is `true` (`auth_common.zig:139`), so the empty
string should resolve to `user_system`, and the `catch ""` should become a
logged failure rather than a widened grant.

### 5.3 `workspaces_create.zig:164` — two writes, one transaction

Today it is a single `db.exec`. It must become:

```zig
var tx = try db.begin();
defer tx.commitOrRollback() catch {};
errdefer tx.rollback() catch {};
// 1. INSERT INTO workspaces (…, user_id) VALUES (…, ?)   -- unchanged, keeps rollback working
// 2. INSERT OR IGNORE INTO workspace_members (workspace_id, user_id, role)
//      VALUES (?, ?, 'owner')
tx.commit();
```

**Trap — the empty-owner bind.** `SqliteBackend.exec` binds an empty slice as
SQL **NULL** (`migration.zig:5318-5320`; live example `src/root.zig:321-323`).
`workspace_members.user_id` is `NOT NULL`, so binding a raw empty owner **fails
the INSERT with a constraint violation**. This is the same class of bug as
Migration 079's `content` column. Do not bind `owner` directly — normalise
first:

```zig
/// auth_common.zig — new
pub fn normaliseOwnerId(owner: []const u8) []const u8 {
    return if (owner.len == 0) system_user_id else owner;
}
```

### 5.4 `workspace_delete.zig:82` — explicit member cleanup

`PRAGMA foreign_keys` is OFF, so `DELETE FROM workspaces` leaves orphan member
rows. Add `DELETE FROM workspace_members WHERE workspace_id = ?` to the same
transaction, before the workspace delete.

### 5.5 Also worth fixing while in here

`workspace_delete.zig:82-88` never checks the affected-row count — a clause
mismatch makes `DELETE` match zero rows while the handler still answers
`200 {"success":true}`. And `auth_middleware.zig:74` gates on the literal
param name `"workspace_id"` while `/api/workspaces/:id` (`src/main.zig:711-713`)
uses `:id` and so bypasses that choke point entirely. Both are pre-existing;
neither is required by this migration.

---

## 6. Migration 101 (deferred, next release)

Only after one release in the wild:

1. Stop writing `workspaces.user_id` in `workspaces_create.zig`.
2. Drop `idx_workspaces_user_id`, then drop the column via the
   recreate-table dance (SQLite before 3.35; the Migration 026 precedent,
   `migration.zig:445-453`) — or plain `ALTER TABLE … DROP COLUMN` if the
   bundled SQLite is new enough. Verify before choosing.
3. Grep for `workspaces.user_id` and confirm zero readers remain.

---

## 7. Rollback

| Situation | Action |
|---|---|
| Migration 100 breaks anything | `DROP TABLE workspace_members`, revert the 8 swaps + the 2 handlers. `workspaces.user_id` was never touched, so **zero data loss**. |
| Backfill produced wrong rows | `DELETE FROM workspace_members` and re-run; it is `INSERT OR IGNORE` from a live SELECT, so it is repeatable. |
| A user was wrongly added as a member | `DELETE FROM workspace_members WHERE workspace_id = ? AND user_id = ?` |

Nothing in 100 is destructive, which is the main reason to ship it before 101.

---

## 8. What has to change in the tests

| Location | Why |
|---|---|
| `src/http_handlers/auth_common.zig:341-353` | String-asserts the generated clause contains `w.user_id IS NULL`, `w.user_id = ''`, `w.user_id = 'user_system'` and **ends with** `w.user_id = ?)`. Rewrite for the new clause; assert the two-bind arity explicitly. |
| `src/migrations/migration.zig:14110` | Asserts `pragma_table_info('workspaces') WHERE name='user_id'` returns exactly 1 — passes only because 100 does not drop the column. |
| `src/http_handlers/workspaces_list.zig:342-360` | Fixture DDL declares `user_id TEXT` and inserts legacy rows at `:447`; needs `workspace_members` too. |
| `src/http_handlers/workspace_items_default.zig:558` | Fixture DDL declares `user_id TEXT`. |
| `src/migrations/migration.zig:6642` | `setupOwnerRoots` fixture. |
| `src/migrations/migration.zig:6749+` | Migration 093 idempotency tests assert the backfill; unaffected but should be re-run. |
| `tests/functional/workspace_isolation_test.py` | The whole file encodes the per-user contract (6 cases, two cookie jars, one DB). This is the **real** proof — a functional harness test per the repo's no-live-server rule. |
| `src/migrations/migration.zig` (new) | New tests: fresh-DB replay, backfill mapping table above, re-run idempotency, **and the post-share re-run must not clobber added members**. |

New functional cases to add alongside the existing isolation suite:

- Bob is added to Alice's workspace → Bob sees it in `GET /api/workspaces`, can
  GET/PUT it, and gets 404 on a workspace he was not added to.
- Removing Bob → Bob 404s again.
- A `user_system`-owned workspace stays visible to a newly-created second user
  after migration 100 (this is the regression that would silently empty an
  operator's sidebar).

---

## 9. Alternatives considered

**`(a) Keep the column, add `workspace_shared_with` as a comma-joined TEXT list.**
Rejected: unusable in an indexed predicate, no role storage, and it silently
breaks on any id containing a comma.

**`(b) `workspaces.company_id` → inherit members from `user_company_members`.**
Rejected: the existing design deliberately decoupled these —
"workspaces belong to users, not companies"
(`docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md:480`).
It also cannot express "shared with one specific person".

**`(c) Replace the column with `workspaces.visibility TEXT` + a join table.**
Rejected in favour of the sentinel-member row: two mechanisms that can disagree,
whereas one sentinel row is self-consistent and doubles as the "share" action.

**`(d) Drop and re-add `workspaces.user_id` as a real FK to `users(id)`.**
Rejected: the pragma is OFF, so the FK would be inert, and dropping a column
requires the recreate-table dance — all risk, no benefit, in the same change that
adds sharing.

---

## 10. Open questions for the reviewer

1. **Is `user_system`-as-public-marker acceptable?** It gives the sentinel a
   second meaning beyond "auth is off". The alternative is a separate
   `workspaces.visibility` column (§9c). I chose the single mechanism, but this
   is the one design call worth arguing about.
2. **Should Migration 100 land before or after any UI?** The frontend has zero
   references to `user_id` (nothing in `src/apps/**` matches it) and no
   membership UI exists, so the backend change is invisible until a
   members dialog ships. That makes it safe to land alone.
3. **Is there a signup path?** There is none — users come only from
   `create-admin` (`src/main.zig:1281`) and the `user_system` seed
   (`migration.zig:4641`). Until one exists, "share with a colleague" needs that
   person to already be a user. Out of scope here, but it gates the feature.
4. **Should role enforcement ship with membership, or after?** This plan says
   after (§4.4). Confirm that is acceptable, since it means the first release of
   sharing is all-or-nothing at the workspace level.

---

## 11. References

- `docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md:456-467` —
  "Sub-project 3 — RBAC enforcement", which already names `workspace_members`
  and the `/api/workspaces/:id/members` routes. This plan is its schema half.
- `docs/superpowers/plans/2026-08-21-users-rbac-foundation.md:354`, `:402` — the
  plan-side mention.
- `docs/plans/2026-09-25-per-user-isolation.md` — the original per-user
  isolation work this extends.
- `src/migrations/migration.zig:4579-4588` — `user_company_members`, the shape
  being copied.

---

## 12. As-built notes — where the implementation differed from this plan

Written after the code shipped, so a reviewer does not have to re-derive it.

### 12.1 `workspace_delete.useCase` needed a transaction-error mapping the plan missed

`db.begin()` and `tx.commit()` return the full `sqlite.Error` set (13 variants:
`BindFailed`, `TransactionClosed`, `DiskFull`, …), which is far wider than the
handler-facing `WorkspaceDeleteError = { OutOfMemory, DatabaseError, NotFound }`.
Both are now collapsed to `error.DatabaseError` at the call site so the
handler's status-code switch stays the single place that decides what a client
sees.

### 12.2 A lazy-analysis blind spot — `useCase` was never compiled by `zig build test`

`useCase` in `workspace_delete.zig` is reachable only from
`workspaceDeleteHandler`, which only `main.zig` calls. Zig analyses lazily, so
the `mod_tests` build **never looked at the function at all** — 12.1's type
error left `zig build test` fully green and `zig build` was what failed.

This is the more important finding: a green test suite was not evidence. The
fix is an inline test in `workspace_delete.zig` that calls `useCase`, which
both forces compilation and covers the membership cleanup. Two tests were
added (cleanup happens; a refused delete takes nothing with it).

### 12.3 `migration.zig` had to be rebuilt to avoid a 2 000-line `zig fmt` reflow

`migration.zig` is **not** `zig fmt`-clean at HEAD, so formatting the file
after inserting Migration 100 rewrote ~2 100 unrelated lines and buried the
real change (the diff was 2 167 lines for ~135 lines of actual work). The file
was restored from HEAD and only the new struct, the `allMigrations` entry and
the new tests were spliced back — **+326 / −0**.

Worth knowing for any future migration: run `zig fmt` on a *snippet*, not on
the file, or the review diff is unreadable.

### 12.4 The migration ledger table is `schema_migrations`

Not `migrations`. The functional test asserts the row directly, so a
migration that is callable but never registered cannot pass.

### 12.5 Two of the new tests were wrong on first run

Recorded because both were caught only by running them, and both are the kind
of mistake that a plausible-looking assertion hides:

- The sharing test first asserted a visibility boundary on `ws_1` — a fixture
  row that is already in the shared legacy bucket, so `user_c` could see it
  before any sharing happened. The assertion proved nothing. It now uses a
  genuinely private workspace.
- The migration-wiring test guessed the ledger table name as `migrations`. It
  is `schema_migrations` (`migration.zig:1584`).

### 12.6 `workspaces_reorder.zig`'s `catch ""` now fails closed

Plan §5.2 called for this. It returns HTTP 500 rather than widening the caller
to "see everything". `worker_list.zig:156` has the same `catch ""` and the same
fail-open shape — **still unfixed, out of scope here, and worth its own ticket.**

### 12.7 Role enforcement is still not in place, as designed

Every member has full access. `workspace_members.role` is written, CHECK-
constrained, and currently read by nothing. That is deliberate (§4.4) but it
means sharing today is all-or-nothing at the workspace level — a `viewer`
cannot yet be prevented from deleting.
