const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 066 — Add `design_pages.workspace_item_task_id` foreign
/// key to bind each design page 1:1 to its `workspace_item_tasks`
/// chat-session row.
///
/// ## Why this migration exists
///
/// Today, the per-page chat lookup in `AppLayout.handleDesignOpenChat`
/// keys off a string pattern (`"Design Chat: <page_name>"`). That
/// approach has three failure modes (renames break the binding, name
/// uniqueness is not enforced, deleting a page leaves an orphan
/// chat task with no cascade). Replacing the name-based lookup with
/// a direct FK makes the binding row-level, lets the DB enforce the
/// 1:1 invariant via a UNIQUE index, and lets ON DELETE CASCADE on
/// `workspace_item_tasks(id)` clean up the chat task automatically
/// when the page is deleted (Tasks 2 + 7 in the plan will wire the
/// cascade at the model layer).
///
/// ## What this does
///
/// 1. Add `workspace_item_task_id TEXT` to `design_pages` (nullable —
///    we backfill existing rows in step 3, and fresh INSERTs from
///    `design_model.setDesignPage` populate it at create time).
/// 2. Create a UNIQUE index on the column to enforce the 1:1 invariant
///    (one task → at most one page; SQLite uses this index for the
///    UNIQUE check AND for the FK lookup, no second index needed).
/// 3. **Backfill** every existing `design_pages` row whose
///    `workspace_item_task_id IS NULL` with a fresh
///    `workspace_item_tasks` row. The new task is named
///    `"Design Chat: <page_name>"` — matching the canonical name so
///    any legacy name-pattern code (or future migrations) still
///    resolves correctly. The new task id is `task_<unix_nanoseconds>`
///    using the same `helpers.unixTimestampNanos()` scheme as
///    `design_items_create.zig:100`.
///
/// ## FK constraint intentionally omitted (decision)
///
/// SQLite does NOT support `ALTER TABLE … ADD CONSTRAINT FK …`. The
/// canonical alternatives — triggers (`BEFORE INSERT` + `ON DELETE
/// CASCADE`) or recreate-table — both add complexity that's
/// out of scope for v1. The UNIQUE index + application-level
/// validation in `design_model.setDesignPage` is the second line of
/// defense; revisit if migration friction appears. See plan Task 1
/// decision bullet "Decision: skip the FK for now."
///
/// Plan: docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md
pub const Migration066AddDesignPageTaskFk = struct {
    pub const version: u32 = 66;
    pub const name = "add_design_page_task_fk";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Add the column. Nullable — backfilled below; new
        //    INSERTs from `design_model.setDesignPage` populate it
        //    at create time.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "design_pages",
            "workspace_item_task_id",
            // name + type — `addColumnIfMissing` uses this verbatim as
            // `ALTER TABLE {table} ADD COLUMN {definition}`, so omitting
            // the column name would create a column literally named
            // "TEXT". See memory `addColumnIfMissing-requires-name-type`.
            "workspace_item_task_id TEXT",
        );

        // 2. UNIQUE index for the 1:1 invariant. `IF NOT EXISTS`
        //    keeps the migration idempotent on re-run.
        try db.exec(
            allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_design_pages_workspace_item_task_id " ++
                "ON design_pages(workspace_item_task_id)",
            &[_][]const u8{},
        );

        // 3. Backfill existing pages. For each row whose
        //    `workspace_item_task_id IS NULL`, INSERT a fresh
        //    `workspace_item_tasks` row named
        //    `"Design Chat: <page_name>"` and UPDATE the page with
        //    the new task id.
        //
        //    We iterate in Zig (not a single SQL CTE) because the
        //    task id is `task_<unix_nanoseconds>` and SQLite has no
        //    native nanosecond-timestamp primitive. Computing the
        //    id in Zig + dynamic SQL with `std.fmt.bufPrint` is the
        //    cleanest path. Only pages with NULL task_id are
        //    touched (re-run safety: after the first run, every row
        //    is populated; the WHERE clause is a no-op on re-runs).
        var q = try db.query(
            allocator,
            \\SELECT dp.id, dp.workspace_item_id,
            \\       COALESCE(dp.name, '') AS name
            \\FROM design_pages dp
            \\WHERE dp.workspace_item_task_id IS NULL
        , &[_][]const u8{});
        defer q.deinit();

        // Last task id's nanosecond value — used to guarantee strictly
        // increasing ids across the batch (Windows FILETIME granularity
        // can repeat back-to-back ticks). Declared OUTSIDE the loop so
        // it persists across iterations.
        var last_task_ns: i128 = 0;

        while (try q.next()) |row| {
            defer row.deinit(allocator);
            const page_id = row.values[0];
            const item_id = row.values[1];
            // Defensive normalization: empty page name → "untitled"
            // (we never want a literal "Design Chat: " with trailing
            // space). COALESCEd above means empty here == the row had
            // no name. Real page names get `"Design Chat: <name>"`.
            const page_name_raw = row.values[2];
            const full_task_name = if (std.mem.eql(u8, page_name_raw, ""))
                "Design Chat: untitled"
            else
                try std.fmt.allocPrint(
                    allocator,
                    "Design Chat: {s}",
                    .{page_name_raw},
                );
            defer if (!std.mem.eql(u8, page_name_raw, "")) allocator.free(full_task_name);

            // Generate a unique `task_<unix_nanoseconds>` id. The
            // nanosecond scheme matches design_items_create.zig:100 —
            // collisions on a multi-page backfill are essentially
            // impossible (each call is a separate `std.c.clock_gettime`
            // syscall yielding a fresh value).
            //
            // Windows caveat: `GetSystemTimeAsFileTime` has a coarse
            // effective granularity (0.5–15.6 ms depending on the
            // timer coalescing), so back-to-back calls in this loop
            // CAN return the same tick → duplicate PRIMARY KEY.
            // Guard: if the fresh timestamp is <= the previous one,
            // use prev + 1 so every id in the batch strictly
            // increases and stays unique.
            var task_id_buf: [64]u8 = undefined;
            const now_ns = helpers.unixTimestampNanos();
            const unique_ns: i128 = if (now_ns <= last_task_ns) last_task_ns + 1 else now_ns;
            last_task_ns = unique_ns;
            const task_id = std.fmt.bufPrint(
                task_id_buf[0..],
                "task_{d}",
                .{unique_ns},
            ) catch return error.BufferTooSmall;

            // Dynamic INSERT + UPDATE per page. We split into TWO exec calls
            // because `db.exec` (via `sqlite3_prepare_v2`) only
            // compiles the FIRST statement in a multi-statement
            // string — it stops at the first `;`. Single exec per
            // statement keeps both commits atomic on the connection
            // (each runs in autocommit, but the migration is a one-shot
            // so partial-commit risk is acceptable). Empty-string
            // description is a SQL '' literal so it doesn't trip
            // `SqliteBackend.exec` empty-slice-binds-as-NULL — see
            // memory `sqlite-backend-empty-slice-binds-as-null`.
            const insert_sql = try std.fmt.allocPrint(
                allocator,
                "INSERT INTO workspace_item_tasks " ++
                    "(id, name, workspace_item_id, task_type, description) " ++
                    "VALUES ('{s}', '{s}', '{s}', 'standard', '')",
                .{ task_id, full_task_name, item_id },
            );
            defer allocator.free(insert_sql);
            try db.exec(allocator, insert_sql, &[_][]const u8{});

            const update_sql = try std.fmt.allocPrint(
                allocator,
                "UPDATE design_pages SET workspace_item_task_id = '{s}' " ++
                    "WHERE id = '{s}'",
                .{ task_id, page_id },
            );
            defer allocator.free(update_sql);
            try db.exec(allocator, update_sql, &[_][]const u8{});
        }
    }
};
