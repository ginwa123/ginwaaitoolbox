//! Static regression checks for the `std.json.Stringify.valueAlloc`
//! response pattern in `task_create.zig`.
//!
//! Why this file exists
//! ────────────────────
//! The `tasksCreateHandler` previously built its 201 JSON response via
//! three nested `std.fmt.allocPrint(allocator, ...)` calls (one per
//! task_type branch). The `.standard` branch nested ANOTHER
//! `std.fmt.allocPrint` inside the args tuple of the outer call:
//!
//!     try std.fmt.allocPrint(allocator, "...{s}...", .{
//!         ...
//!         if (r.kanban_column_id) |cid|
//!             try std.fmt.allocPrint(allocator, "...{s}...", .{...})
//!         else
//!             "...",
//!     });
//!
//! When the outer `Allocator.Writer` grows its buffer via
//! `ensureTotalCapacityPrecise`, it `rawFree`s the old chunk back to
//! the per-request arena. The inner `allocPrint`'s `rawAlloc` may
//! then be served from the just-freed memory, leaving the inner
//! result slice inside the outer's NEXT buffer chunk. When the outer
//! `print` later does `@memcpy(w.buffer[w.end..], inner_buf)`, the
//! slices overlap and Zig 0.16's runtime safety check aborts with:
//!
//!     thread N panic: @memcpy arguments alias
//!         at /usr/local/lib/zig/std/Io/Writer.zig:535
//!
//! This is a user-reported crash (2026-07-01, see the long-running
//! nalar on port 8081). The fix is to drop the hand-rolled JSON and
//! use `std.json.Stringify.valueAlloc` with a typed struct, which
//! (a) never nests `allocPrint` calls and (b) handles JSON escaping
//! for user-provided strings like `r.name`.
//!
//! These contracts are enforced by static substring checks, matching
//! the project's `task_create_routines_test.zig` / `tasks_create_kanban_test.zig`
//! pattern.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_create.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Contract 1: response uses valueAlloc, not nested allocPrint ───────

test "tasks_create 201 response uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must use std.json.Stringify.valueAlloc for all 3
    // task_type branches (.routine, .memory, .standard). Count the
    // occurrences: 3 branches × 1 valueAlloc each = 3 minimum. Allow
    // ≥ 3 to give room for future cleanup of the doc-comment mention
    // without breaking this test.
    const value_alloc_count = countOccurrences(source, "std.json.Stringify.valueAlloc");
    if (value_alloc_count < 3) {
        std.debug.print(
            "\n!! {s} response does not use std.json.Stringify.valueAlloc !!\n" ++
                "   Found {d} occurrences of `std.json.Stringify.valueAlloc`, need >= 3.\n" ++
                "   The handler has 3 task_type branches (.routine, .memory, .standard)\n" ++
                "   and each must serialize via valueAlloc. The typed-struct + valueAlloc\n" ++
                "   pattern is required to avoid the @memcpy aliasing crash and to\n" ++
                "   escape JSON-special characters in user-provided fields.\n",
            .{ HANDLER_PATH, value_alloc_count },
        );
        return error.ResponseUsesHandRolledAllocPrint;
    }
}

test "tasks_create 201 response has typed RoutineResponse / MemoryResponse / StandardResponse structs" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must define one typed struct per branch — valueAlloc
    // serializes a typed struct to JSON (it cannot serialize ad-hoc
    // format-string output).
    const required_structs = [_][]const u8{
        "RoutineResponse",
        "MemoryResponse",
        "StandardResponse",
    };
    for (required_structs) |name| {
        if (std.mem.indexOf(u8, source, name) == null) {
            std.debug.print(
                "\n!! {s} is missing the `{s}` typed response struct !!\n" ++
                    "   valueAlloc requires a typed struct to serialize; ad-hoc format-string\n" ++
                    "   output is not supported. Add `const {s} = struct {{ ... }};` near\n" ++
                    "   the other response structs.\n",
                .{ HANDLER_PATH, name, name },
            );
            return error.TypedResponseStructMissing;
        }
    }
}

// ─── Contract 2: response has no nested std.fmt.allocPrint ────────────

test "tasks_create does NOT nest std.fmt.allocPrint inside another allocPrint" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The bug pattern: a `try std.fmt.allocPrint(...)` whose result is
    // returned as an arg of an OUTER `std.fmt.allocPrint(...)`. When
    // both share the per-request arena, the inner result slice can
    // alias with the outer's grown buffer and trigger Zig 0.16's
    // `@memcpy arguments alias` runtime panic.
    //
    // Detection heuristic: look for `try std.fmt.allocPrint` inside
    // the response switch block (the `switch (outcome)` in
    // `tasksCreateHandler`). The use case layer (createRoutineTask /
    // createStandardTask) also calls allocPrint, but those results
    // are stored in a returned struct field, not fed back into another
    // allocPrint, so they don't have the aliasing risk.
    //
    // We grep the whole file for `try std.fmt.allocPrint` — if there
    // are 0 occurrences (the response is built via valueAlloc
    // exclusively), the bug pattern is gone.
    const nested_alloc_print = countOccurrences(source, "try std.fmt.allocPrint");
    if (nested_alloc_print > 0) {
        std.debug.print(
            "\n!! {s} still contains `try std.fmt.allocPrint` !!\n" ++
                "   Found {d} occurrences. The handler must build responses via typed\n" ++
                "   structs + std.json.Stringify.valueAlloc, NEVER via std.fmt.allocPrint\n" ++
                "   chained with another allocPrint sharing the per-request arena. That\n" ++
                "   pattern triggers a Zig 0.16 runtime panic:\n" ++
                "     thread N panic: @memcpy arguments alias\n" ++
                "       at /usr/local/lib/zig/std/Io/Writer.zig:535\n" ++
                "   The user-reported crash on 2026-07-01 was triggered by exactly this\n" ++
                "   pattern in the .standard branch. Replace all `try std.fmt.allocPrint`\n" ++
                "   response builders with `std.json.Stringify.valueAlloc` + a typed\n" ++
                "   struct.\n",
            .{ HANDLER_PATH, nested_alloc_print },
        );
        return error.NestedAllocPrintPresent;
    }
}

// ─── helpers ───────────────────────────────────────────────────────────

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, idx, needle)) |pos| {
        count += 1;
        idx = pos + needle.len;
    }
    return count;
}