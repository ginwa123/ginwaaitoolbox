# nalar — `SqliteBackend.exec` binds empty `[]const u8` as SQL NULL

In `src/modules/databases/sqlite/Sqlite.zig:73-74`, the `exec` function
treats any `[]const u8` argument with `arg.len == 0` as `NULL`:

```zig
for (argv, 0..) |arg, i| {
    const param_idx: c_int = @intCast(i + 1);
    if (arg.len == 0) {
        rc = c.sqlite3_bind_null(stmt, param_idx);
    } else {
        rc = c.sqlite3_bind_text(stmt, param_idx, arg.ptr, @intCast(arg.len), c.SQLITE_TRANSIENT);
    }
    ...
}
```

This is a project-specific convention: **empty slice → NULL, not
empty string**. The `query` function (line 209) does the same.

## Why this bites

When a column is declared `NOT NULL`, callers cannot pass an empty
string as a sentinel "no value" — the empty slice gets bound as NULL
and the INSERT/UPDATE fails with
`NOT NULL constraint failed: <table>.<column>`.

The only way to get an empty string into a NOT NULL column is either:
1. Omit the column from the INSERT (let the DEFAULT '' apply).
2. Pass a non-empty placeholder that the application layer
   translates to "" on the way out (not great).
3. Change the column to nullable.

For the kanban-column `description` field (Migration 053), the model
layer uses option 1: `addColumn` builds a 4-column INSERT (no
description) when description is empty, and a 5-column INSERT when
non-empty.

## Symptom

```
sqlite3_step error: NOT NULL constraint failed: kanban_columns.description
```

In `Sqlite.zig:94` — comes from `db.exec(...)` returning
`Error.ExecuteFailed`.

## Fix patterns

### Pattern A — split INSERT into "with description" / "without description"

```zig
if (description.len == 0) {
    try db.exec(allocator,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES (?, ?, ?, ?)",
        &.{ id, workspace_item_id, name, pos_str });
} else {
    try db.exec(allocator,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, description, position) " ++
        "VALUES (?, ?, ?, ?, ?)",
        &.{ id, workspace_item_id, name, description, pos_str });
}
```

Use this for INSERTs into `NOT NULL DEFAULT ''` columns that the
caller may legitimately pass as "".

### Pattern B — skip the UPDATE when the value is empty (no-op semantics)

For an "update this field IF non-empty" API (e.g. the new
`kanban_model.updateColumn`), the cleanest fix is to skip the
UPDATE entirely when the value is `""`. The caller is saying
"don't change this field" by passing `""`, and the SQLite layer
can't distinguish that from "set to NULL".

```zig
if (description) |d| {
    if (d.len > 0) {
        try db.exec(allocator,
            "UPDATE kanban_columns SET description = ? WHERE id = ?",
            &.{ d, column_id });
    }
}
```

Trade-off: callers can't currently "clear" an existing description
through this path — they'd need a separate "delete description"
API. Acceptable for v1 where the frontend treats `""` and the
current value identically.

### Pattern C — fix at the SQLite backend layer (NOT recommended)

Changing `Sqlite.zig` to always bind empty slices as `""` would be
the cleanest fix, but it's a cross-cutting change that would alter
the semantics of every existing call site. Out of scope for
incremental feature work.

## When this bites

- Any new `db.exec` call that includes a `NOT NULL` column with a
  `DEFAULT ''` and the caller may pass `""` (the "no description"
  pattern).
- Any new model function that uses `?[]const u8` to mean "leave
  unchanged" — the empty slice vs. null distinction is invisible
  to the SQLite layer.
- Migrations that add a new `NOT NULL DEFAULT ''` column to a
  table — the new column requires either schema-level care
  (always include in INSERTs) or model-layer care (split SQL by
  presence of value).

## How to verify

```bash
# Compile + run the new model's unit tests:
TEST_BIN=$(ls -t .zig-cache/o/*/test | head -n 1)
timeout 60 "$TEST_BIN" 2>&1 | rg "kanban_model_test_description"
# Expected: 5/5 tests pass with "description" round-trip
# assertions (e.g. "Not started yet — work in queue").
```

If you see `NOT NULL constraint failed: <col>`, the value being
bound is `""` and the column is `NOT NULL`. Either omit the column
from the INSERT (let DEFAULT apply) or guard the UPDATE behind
`if (d.len > 0)`.

## Related

- `zig-migration-tests-three-pitfalls.md` — different SQLite pitfall
  (PrepareFailed vs QueryFailed for missing tables).
- `nalar-http-handler-thin-wrapper-pattern.md` — convention for
  parsing PATCH bodies with `parseFromSliceLeaky`.
- The actual fix in nalar is at `src/ai_workflow/tui/kanban_model.zig`
  in the `addColumn` and `updateColumn` functions, committed as
  `9d305c4b feat(kanban): extend KanbanColumn with description`.