# LLM history + FTS tests: use migrations module, not hand-created schema

## Symptom

Tests that hand-create the `llm_history` table + `messages_fts` + sync
triggers silently test an outdated schema. The moment a new migration
adds a `NOT NULL` column (e.g. `model`, `created_iso`), the INSERT
fails with `NOT NULL constraint failed: llm_history.model` — and the
test fails for the wrong reason.

## Root cause

The `llm_history` table is rebuilt across 67 migrations:
- `model TEXT NOT NULL` (added in early CREATE TABLE migration)
- `created_iso TEXT` (added in migration 059)
- `messages_fts` triggers (added in migration 058)
- many other columns added via ALER

Hand-creating the schema in `setupDb()` is a maintenance trap. The
test author copies "looks plausible" column list, omits `model`, and
the next person to add a column doesn't touch the test so the test
silently passes against an outdated schema.

## Fix (always use migrations module in test setup)

```zig
const migration = @import("../../migrations/migration.zig");

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
    return .{ .db = db, .threaded = threaded };
}
```

This walks all 67 migrations, so the test schema is GUARANTEED to
match production. The next time someone adds a migration, they
ONLY have to update production code — the test setup follows
automatically.

## Trade-off

Running 67 migrations adds ~50 ms to each test's setup (vs ~5 ms for
hand-created schema). For a test suite with 5-10 tests in the file,
that's 250-500 ms total — acceptable cost for schema-safety.

## Reviewer pattern (project convention)

User reviews on the ginwa123 PR queue flag this consistently:
> "when setup db, use from migrationsss module, migrations module will load all table"

So use the migrations module from the start when writing any new
SQLite-backend test. Don't try to hand-create the schema "to keep
the test fast."

## Pitfalls

- **Production schema may have `NOT NULL` columns** that your hand-
  rolled INSERT didn't include. Adding `model` to the INSERT is the
  typical fix. Check `migration.zig` for the final CREATE TABLE
  shape after all migrations.
- **`MigrationManager.init` takes a `*sqlite.SqliteBackend`, not a
  `*Sqlite` interface** — make sure the test ctx holds the backend
  type, not a wrapper.
- **Don't forget `defer manager.deinit()`** — the manager has its own
  allocator bookkeeping.

## Related

- PR #172 (tool-error-better-message) — reviewer's "use migrations
  module" comment prompted this fix
- File: `src/ai_workflow/tui/llm_history_search_fts_query_safety_test.zig`
- Existing `llm_history_search_messages_fts_test.zig` still uses the
  hand-created schema (older test, pre-reviewer-feedback era). Could
  be migrated in a follow-up.
