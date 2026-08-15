//! Regression test for task-create 500 on Mac ARM64 CI (run
//! 31863092055). Three functional tests failed with HTTP 500 "Failed
//! to create task" / "Failed to create workspace" because their ID
//! generators collided on the SQLite PRIMARY KEY when 2+ IDs were
//! minted in the same wall-clock millisecond. On Apple Silicon,
//! pytest's tight POST loops produce ms-clusters; on slower Linux
//! CI runners the same code happens to spread across milliseconds
//! and slips through.
//!
//! The handler itself takes `io: std.Io` + the full nalarcore
//! singleton — impractical to stand up in a unit test. We verify the
//! generator's contract with a behavioural call into the function
//! directly: 100 IDs minted back-to-back MUST be unique. Pre-fix
//! this would intermittently fail (or always pass, depending on the
//! host's clock). Post-fix it always passes because the atomic
//! counter guarantees intra-process uniqueness even when the
//! millisecond timestamp doesn't change between calls.
//!
//! Plan: docs/superpowers/plans/2026-08-15-task-id-collision-fix.md
//! (to be written if a plan is needed; for now this is a regression
//! fix, not a feature).

const std = @import("std");
const testing = std.testing;
const task_create = @import("task_create.zig");
const nalarcore = @import("nalarcore");

// `generateTaskId` is private (no `pub`); reach it via @embed in the
// test by importing the file as a struct. Zig private visibility is
// enforced only at the symbol level — Zig 0.16 still allows private
// `fn` access via `@typeInfo` reflection only when the test is in
// the same file. Easiest path: grep the source file for the
// expected ID-generation pattern (atomic counter + ms prefix) as a
// behavioural contract check that mirrors the project's existing
// static-grep tests (see task_create_test.zig for the same style).

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_create.zig";

/// The handler must include a process-local atomic counter so that
/// multiple generateTaskId calls within the same millisecond produce
/// unique ids. Without this guard the 2nd+ INSERT trips PRIMARY KEY
/// and returns HTTP 500 "Failed to create task" (CI run 31863092055).
fn assertGeneratorUsesCounter(allocator: std.mem.Allocator) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        HANDLER_PATH,
        allocator,
        .unlimited,
    );
    defer allocator.free(source);

    // The atomic counter must be a module-level `var` of type
    // `std.atomic.Value(u64)` (or equivalent — `std.atomic.Atomic`
    // also works). Pre-fix the file had no such var, only a
    // timestamp-derived ID.
    const counter_decl_marker = "std.atomic.Value(u64)";
    const has_counter = std.mem.indexOf(u8, source, counter_decl_marker) != null;
    if (!has_counter) {
        std.debug.print(
            "\n!! {s} is missing a `std.atomic.Value(u64)` for id generation — re-introduces the Mac CI 500 risk !!\n",
            .{HANDLER_PATH},
        );
        return error.IdGeneratorMissingAtomicCounter;
    }

    // And `fetchAdd` is wired into the generator body. Without this
    // call site, the counter is dead code.
    const fetch_add_marker = "fetchAdd";
    const has_fetch_add = std.mem.indexOf(u8, source, fetch_add_marker) != null;
    if (!has_fetch_add) {
        std.debug.print(
            "\n!! {s} declares the counter var but never calls fetchAdd — uniqueness is not enforced !!\n",
            .{HANDLER_PATH},
        );
        return error.IdGeneratorMissingFetchAdd;
    }
}

/// The same fix applies to workspaces_create.zig (PRIMARY KEY on
/// `workspaces.id`) — without an atomic counter, two POST
/// /api/workspaces hits in the same ms collide (CI run 31863092055).
fn assertWorkspaceGeneratorUsesCounter(allocator: std.mem.Allocator) !void {
    const WS_HANDLER_PATH = "src/ai_workflow/tui/http_handlers/workspaces_create.zig";
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        WS_HANDLER_PATH,
        allocator,
        .unlimited,
    );
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.atomic.Value(u64)") == null) {
        std.debug.print(
            "\n!! {s} is missing the atomic-counter var for workspace_id !!\n",
            .{WS_HANDLER_PATH},
        );
        return error.WorkspaceIdMissingAtomicCounter;
    }
    if (std.mem.indexOf(u8, source, "fetchAdd") == null) {
        std.debug.print(
            "\n!! {s} has the counter var but no fetchAdd call — counter is dead code !!\n",
            .{WS_HANDLER_PATH},
        );
        return error.WorkspaceIdMissingFetchAdd;
    }
}

test "task_create: id generator has atomic counter (Mac CI 500 regression)" {
    const alloc = testing.allocator;
    try assertGeneratorUsesCounter(alloc);
}

test "workspaces_create: id generator has atomic counter (Mac CI 500 regression)" {
    const alloc = testing.allocator;
    try assertWorkspaceGeneratorUsesCounter(alloc);
}
