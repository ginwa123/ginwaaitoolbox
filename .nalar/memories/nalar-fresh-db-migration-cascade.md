# nalar — Migration #009-#052 fresh-DB cascade is fragile; CI smoke test catches it

When the criteria-pass smoke test (`scripts/ci-smoke-test.sh`) boots `nalar` against an isolated `$HOME` (auto-creating `config.json` + running all 54 migrations from scratch), the `runMigrations` step fails at FOUR different migrations, in order:

1. **Migration 009** — references a `created` column that has never existed.
   `created_at` has been the column name since Migration 001. The
   `INSERT…SELECT datetime(CAST(created AS INTEGER), 'unixepoch')`
   crashes with `no such column: created`.

2. **Migration 009** also forward-projects the schema — its `CREATE TABLE`
   declares `temperature REAL` and `is_thinking INTEGER DEFAULT 0`,
   which **Migration 011** later tries to `ADD COLUMN`. On a fresh DB
   this crashes with `duplicate column name: temperature`.

3. **Migration 020** uses `ALTER TABLE … ADD COLUMN IF NOT EXISTS`,
   which SQLite doesn't support (it errors at prepare with
   `near 'EXISTS': syntax error`). The three columns it tries to
   add (`working_directory`, `last_activity`,
   `last_activity_description`) are already in Migration 019's
   CREATE TABLE for `worker`, so on a fresh DB this is also a
   `duplicate column name` error if you just remove the `IF NOT
   EXISTS`.

4. **Migration 052** calls `DROP COLUMN session_id` on
   `workspace_item_tasks`, but Migration 034's canonical schema
   never declares `session_id` (it was redundant — `task.id` IS
   the session id). On a fresh DB: `no such column: session_id`.

## Why these bugs were hidden

Every developer's existing database has these migrations already
applied (or already failed). The "happy path" smoke check
(`./zig-out/bin/nalar --version`) doesn't actually boot the
server, so none of the bootstrap code paths are exercised. CI
didn't catch it because CI used the same `--version` placebo
check. New users on fresh installs would hit the bug; the smoke
test fixes that.

## The fixes (in PR #69)

1. `migration.zig` Migration 009: replace
   `datetime(CAST(created AS INTEGER), 'unixepoch')` with
   `COALESCE(created_at, CURRENT_TIMESTAMP)`. Also remove
   `temperature` and `is_thinking` from Migration 009's
   CREATE TABLE / INSERT projection.

2. New helpers `addColumnIfMissing` and `dropColumnIfExists`
   in `migration.zig`. Both are zero-alloc, stack-buffer
   their SQL strings, and check `pragma_table_info('<table>')`
   before issuing the ALTER. Used by Migrations 020 and 052
   respectively.

3. New regression test `migration_009_test.zig` replays
   Migrations 001–008 + 009 against an in-memory DB and
   asserts no crash (with both empty and pre-populated row
   cases).

## When this bites

- Any new CI smoke test that runs the binary against a fresh
  `$HOME` (the only way to actually catch fresh-DB bugs)
- Any new user installing nalar for the first time
- Any docker / container deployment that bind-mounts an
  empty `agent.db`

## How to verify

```bash
env -i HOME=/tmp/nalar-fresh-test PATH=$PATH \
  ./zig-out/bin/nalar --port 18080 &
sleep 5
ss -tln | grep 18080  # expect: 0 (server crashed on migration)
```

If you see the migration 9 / 11 / 20 / 52 errors in the log,
the cascade is back. The fix is in commit `866a9add` on
branch `feature/criteria-smoke-test` (PR #69).

## Related

- `nalar-http-handler-thin-wrapper-pattern.md` — different
  CI / handler pattern (the `initSchema` multi-statement bug)
- `zig-migration-tests-three-pitfalls.md` — different migration-test
  pitfall (PrepareFailed vs QueryFailed for missing tables)