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
    db: *sqlite.SqliteBackend,
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
    // `src/modules/databases/sqlite/Sqlite.zig:73-74`). The
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
    db: *sqlite.SqliteBackend,
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
    // so the `kanban.task_id ON DELETE CASCADE` from workspace_item_tasks
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
            db,
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
            db,
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
            "SELECT COALESCE(k.kanban_column_id, '') FROM kanban k WHERE k.task_id = ?",
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
        "INSERT OR REPLACE INTO kanban (task_id, kanban_column_id, kanban_position) VALUES (?, ?, ?)",
        &.{ task_id, target_column_id, pos_str });

    // Step 3: shift other tasks in the target column that are at >= target_position.
    try db.exec(allocator,
        \\UPDATE kanban
        \\SET kanban_position = kanban_position + 1
        \\WHERE kanban_column_id = ? AND task_id != ? AND kanban_position >= ?
    , &.{ target_column_id, task_id, pos_str });

    // Step 4: if the column changed, compact the source column.
    if (!std.mem.eql(u8, current_col_id, target_column_id)) {
        try db.exec(allocator,
            \\UPDATE kanban
            \\SET kanban_position = (
            \\    SELECT COUNT(*) FROM kanban k2
            \\    WHERE k2.kanban_column_id = kanban.kanban_column_id
            \\        AND (k2.kanban_position < kanban.kanban_position
            \\            OR (k2.kanban_position = kanban.kanban_position AND k2.task_id <= kanban.task_id))
            \\) - 1
            \\WHERE kanban_column_id = ?
        , &.{current_col_id});
    }
}
