//! Data layer for the kanban workspace item (item_type='kanban').
//!
//! Each kanban workspace item has N user-defined columns (the default
//! seed is `todo / in progress / done`). Tasks assigned to a kanban
//! item get a `kanban_column_id` + `kanban_position` and are
//! drag-and-drop reorderable within and across columns.
//!
//! Schema: see Migration 051 (`Migration051AddKanban` in
//! `src/migrations/migration.zig`).
//!
//! SQL convention: every SELECT aliases its tables (`kc` for
//! `kanban_columns`, `t` for `workspace_item_tasks`) and qualifies
//! every column reference with the alias. See the project memory
//! `nalar-sql-alias-tables.md`.
//!
//! Row ownership: each `db.query()` row's `values[i]` slices are
//! owned by the `Row` and freed by `row.deinit(allocator)`. To keep
//! a value past the loop iteration, the field is duplicated with
//! `allocator.dupe(u8, row.values[i])`. Strings returned by
//! `listColumns` are owned by the caller and must be released with
//! `freeColumns`.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 2)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

/// One kanban column row, fully duplicated into heap memory.
/// Free with `freeColumns(allocator, slice)`.
pub const KanbanColumn = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    description: []u8,
    position: i64,
    created_at: []u8,
};

/// Free the per-column strings and the backing slice in one call.
pub fn freeColumns(allocator: std.mem.Allocator, cols: []KanbanColumn) void {
    for (cols) |c| {
        allocator.free(c.id);
        allocator.free(c.workspace_item_id);
        allocator.free(c.name);
        allocator.free(c.description);
        allocator.free(c.created_at);
    }
    allocator.free(cols);
}

/// List the columns of a kanban workspace item in `position` order.
///
/// Returns an owned slice; the caller must release it with
/// `freeColumns(allocator, slice)`. If the item has no columns, the
/// slice has length 0 (not an error).
pub fn listColumns(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]KanbanColumn {
    var q = try db.query(allocator,
        \\SELECT kc.id, kc.workspace_item_id, kc.name, kc.description, kc.position, COALESCE(kc.created_at, '')
        \\FROM kanban_columns kc
        \\WHERE kc.workspace_item_id = ?
        \\ORDER BY kc.position ASC
    , &.{workspace_item_id});
    defer q.deinit();

    var rows = std.ArrayList(KanbanColumn).empty;
    errdefer {
        for (rows.items) |c| {
            allocator.free(c.id);
            allocator.free(c.workspace_item_id);
            allocator.free(c.name);
            allocator.free(c.description);
            allocator.free(c.created_at);
        }
        rows.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_item_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .description = try allocator.dupe(u8, row.values[3]),
            .position = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
            .created_at = try allocator.dupe(u8, row.values[5]),
        });
    }
    return rows.toOwnedSlice(allocator);
}

/// Generate a unique column id of the form `col_<unix_nanoseconds>`.
///
/// Uses libc `clock_gettime` for nanosecond precision so that 3
/// `addColumn` calls inside `seedDefaultColumns` (which all run in
/// the same millisecond during tests) get distinct IDs. The
/// project-wide convention for ID generation is the same nanosecond
/// timestamp — see `workspace_items_create.zig:generateItemId`
/// which uses `std.Io.Clock.now(.real, io)`.
///
/// `std.time.timestamp()` was removed in Zig 0.16 — see the project
/// memory `zig-0.16-crypto-time-stdlib-removals.md`.
/// Uses a monotonic atomic counter XORed with a stack address for
/// uniqueness. The counter alone is sufficient (it's process-global
/// and monotonically increasing), but the address mix-in adds
/// additional entropy if a future refactor ever threads the same
/// allocator across threads. Avoids `std.c.clock_gettime` which
/// doesn't compile on Windows (clockid_t is void there).
fn generateColumnId(allocator: std.mem.Allocator) ![]u8 {
    const counter = nextColumnIdCounter();
    var entropy: [8]u8 = undefined;
    const stack_addr: u64 = @intCast(@intFromPtr(&entropy));
    const mixed: u64 = counter ^ stack_addr;
    std.mem.writeInt(u64, &entropy, mixed, .little);
    var hex: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (entropy, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }
    return std.fmt.allocPrint(allocator, "col_{s}", .{&hex});
}

/// Process-global monotonic counter for `generateColumnId`. Every call
/// to `generateColumnId` advances the counter by one, guaranteeing a
/// unique ID per call regardless of how fast the caller invokes it.
/// Uses `std.atomic.Value(u64)` for lock-free thread safety (the
/// counter may be touched from any worker thread that creates a
/// kanban column).
var column_id_counter: std.atomic.Value(u64) = .init(0);

fn nextColumnIdCounter() u64 {
    return column_id_counter.fetchAdd(1, .seq_cst);
}

/// Append a new column to the end of the kanban's column sequence.
///
/// `position` may be `null` (default) to place the column at
/// `MAX(kanban_columns.position) + 1` for this item, or a concrete
/// integer to insert at a specific position (the renumbering
/// behavior of an explicit position is the caller's responsibility
/// — see `reorderColumn`).
///
/// `description` is the free-text "meaning" of the column (Migration
/// 053); pass `""` for "no description" (the column will render with
/// the "Add a description…" placeholder in the frontend).
///
/// Returns a freshly-allocated id of the form `col_<unix_seconds>`.
/// Caller owns the returned slice.
pub fn addColumn(
    allocator: std.mem.Allocator,
    db: nalarcore.DbOrTx,
    workspace_item_id: []const u8,
    name: []const u8,
    description: []const u8,
    position: ?i64,
) ![]u8 {
    const id = try generateColumnId(allocator);
    defer allocator.free(id);

    const pos = position orelse blk: {
        var q = try db.query(allocator,
            \\SELECT COALESCE(MAX(kc.position), -1) + 1
            \\FROM kanban_columns kc
            \\WHERE kc.workspace_item_id = ?
        , &.{workspace_item_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NoMaxPosition;
        defer row.deinit(allocator);
        break :blk try std.fmt.parseInt(i64, row.values[0], 10);
    };

    const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{pos});
    defer allocator.free(pos_str);

    // SQLiteBackend.exec binds `arg.len == 0` as SQL NULL (see
    // `ruangsql src/sqlite/Sqlite.zig (github.com/ginwa123/ruangsql):73-74`). The
    // `description` column is `NOT NULL DEFAULT ''`, so binding
    // NULL would violate the constraint. Omit the column from the
    // INSERT when description is empty so the DEFAULT '' applies.
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
    return allocator.dupe(u8, id);
}

/// Seed the canonical 3-column default flow `todo / in progress /
/// done` for a freshly-created kanban item. Idempotent only at the
/// "called once at item-creation time" granularity — re-calling on a
/// board that already has columns appends a second set.
///
/// All seeded columns get `description = ""` (the "no description"
/// sentinel). Users can set per-column descriptions via the Kanban
/// Settings dialog (Chunk 3).
pub fn seedDefaultColumns(
    allocator: std.mem.Allocator,
    db: nalarcore.DbOrTx,
    workspace_item_id: []const u8,
) !void {
    // Each `addColumn` returns an owned id slice that the caller MUST
    // free. `seedDefaultColumns` doesn't surface the ids (the caller
    // doesn't need them), so we free each one immediately after.
    {
        const id = try addColumn(allocator, db, workspace_item_id, "todo", "", 0);
        defer allocator.free(id);
    }
    {
        const id = try addColumn(allocator, db, workspace_item_id, "in progress", "", 1);
        defer allocator.free(id);
    }
    {
        const id = try addColumn(allocator, db, workspace_item_id, "done", "", 2);
        defer allocator.free(id);
    }
}

/// Update an existing column. `name` and `description` are both
/// optional; at least one must be non-null (validated at the HTTP
/// handler layer). Field semantics:
///   - `null` → "leave the field unchanged" (absent from PATCH body)
///   - `""` (empty string) → "clear the field" (the user explicitly
///      sent `""` to remove the existing value)
///   - non-empty → "set the field to this value"
///
/// These three states are distinct: the frontend's Settings UI sends
/// an explicit `""` when the user clears the description (saves an
/// empty textarea), distinct from omitting the field entirely (the
/// user only wants to rename, not touch the description).
///
/// `workspace_item_id` is accepted for symmetry with the other
/// column-mutators but the WHERE clause matches only on `id`
/// (column ids are globally unique within the schema).
pub fn updateColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: []const u8,
    name: ?[]const u8,
    description: ?[]const u8,
) !void {
    _ = workspace_item_id;
    if (name) |n| {
        try db.exec(allocator,
            "UPDATE kanban_columns SET name = ? WHERE id = ?",
            &.{ n, column_id });
    }
    // Three distinct states for `description`:
    //   null     → don't change (field absent from PATCH body)
    //   ""       → clear (user explicitly sent empty string)
    //   non-empty → overwrite with the new value
    // The "clear" branch binds the empty literal directly in SQL
    // rather than passing `""` as a parameter, because
    // SqliteBackend.exec treats `arg.len == 0` as SQL NULL (see
    // project memory `sqlite-backend-empty-slice-binds-as-null.md`)
    // which would violate the NOT NULL constraint on
    // `kanban_columns.description`.
    if (description) |d| {
        if (d.len > 0) {
            try db.exec(allocator,
                "UPDATE kanban_columns SET description = ? WHERE id = ?",
                &.{ d, column_id });
        } else {
            try db.exec(allocator,
                "UPDATE kanban_columns SET description = '' WHERE id = ?",
                &.{column_id});
        }
    }
}

/// Delete a column. Tasks that were assigned to this column have
/// their `kanban_column_id` set to `NULL` (so they show in the
/// "Unassigned" group of the folder-list view); the tasks themselves
/// are NOT removed.
///
/// IMPORTANT: callers MUST first verify the column has no tasks via
/// `countTasksInColumn` before calling this. The model layer does
/// NOT enforce the "no orphan tasks" invariant — that decision
/// belongs at the HTTP handler layer (see
/// `kanban_columns_delete.zig`), which surfaces it as a 409 Conflict
/// so the frontend can prompt the user to move the tasks first.
pub fn deleteColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: []const u8,
) !void {
    _ = workspace_item_id;
    // Tasks that were assigned to this column have their `kanban`
    // card row DELETED (so the LEFT JOIN in list queries surfaces
    // them as "task exists but is unassigned" — the same observable
    // wire format as before). The tasks themselves
    // (`workspace_item_tasks`) are NOT removed.
    //
    // IMPORTANT: this codebase does NOT enable `PRAGMA foreign_keys`
    // (FK enforcement is off — see
    // `src/ai_workflow/tui/design_model_delete_parent_test.zig:8`),
    // so the `kanban.workspace_item_task_id ON DELETE CASCADE` from workspace_item_tasks
    // works in reverse ONLY if we explicitly DELETE here. We DELETE
    // the kanban rows before the kanban_columns row to preserve the
    // "task unassigned" semantics.
    //
    // Note: we DELETE the kanban row (not NULL the column FK) because
    // `kanban.kanban_column_id` is NOT NULL — a kanban row exists IFF
    // its task is assigned to a specific column.
    try db.exec(allocator,
        "DELETE FROM kanban WHERE kanban_column_id = ?",
        &.{column_id});
    try db.exec(allocator,
        "DELETE FROM kanban_columns WHERE id = ?",
        &.{column_id});
}

/// Replace the target kanban's columns with copies of the source
/// kanban's columns. The target's existing columns are deleted (tasks
/// assigned to them get `kanban_column_id = NULL` per the existing
/// `deleteColumn` contract); the source's columns are then inserted
/// on the target with positions 0..N-1 matching the source's order.
///
/// Used by the `POST /kanban/copy_spec_from` endpoint (Chunk 2 of
/// the copy-kanban plan) in "Replace" mode. The destructive delete
/// + insert sequence is performed in three SQL statements without an
/// explicit transaction wrapper — SQLite auto-commits each statement,
/// and the consequence of an interrupted copy (target emptied, source
/// not yet copied) is recoverable by re-running the endpoint.
///
/// Self-copy (`source_item_id == target_item_id`) is undefined:
/// the function deletes the target's columns (which IS the source)
/// before copying from the (now-empty) source. The HTTP handler
/// rejects this case before reaching the helper.
///
/// Both `workspace_item_id` arguments are validated by the caller
/// (HTTP handler); this helper assumes they exist in the
/// `workspace_items` table.
///
/// SQL convention: every inner-table reference is aliased (`kc`) per
/// the project memory `nalar-sql-alias-tables.md`.
pub fn replaceColumnsWith(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    source_item_id: []const u8,
    target_item_id: []const u8,
) !void {
    // Step 1: Fetch the source's columns (ordered by position ASC).
    const source_cols = try listColumns(allocator, db, source_item_id);
    defer freeColumns(allocator, source_cols);

    // Step 2: Delete every existing column on the target. We collect
    // the ids first (so we don't hold the query open while doing
    // per-id DELETEs that would race against the open cursor), then
    // call `deleteColumn` per id so the task-unassign semantics stay
    // consistent with the per-column delete handler.
    //
    // Ownership: `target_column_ids` is built with an `errdefer` for
    // OOM-during-append safety, then `toOwnedSlice` transfers the
    // heap-owned ids to `owned_ids` BEFORE the per-id DELETE loop.
    // This pattern (mirrors `listColumns` above) makes the errdefer a
    // no-op on the success path and isolates the cleanup: a failure
    // inside `deleteColumn` (e.g. the source item being deleted under
    // us) surfaces the error while `owned_ids` is still freed exactly
    // once by the defer.
    {
        var existing = try db.query(allocator,
            \\SELECT kc.id FROM kanban_columns kc WHERE kc.workspace_item_id = ?
        , &.{target_item_id});
        defer existing.deinit();
        var target_column_ids = std.ArrayList([]u8).empty;
        errdefer {
            for (target_column_ids.items) |id| allocator.free(id);
            target_column_ids.deinit(allocator);
        }
        while (try existing.next()) |row| {
            defer row.deinit(allocator);
            try target_column_ids.append(allocator, try allocator.dupe(u8, row.values[0]));
        }
        const owned_ids = try target_column_ids.toOwnedSlice(allocator);
        defer {
            for (owned_ids) |id| allocator.free(id);
            allocator.free(owned_ids);
        }
        for (owned_ids) |col_id| {
            try deleteColumn(allocator, db, target_item_id, col_id);
        }
    }

    // Step 3: Copy each source column to the target with position 0..N-1.
    for (source_cols, 0..) |col, idx| {
        // addColumn returns a heap-owned id that the caller MUST
        // free. We don't surface the id (the caller doesn't need
        // it) so we free it immediately — mirrors `seedDefaultColumns`.
        const new_id = try addColumn(
            allocator,
            .{ .db = db },
            target_item_id,
            col.name,
            col.description,
            @intCast(idx),
        );
        defer allocator.free(new_id);
    }
}

/// Append copies of the source kanban's columns to the end of the
/// target kanban's column sequence. Unlike `replaceColumnsWith`, this
/// does NOT delete the target's existing columns — they keep their
/// positions 0..M-1 and the source's columns are appended at
/// M, M+1, M+2, … (where M is the target's MAX(position) + 1).
///
/// Used by the `POST /kanban/copy_spec_from` endpoint in "Append"
/// mode. Like `replaceColumnsWith`, no transaction wrapper is used
/// — SQLite auto-commits each INSERT. The append-only semantics mean
/// partial failures leave a few extra columns at the end of the
/// target, which the user can manually delete.
///
/// SQL convention: every inner-table reference is aliased (`kc`) per
/// the project memory `nalar-sql-alias-tables.md`.
pub fn appendColumnsFrom(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    source_item_id: []const u8,
    target_item_id: []const u8,
) !void {
    const source_cols = try listColumns(allocator, db, source_item_id);
    defer freeColumns(allocator, source_cols);

    // Compute MAX(position) + 1 across the target's columns. The
    // COALESCE handles the empty-target case (no rows → MAX is
    // NULL → -1 → start_pos 0).
    var start_pos: i64 = 0;
    {
        var q = try db.query(allocator,
            \\
            \\SELECT COALESCE(MAX(kc.position), -1) + 1
            \\FROM kanban_columns kc
            \\WHERE kc.workspace_item_id = ?
        , &.{target_item_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            start_pos = std.fmt.parseInt(i64, row.values[0], 10) catch 0;
        }
    }

    for (source_cols, 0..) |col, offset| {
        // addColumn returns a heap-owned id that the caller MUST
        // free (mirrors seedDefaultColumns + replaceColumnsWith).
        const new_id = try addColumn(
            allocator,
            .{ .db = db },
            target_item_id,
            col.name,
            col.description,
            start_pos + @as(i64, @intCast(offset)),
        );
        defer allocator.free(new_id);
    }
}

/// Count how many tasks currently reference `column_id` as their
/// `kanban_column_id`. Used by `kanbanColumnsDeleteHandler` to refuse
/// deletion when the column still has tasks (the user must move them
/// to another column first).
///
/// Returns `0` when the column has no tasks. Note: this is just a
/// `COUNT(*)` against the FK column — there is no separate
/// existence check for the column row itself, so a non-existent
/// column id also returns `0` (caller doesn't need to distinguish
/// "no tasks" from "no such column" for the delete-gate purpose).
///
/// SQL convention: every inner-table reference is aliased (`t`) per
/// the project memory `nalar-sql-alias-tables.md`.
pub fn countTasksInColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    column_id: []const u8,
) !u32 {
    // After Migration 072, "tasks in this column" is read from `kanban`
    // (the 1:1 join table where a row exists iff a task is assigned to
    // a kanban column). A row in `kanban` with `kanban_column_id = X`
    // is equivalent to the legacy `workspace_item_tasks.kanban_column_id
    // = X` query.
    var q = try db.query(allocator,
        \\SELECT COUNT(*) FROM kanban k WHERE k.kanban_column_id = ?
    , &.{column_id});
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(allocator);
    return try std.fmt.parseInt(u32, row.values[0], 10);
}

/// Reorder a column to a new position with list-insertion
/// semantics: the column is removed from its current slot and
/// re-inserted at `new_position`, shifting the OTHER columns
/// around it. The result is a dense 0..N-1 sequence that reflects
/// the user's intended visual order.
///
/// Algorithm (4 SQL statements; the simplest correct implementation
/// that handles both forward and backward moves symmetrically):
///
///   1. Temporarily park the moved column at a sentinel position
///      (well above any realistic column count) so it's sorted to
///      the end and won't disturb the renumber in step 2.
///   2. Compact the OTHER columns into a dense 0..N-2 sequence
///      ranked by their current position (with ties broken by id
///      for determinism).
///   3. Shift every OTHER column at position >= new_position up by
///      1, opening a slot for the moved column.
///   4. Place the moved column at new_position.
///
/// Worked examples (initial state dense 0..N-1):
///
///   start [todo=0, ip=1, rev=2, done=3], reorder("done", 0)
///     step 1 → [todo=0, ip=1, rev=2, done=∞]
///     step 2 → [todo=0, ip=1, rev=2, done=∞]
///     step 3 → [todo=1, ip=2, rev=3, done=∞]  (everyone else shifts up)
///     step 4 → [done=0, todo=1, ip=2, rev=3]   ✓
///
///   start [done=0, todo=1, ip=2, rev=3], reorder("todo", 2)
///     step 1 → [done=0, todo=∞, ip=2, rev=3]
///     step 2 → [done=0, ip=1, rev=2, todo=∞]
///     step 3 → [done=0, ip=1, rev=3, todo=∞]  (only rev at >=2 shifts)
///     step 4 → [done=0, ip=1, todo=2, rev=3]   ✓
///
/// The sentinel value 1_000_000 is well above any realistic
/// per-item column count (the product spec caps custom columns at
/// a handful; typical N ≤ 10).
///
/// SQL convention: every inner-table reference is aliased (`kc2`)
/// per the project memory `nalar-sql-alias-tables.md`. The outer
/// UPDATE target is NOT aliased — SQLite disallows aliases on the
/// UPDATE target.
pub fn reorderColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: []const u8,
    new_position: i64,
) !void {
    // Sentinel: large enough to park the moved column past every
    // realistic position without overflow concerns (SQLite stores
    // INTEGER as i64).
    const SENTINEL: i64 = 1_000_000;
    const sentinel_str = try std.fmt.allocPrint(allocator, "{d}", .{SENTINEL});
    defer allocator.free(sentinel_str);
    const new_pos_str = try std.fmt.allocPrint(allocator, "{d}", .{new_position});
    defer allocator.free(new_pos_str);

    // Step 1: park the moved column at the sentinel.
    try db.exec(allocator,
        "UPDATE kanban_columns SET position = ? WHERE id = ?",
        &.{ sentinel_str, column_id });

    // Step 2: compact the OTHER columns (everyone except the
    // parked one) into 0..N-2 by current position order. The
    // subquery counts siblings at position < this column's
    // position, with id-tiebreak for deterministic ordering of
    // siblings that share a position (which can happen if a prior
    // renumber was skipped).
    try db.exec(allocator,
        \\UPDATE kanban_columns
        \\SET position = (
        \\    SELECT COUNT(*) FROM kanban_columns kc2
        \\    WHERE kc2.workspace_item_id = kanban_columns.workspace_item_id
        \\      AND kc2.id != ?
        \\      AND (kc2.position < kanban_columns.position
        \\          OR (kc2.position = kanban_columns.position AND kc2.id < kanban_columns.id))
        \\)
        \\WHERE workspace_item_id = ? AND id != ?
    , &.{ column_id, workspace_item_id, column_id });

    // Step 3: shift every OTHER column at position >= new_position
    // up by 1, opening a slot for the moved column.
    try db.exec(allocator,
        \\UPDATE kanban_columns
        \\SET position = position + 1
        \\WHERE workspace_item_id = ? AND id != ? AND position >= ?
    , &.{ workspace_item_id, column_id, new_pos_str });

    // Step 4: place the moved column at new_position.
    try db.exec(allocator,
        "UPDATE kanban_columns SET position = ? WHERE id = ?",
        &.{ new_pos_str, column_id });
}

/// Move a task from its current column to `target_column_id` at
/// `target_position`. Shifts the other tasks in the target column
/// that are at >= target_position down by one; if the column
/// changed, compacts the source column's remaining tasks back into
/// 0..N-1.
///
/// Note: uses the correlated-subquery approach for compacting the
/// source column (see step 4 below) — it's one atomic UPDATE per
/// call which is fine for v1 boards (typical N ≤ 50 tasks).
pub fn moveTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    task_id: []const u8,
    target_column_id: []const u8,
    target_position: i64,
) !void {
    _ = workspace_item_id;

    // Step 1: read the current column for the task (needed to renumber
    // the source column after the move). After Migration 072, the
    // task's current column lives in the `kanban` join table, not on
    // `workspace_item_tasks` directly.
    const current_col_id = blk: {
        var q = try db.query(allocator,
            "SELECT COALESCE(k.kanban_column_id, '') FROM kanban k WHERE k.workspace_item_task_id = ?",
            &.{task_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.TaskNotFound;
        defer row.deinit(allocator);
        break :blk try allocator.dupe(u8, row.values[0]);
    };
    defer allocator.free(current_col_id);

    const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{target_position});
    defer allocator.free(pos_str);

    // Step 2: move the task to the target column at the target position.
    // INSERT OR REPLACE handles both first-move (no kanban row yet) and
    // subsequent-move (existing kanban row updated) atomically: the
    // PRIMARY KEY collision on re-inserts triggers a delete-then-insert
    // which is the same observable behavior as the legacy UPDATE.
    try db.exec(allocator,
        "INSERT OR REPLACE INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES (?, ?, ?)",
        &.{ task_id, target_column_id, pos_str });

    // Step 3: shift other tasks in the target column that are at >= target_position.
    try db.exec(allocator,
        \\UPDATE kanban
        \\SET kanban_position = kanban_position + 1
        \\WHERE kanban_column_id = ? AND workspace_item_task_id != ? AND kanban_position >= ?
    , &.{ target_column_id, task_id, pos_str });

    // Step 4: if the column changed, compact the source column.
    if (!std.mem.eql(u8, current_col_id, target_column_id)) {
        try db.exec(allocator,
            \\UPDATE kanban
            \\SET kanban_position = (
            \\    SELECT COUNT(*) FROM kanban k2
            \\    WHERE k2.kanban_column_id = kanban.kanban_column_id
            \\        AND (k2.kanban_position < kanban.kanban_position
            \\            OR (k2.kanban_position = kanban.kanban_position AND k2.workspace_item_task_id <= kanban.workspace_item_task_id))
            \\) - 1
            \\WHERE kanban_column_id = ?
        , &.{current_col_id});
    }
}


// ─── Inline tests (formerly kanban_model_test.zig) ───────────────────────
// Unit tests for the kanban column CRUD data layer. Inlined here per
// the agentic_loop/ convention.

const testing = std.testing;


/// Open a fresh in-memory sqlite DB with the bare minimum tables the
/// kanban_model functions need: `workspace_items` (for the FK
/// reference) and `kanban_columns` (the table being queried). Tests
/// that exercise task movement additionally `CREATE TABLE
/// workspace_item_tasks` after calling this helper.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    return .{ .db = db, .threaded = threaded };
}

// ─── Test: listColumns orders by position ────────────────────────────────

test "listColumns returns columns ordered by position" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'in progress', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c3', 'item_1', 'done', 2)", &.{});

    const cols = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("c1", cols[0].id);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("c2", cols[1].id);
    try testing.expectEqualStrings("c3", cols[2].id);
}

// ─── Test: addColumn appends at MAX(position) + 1 when position=null ─────

test "addColumn inserts at end of position sequence" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});

    const new_id = try addColumn(alloc, .{ .db = &s.db }, "item_1", "review", "", null);
    defer alloc.free(new_id);
    // Generated id is `col_<unix_nanoseconds>` — just sanity-check the prefix.
    try testing.expect(std.mem.startsWith(u8, new_id, "col_"));

    const cols = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 2), cols.len);
    try testing.expectEqualStrings("review", cols[1].name);
    try testing.expectEqual(@as(i64, 1), cols[1].position);
}

// ─── Test: seedDefaultColumns produces the 3-column canonical flow ───────

test "seedDefaultColumns creates todo, in progress, done" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});

    try seedDefaultColumns(alloc, .{ .db = &s.db }, "item_1");

    const cols = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
}

// ─── Test: renameColumn updates the column's name ────────────────────────

test "renameColumn updates name" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});

    try updateColumn(alloc, &s.db, "item_1", "c1", "backlog", null);

    const cols = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 1), cols.len);
    try testing.expectEqualStrings("backlog", cols[0].name);
}

// ─── Test: deleteColumn nulls out the kanban row's kanban_column_id ──────

test "deleteColumn nulls out the kanban row's kanban_column_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    // Mirror the post-Migration-072 schema: workspace_item_tasks has
    // no kanban_column_id/kanban_position columns; the kanban table
    // holds the 1:1 task-to-board placement with FKs.
    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0,
        \\    FOREIGN KEY (workspace_item_task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE,
        \\    FOREIGN KEY (kanban_column_id) REFERENCES kanban_columns(id) ON DELETE SET NULL)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c1', 0)", &.{});

    try deleteColumn(alloc, &s.db, "item_1", "c1");

    // Column row is gone
    const cols = try listColumns(alloc, &s.db, "item_1");
    defer freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 0), cols.len);

    // The task itself still exists (kanban FK CASCADE doesn't drop the task)
    {
        var q = try s.db.query(alloc,
            "SELECT t.id FROM workspace_item_tasks t WHERE t.id = 't1'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NoTask;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("t1", row.values[0]);
    }

    // The kanban card row is DELETED (no kanban row = "task exists but
    // is unassigned" — the list-query LEFT JOIN surfaces this as
    // kanban_column_id = NULL in the wire format).
    {
        var q = try s.db.query(alloc,
            "SELECT COUNT(*) FROM kanban k WHERE k.workspace_item_task_id = 't1'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NoCount;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("0", row.values[0]);
    }
}

// ─── Test: countTasksInColumn counts only tasks in that column ───────────

test "countTasksInColumn returns the number of tasks assigned to the column" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Post-Migration-072 schema: workspace_item_tasks has no
    // kanban_column_id/kanban_position; the kanban join table holds
    // the 1:1 task-to-board placement.
    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    // Three tasks in c1, one in c2, one unassigned (no kanban row).
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES " ++
            "('t1', 'A', 'item_1'), ('t2', 'B', 'item_1'), ('t3', 'C', 'item_1'), " ++
            "('t4', 'D', 'item_1'), ('t5', 'E', 'item_1')",
        &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES " ++
            "('t1', 'c1', 0), ('t2', 'c1', 1), ('t3', 'c1', 2), ('t4', 'c2', 0)",
        &.{});

    try testing.expectEqual(@as(u32, 3), try countTasksInColumn(alloc, &s.db, "c1"));
    try testing.expectEqual(@as(u32, 1), try countTasksInColumn(alloc, &s.db, "c2"));
}

test "countTasksInColumn returns 0 when no tasks reference the column" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c1', 0)", &.{});

    // c2 exists in kanban_columns but has no tasks — count is 0, not
    // an error. (The delete-handler treats 0 as "safe to delete".)
    try testing.expectEqual(@as(u32, 0), try countTasksInColumn(alloc, &s.db, "c2"));
    // Non-existent column id also returns 0 (no rows match the FK).
    try testing.expectEqual(@as(u32, 0), try countTasksInColumn(alloc, &s.db, "col_does_not_exist"));
}

test "countTasksInColumn returns 0 when the kanban table is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});

    try testing.expectEqual(@as(u32, 0), try countTasksInColumn(alloc, &s.db, "any_column"));
}

// ─── Test: moveTask changes column and renumbers positions ──────────────

test "moveTask changes column and renumbers positions" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    // Post-Migration-072 schema
    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'done', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t2', 'B', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t3', 'C', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c1', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t2', 'c1', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t3', 'c2', 0)", &.{});

    // Move t1 (was c1 pos 0) to c2 pos 0
    try moveTask(alloc, &s.db, "item_1", "t1", "c2", 0);

    var q = try s.db.query(alloc,
        "SELECT k.workspace_item_task_id, k.kanban_column_id, k.kanban_position " ++
        "FROM kanban k " ++
        "WHERE k.workspace_item_task_id IN ('t1', 't2', 't3') ORDER BY k.workspace_item_task_id", &.{});
    defer q.deinit();
    // t1 → c2, pos 0
    const r1 = (try q.next()) orelse return error.NoTask;
    defer r1.deinit(alloc);
    try testing.expectEqualStrings("t1", r1.values[0]);
    try testing.expectEqualStrings("c2", r1.values[1]);
    try testing.expectEqualStrings("0", r1.values[2]);
    // t2 → c1, pos 0 (compacted up after t1 left)
    const r2 = (try q.next()) orelse return error.NoTask;
    defer r2.deinit(alloc);
    try testing.expectEqualStrings("t2", r2.values[0]);
    try testing.expectEqualStrings("c1", r2.values[1]);
    try testing.expectEqualStrings("0", r2.values[2]);
    // t3 → c2, pos 1 (shifted down after t1 arrived)
    const r3 = (try q.next()) orelse return error.NoTask;
    defer r3.deinit(alloc);
    try testing.expectEqualStrings("t3", r3.values[0]);
    try testing.expectEqualStrings("c2", r3.values[1]);
    try testing.expectEqualStrings("1", r3.values[2]);
}

// ─── Test: reorderColumn shifts siblings to keep positions dense ─────────
//
// Mirrors the two-step drag scenario from the plan:
//   - move "done" from slot 3 to slot 0  →  [done, todo, ip, rev]
//   - move "todo" from slot 1 to slot 2  →  [done, ip, todo, rev]
//
// Verifies that the 4-statement algorithm in `reorderColumn` (park
// the moved column at a sentinel, compact the others, shift the
// ones >= new_position, place the moved column) produces the
// expected visual order in both cases.
test "reorderColumn shifts siblings to a dense sequence matching the user's intent" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    // Seed 4 columns at dense positions 0..3. The names (todo, ip,
    // rev, done) and ids (c1..c4) don't match — the renumber uses
    // CURRENT position order, not lex-id, so the id labels are
    // arbitrary.
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'in_progress', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c3', 'item_1', 'review', 2)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c4', 'item_1', 'done', 3)", &.{});

    // Helper: read columns in current position order, returning
    // their (id, position) pairs.
    const ColRow = struct {
        id: []const u8,
        position: i64,
    };
    const readByPos = struct {
        fn run(a: std.mem.Allocator, db: *sqlite.SqliteBackend, item_id: []const u8) ![]ColRow {
            var q = try db.query(a,
                \\SELECT kc.id, kc.position
                \\FROM kanban_columns kc
                \\WHERE kc.workspace_item_id = ?
                \\ORDER BY kc.position ASC
            , &.{item_id});
            defer q.deinit();
            var rows = std.ArrayList(ColRow).empty;
            errdefer rows.deinit(a);
            while (try q.next()) |row| {
                defer row.deinit(a);
                try rows.append(a, .{
                    .id = try a.dupe(u8, row.values[0]),
                    .position = try std.fmt.parseInt(i64, row.values[1], 10),
                });
            }
            return rows.toOwnedSlice(a);
        }
    }.run;

    // Step 1: drag "done" (c4) from slot 3 to slot 0.
    try reorderColumn(alloc, &s.db, "item_1", "c4", 0);

    const after1 = try readByPos(alloc, &s.db, "item_1");
    defer {
        for (after1) |r| alloc.free(r.id);
        alloc.free(after1);
    }
    try testing.expectEqual(@as(usize, 4), after1.len);
    // Expected: done (c4) at 0, then todo (c1) at 1, ip (c2) at 2,
    // rev (c3) at 3 — the OTHERS shifted right by 1.
    try testing.expectEqualStrings("c4", after1[0].id);
    try testing.expectEqual(@as(i64, 0), after1[0].position);
    try testing.expectEqualStrings("c1", after1[1].id);
    try testing.expectEqual(@as(i64, 1), after1[1].position);
    try testing.expectEqualStrings("c2", after1[2].id);
    try testing.expectEqual(@as(i64, 2), after1[2].position);
    try testing.expectEqualStrings("c3", after1[3].id);
    try testing.expectEqual(@as(i64, 3), after1[3].position);

    // Step 2: drag "todo" (c1) from slot 1 to slot 2.
    try reorderColumn(alloc, &s.db, "item_1", "c1", 2);

    const after2 = try readByPos(alloc, &s.db, "item_1");
    defer {
        for (after2) |r| alloc.free(r.id);
        alloc.free(after2);
    }
    try testing.expectEqual(@as(usize, 4), after2.len);
    // Expected: done (c4) at 0, ip (c2) at 1, todo (c1) at 2,
    // rev (c3) at 3.
    try testing.expectEqualStrings("c4", after2[0].id);
    try testing.expectEqual(@as(i64, 0), after2[0].position);
    try testing.expectEqualStrings("c2", after2[1].id);
    try testing.expectEqual(@as(i64, 1), after2[1].position);
    try testing.expectEqualStrings("c1", after2[2].id);
    try testing.expectEqual(@as(i64, 2), after2[2].position);
    try testing.expectEqualStrings("c3", after2[3].id);
    try testing.expectEqual(@as(i64, 3), after2[3].position);
}


// ─── Inline tests (formerly kanban_model_test_description.zig) ──────────
// Unit tests for kanban column description. Inlined here.

fn setupDbDescription() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Migration 051 needs `workspace_items` (FK target) and
    // `workspace_item_tasks` (ALTER TABLE target). Mirror
    // migration_051_test.zig's setup; 051 assumes these tables
    // exist (the production migrator walks 001 → 051 in order, so
    // by the time 051 runs they are already there).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    const migration = nalarcore.migrations_mod.migration;
    try migration.Migration051AddKanban.up(&db, alloc);
    try migration.Migration053AddKanbanColumnDescription.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "addColumn writes description to the new row" {
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "in_review", "Awaiting code review", 0,
    );
    defer alloc.free(id);

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 1), cols.len);
    try testing.expectEqualStrings("in_review", cols[0].name);
    try testing.expectEqualStrings("Awaiting code review", cols[0].description);
}

test "updateColumn with only description leaves name unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "todo", "Not started", 0,
    );
    defer alloc.free(id);

    try updateColumn(
        alloc, &ctx.db, "wi_1", id, null, "Not started yet — work in queue",
    );

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("Not started yet — work in queue", cols[0].description);
}

test "updateColumn with only name leaves description unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "todo", "Not started", 0,
    );
    defer alloc.free(id);

    try updateColumn(alloc, &ctx.db, "wi_1", id, "backlog", null);

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("backlog", cols[0].name);
    try testing.expectEqualStrings("Not started", cols[0].description);
}

test "updateColumn with both name and description writes both" {
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "todo", "old", 0,
    );
    defer alloc.free(id);

    try updateColumn(
        alloc, &ctx.db, "wi_1", id, "backlog", "Newly triaged items",
    );

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("backlog", cols[0].name);
    try testing.expectEqualStrings("Newly triaged items", cols[0].description);
}

test "seedDefaultColumns writes empty descriptions" {
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDefaultColumns(alloc, .{ .db = &ctx.db }, "wi_1");

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    for (cols) |c| {
        try testing.expectEqualStrings("", c.description);
    }
}

test "updateColumn with empty-string description clears existing description" {
    // Regression test for the 2026-06-30 PATCH bug:
    //   curl -X PATCH .../kanban/columns/col_X \
    //        --data-raw '{"name":"in_review_planning","description":""}'
    // The old code treated `""` identically to `null` (both
    // skipped the UPDATE), so the existing description stayed in
    // the DB and the response echoed the old value back. After the
    // fix, `""` clears the description while `null` leaves it
    // unchanged — three distinct states.
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "in_review", "Awaiting code review", 0,
    );
    defer alloc.free(id);

    // Sanity check: description was set on creation.
    {
        const cols = try listColumns(alloc, &ctx.db, "wi_1");
        defer freeColumns(alloc, cols);
        try testing.expectEqualStrings("Awaiting code review", cols[0].description);
    }

    // PATCH with description="" — must CLEAR the description (not
    // skip the UPDATE). The name stays unchanged.
    try updateColumn(
        alloc, &ctx.db, "wi_1", id, null, "",
    );

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("in_review", cols[0].name);
    try testing.expectEqualStrings("", cols[0].description);
}

test "updateColumn with null description leaves existing description unchanged" {
    // Companion to the empty-clear test above. Verifies that
    // `null` still means "leave unchanged" (field absent from
    // PATCH body), distinct from `""` (clear). If this test ever
    // starts clearing too, the branch logic has regressed.
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "todo", "Not started", 0,
    );
    defer alloc.free(id);

    // PATCH with name only — description must NOT be cleared.
    try updateColumn(alloc, &ctx.db, "wi_1", id, "backlog", null);

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("backlog", cols[0].name);
    try testing.expectEqualStrings("Not started", cols[0].description);
}

test "updateColumn with both empty description and new name writes both" {
    // Mixed PATCH: rename the column AND clear its description in
    // the same call. Verifies the empty-description branch and the
    // name branch compose correctly without one stomping the other.
    // Mirrors the user's exact curl from the bug report.
    const alloc = testing.allocator;
    var ctx = try setupDbDescription();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_1", "in_review", "Awaiting code review", 0,
    );
    defer alloc.free(id);

    try updateColumn(
        alloc, &ctx.db, "wi_1", id, "in_review_planning", "",
    );

    const cols = try listColumns(alloc, &ctx.db, "wi_1");
    defer freeColumns(alloc, cols);

    try testing.expectEqualStrings("in_review_planning", cols[0].name);
    try testing.expectEqualStrings("", cols[0].description);
}


// ─── Inline tests (formerly kanban_copy_spec_test.zig) ───────────────────
// In-memory round-trip tests for replaceColumnsWith + appendColumnsFrom.
// Inlined here.

fn setupDbCopy() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Migration 051 needs `workspace_items` (FK target) and
    // `workspace_item_tasks` (ALTER TABLE target). Mirror the
    // existing `kanban_model_test_description.zig` setup: the
    // production migrator walks 001 → 051 in order, so by the time
    // 051 runs these tables are already there.
    //
    // After Migration 072 (extract kanban table plan, 2026-08-15),
    // the kanban_column_id + kanban_position columns are no longer on
    // workspace_item_tasks — they live on the new `kanban` join table.
    // We apply 051 + 053 (legacy column-add) + 072 (legacy column-drop
    // + kanban table create) to get the post-Migration-072 schema.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    const migration = @import("nalarcore").migrations_mod.migration;
    try migration.Migration051AddKanban.up(&db, alloc);
    try migration.Migration053AddKanbanColumnDescription.up(&db, alloc);
    try migration.Migration072ExtractKanbanTable.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Seed a column and immediately free the returned id. Tests that
/// only care about the column existing (not its id) use this helper
/// to avoid the boilerplate of `const id = try addColumn(...);
/// defer alloc.free(id);` at every call site — and to prevent leaks
/// when `_ = try addColumn(...)` is used naively (the returned id
/// is heap-allocated and the caller owns it; see `zig`
/// `addColumn` line 196).
fn seedColumn(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    name: []const u8,
    description: []const u8,
    position: i64,
) !void {
    const id = try addColumn(
        alloc,
        .{ .db = db },
        workspace_item_id,
        name,
        description,
        position,
    );
    defer alloc.free(id);
}

test "replaceColumnsWith deletes target columns and copies source columns" {
    const alloc = testing.allocator;
    var ctx = try setupDbCopy();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed source kanban with 3 columns.
    try seedColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_src", "in progress", "", 1);
    try seedColumn(alloc, &ctx.db, "wi_src", "done", "", 2);

    // Seed target kanban with 1 column (different from source).
    try seedColumn(alloc, &ctx.db, "wi_tgt", "legacy", "", 0);

    try replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try listColumns(alloc, &ctx.db, "wi_tgt");
    defer freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
    // Positions are 0, 1, 2 (dense).
    try testing.expectEqual(@as(i64, 0), cols[0].position);
    try testing.expectEqual(@as(i64, 1), cols[1].position);
    try testing.expectEqual(@as(i64, 2), cols[2].position);
}

test "replaceColumnsWith preserves description field" {
    const alloc = testing.allocator;
    var ctx = try setupDbCopy();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "in_review", "Awaiting code review", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "old", "Old desc", 0);

    try replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try listColumns(alloc, &ctx.db, "wi_tgt");
    defer freeColumns(alloc, cols);
    try testing.expectEqualStrings("Awaiting code review", cols[0].description);
}

test "appendColumnsFrom adds source columns to target without deleting" {
    const alloc = testing.allocator;
    var ctx = try setupDbCopy();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "review", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_src", "merged", "", 1);

    try seedColumn(alloc, &ctx.db, "wi_tgt", "todo", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "in progress", "", 1);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "done", "", 2);

    try appendColumnsFrom(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try listColumns(alloc, &ctx.db, "wi_tgt");
    defer freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 5), cols.len);
    // Original target columns kept their positions 0,1,2.
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
    // Source columns appended at MAX+1, MAX+2 (positions 3, 4).
    try testing.expectEqualStrings("review", cols[3].name);
    try testing.expectEqualStrings("merged", cols[4].name);
    try testing.expectEqual(@as(i64, 3), cols[3].position);
    try testing.expectEqual(@as(i64, 4), cols[4].position);
}

test "replaceColumnsWith unassigns tasks on the deleted target columns" {
    const alloc = testing.allocator;
    var ctx = try setupDbCopy();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    // Capture the legacy column id before the replace — we'll verify
    // the task referencing it was unassigned. addColumn returns a
    // heap-allocated id that we must free (see seedColumn's doc on
    // why an explicit `defer alloc.free` is needed for the returned
    // id to avoid a leak).
    const legacy_id = try addColumn(alloc, .{ .db = &ctx.db }, "wi_tgt", "legacy", "", 0);
    defer alloc.free(legacy_id);

    // Create a task assigned to the target's "legacy" column. After
    // Migration 072, the task→column mapping lives in the `kanban`
    // join table (1:1 row per assigned task), not on
    // workspace_item_tasks directly.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id) VALUES ('task_1', 'wi_tgt')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('task_1', ?, 0)",
        &.{legacy_id});

    try replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    // Verify the kanban card row was DELETED when the column was
    // replaced (FK CASCADE simulation — PRAGMA foreign_keys is off in
    // this codebase, so we explicitly DELETE the kanban rows in
    // deleteColumn). The task itself is NOT removed.
    {
        var q = try ctx.db.query(alloc,
            "SELECT COUNT(*) FROM kanban k WHERE k.workspace_item_task_id = 'task_1'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("0", row.values[0]);
    }

    // Sanity: the task row still exists.
    {
        var q2 = try ctx.db.query(alloc,
            "SELECT t.id FROM workspace_item_tasks t WHERE t.id = 'task_1'",
            &.{});
        defer q2.deinit();
        const r2 = (try q2.next()) orelse return error.RowMissing;
        defer r2.deinit(alloc);
        try testing.expectEqualStrings("task_1", r2.values[0]);
    }
}

test "replaceColumnsWith with empty source empties the target" {
    const alloc = testing.allocator;
    var ctx = try setupDbCopy();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "x", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "y", "", 1);

    // Manually empty the source.
    try ctx.db.exec(alloc, "DELETE FROM kanban_columns WHERE workspace_item_id = 'wi_src'", &.{});

    try replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try listColumns(alloc, &ctx.db, "wi_tgt");
    defer freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 0), cols.len);
}

// Static regression test: `replaceColumnsWith` must use the
// `toOwnedSlice` ownership-transfer pattern (mirrors `listColumns`'s
// errdefer-only model) so the errdefer+defer double-cleanup of
// `target_column_ids` cannot fire on the error path. The pre-fix
// code at zig:346-360 had BOTH `errdefer` AND `defer`
// blocks freeing the same `target_column_ids.items`. Under Zig's LIFO
// defer semantics, the second cleanup fires first → iterates freed
// memory → heap-use-after-free + double `deinit` panic. This test
// reads the model file source and asserts the `toOwnedSlice`
// ownership-transfer call is present inside the function body.
test "replaceColumnsWith uses toOwnedSlice pattern (no double-free)" {
    const allocator = testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/agentic_loop/kanban_model.zig",
        allocator,
        .limited(256 * 1024),
    );
    defer allocator.free(source);

    // Locate the function body: from `pub fn replaceColumnsWith`
    // to the next `\npub fn ` (or EOF).
    const fn_start_marker = "pub fn replaceColumnsWith";
    const fn_start = std.mem.indexOf(u8, source, fn_start_marker) orelse {
        std.debug.print(
            "\n!! replaceColumnsWith function not found in kanban_model.zig !!\n",
            .{},
        );
        return error.FnNotFound;
    };
    var fn_end: usize = source.len;
    if (std.mem.indexOfPos(u8, source, fn_start + fn_start_marker.len, "\npub fn ")) |p| {
        fn_end = p;
    }
    const fn_body = source[fn_start..fn_end];

    // The contract: the function must transfer ownership of the
    // target_column_ids list to an owned slice via `toOwnedSlice`
    // BEFORE the deleteColumn loop, so the errdefer becomes a no-op
    // on the success path. Without this, the LIFO defer+errdefer
    // double-cleanup triggers a heap-use-after-free.
    if (std.mem.indexOf(u8, fn_body, "toOwnedSlice") == null) {
        std.debug.print(
            "\n!! replaceColumnsWith does not use toOwnedSlice !!\n" ++
                "   The double-free bug at zig:346-360 is back.\n" ++
                "   Fix pattern (mirror listColumns at zig:70-95):\n" ++
                "     1. Keep the existing `errdefer` block (handles OOM mid-loop).\n" ++
                "     2. After the rows are appended, transfer ownership:\n" ++
                "          const owned_ids = try target_column_ids.toOwnedSlice(allocator);\n" ++
                "          defer for (owned_ids) |id| allocator.free(id);\n" ++
                "     3. Iterate `owned_ids` (not `target_column_ids.items`) in the loop.\n" ++
                "   See docs/superpowers/plans/2026-07-04-copy-kanban-spec.md.\n",
            .{},
        );
        return error.DoubleFreeReintroduced;
    }
}
