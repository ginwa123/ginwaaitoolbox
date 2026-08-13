//! Behavioural contract test for the kanban-task / session-name match fix.
//!
//! Pre-fix, `createStandardTask` inserted the linked sessions row with
//! `name = task.id` (the literal task id). Post-fix, it must insert
//! `name = task.name` (the user-facing title).
//!
//! The handler's `createStandardTask` requires `io: std.Io` and the
//! full nalarcore singleton context, which is impractical to stand up
//! in a unit test. We verify the contract with a focused static check
//! on the bind-values list shape: it must read `task.id, task.name, flag`,
//! NOT `task.id, task.id, flag`.
//!
//! Plan: docs/superpowers/plans/2026-08-13-kanban-task-session-name-match.md
//! Task 2 / Step 2.1.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_create.zig";

/// Read a source file from disk, normalize CRLF to LF so Windows-checked-
/// out files match the test expectation. Relative to the project root
/// (which is the cwd when `zig build test` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "createStandardTask binds sessions.name = task.name (not task.id)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Locate the unattended-mode sessions INSERT — it's the only place
    // in createStandardTask that writes to the sessions table.
    const sessions_insert_marker =
        \\INSERT OR IGNORE INTO sessions (id, name, status, is_auto_retry_until_stop)
    ;
    const sql_idx = std.mem.indexOf(u8, source, sessions_insert_marker) orelse {
        std.debug.print("\n!! {s} is missing the unattended-mode sessions INSERT !!\n", .{HANDLER_PATH});
        return error.SessionsInsertMissing;
    };

    // After the SQL string the handler binds its values inline. The
    // pre-fix shape was `&[_][]const u8{ task.id, task.id, normalized }`
    // (BUG); post-fix it must be `&[_][]const u8{ task.id, task.name, normalized }`.
    // Find the bind list that follows the SQL string and inspect the
    // second element.
    const bind_list_marker = "&[_][]const u8{ task.id, ";
    const search_from = sql_idx + sessions_insert_marker.len;
    const bind_idx = std.mem.indexOfPos(u8, source, search_from, bind_list_marker) orelse {
        std.debug.print("\n!! {s} sessions INSERT bind list is missing the expected shape !!\n", .{HANDLER_PATH});
        return error.BindListMissing;
    };

    // The second element starts right after the marker and runs until
    // the next comma. Trim incidental whitespace before comparing.
    const after_marker = bind_idx + bind_list_marker.len;
    // The list literal ends with `}` somewhere after; scan for the
    // first comma, but only up to a safe upper bound (the bind list
    // is at most ~50 chars). Use indexOfPos with the slice's bounds
    // — `source` is the full file, not a view, so the result must
    // be relative to after_marker.
    const slice_end = @min(after_marker + 64, source.len);
    const comma_offset = std.mem.indexOfPos(u8, source, after_marker, ",") orelse {
        std.debug.print("\n!! {s} bind list not parseable — no comma within {} bytes !!\n", .{ HANDLER_PATH, slice_end - after_marker });
        return error.BindListUnparseable;
    };
    if (comma_offset > slice_end) {
        std.debug.print("\n!! {s} comma too far away (idx={d}, window_end={d}) !!\n", .{ HANDLER_PATH, comma_offset, slice_end });
        return error.BindListUnparseable;
    }
    const raw_second = source[after_marker..comma_offset];
    const second_elem = std.mem.trim(u8, raw_second, " \t\n\r");

    if (!std.mem.eql(u8, second_elem, "task.name")) {
        std.debug.print(
            "\n!! {s} sessions INSERT second bind is '{s}', expected 'task.name' !!\n",
            .{ HANDLER_PATH, second_elem },
        );
        return error.SessionNameBindBug;
    }
}