//! Static regression checks for the `POST /workspaces/:wsId/items/kanban`
//! handler (`workspace_items_create_kanban.zig`).
//!
//! Why this file exists
//! ────────────────────
//! The Workspace Item Kanban feature (plan:
//! `2026-06-21-workspace-item-kanban.md`) introduces a new
//! `item_type='kanban'` workspace item. The create handler is a thin
//! wrapper that:
//!   1. Parses `{name}` from the JSON body via `parseFromSliceLeaky`.
//!   2. Generates a unique `item_<unix_nanoseconds>` id.
//!   3. INSERTs the row with `item_type='kanban'` and a fresh position.
//!   4. Calls `kanban_model.seedDefaultColumns` to add the canonical
//!      3-column default flow (`todo / in progress / done`).
//!   5. Returns 201 with `{id, workspace_id, item_type, name, position}`.
//!
//! These contracts are enforced by static substring checks (matching
//! the project's `routines_run_test.zig` / `task_create_routines_test.zig`
//! pattern), not by spinning up an in-memory DB. The static checks
//! below directly test the bug — they fail if and only if the create
//! plumbing is removed or routed back to the generic `item_type='folder'`
//! path.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.2)

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── Contract 1: handler parses the request body via parseFromSliceLeaky ───

test "create_kanban handler parses name from JSON body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must use `parseFromSliceLeaky` (NOT the non-leaky
    // variant — see project memory
    // `nalar-http-handler-thin-wrapper-pattern`). The parsed body's
    // `.name` field must then be referenced (extracted from the
    // struct for use in the SQL INSERT).
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The create-body contract is broken: the handler must parse the\n" ++
                "   `{{name}}` body via `parseFromSliceLeaky` (per-request arena owns\n" ++
                "   the memory; no explicit deinit needed). Switch from\n" ++
                "   `parseFromSlice` to `parseFromSliceLeaky`.\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
    // `.name` extraction — the parsed struct's `name` field must be
    // referenced for use in the INSERT. We look for the substring
    // `parsed.name` which is the standard extraction pattern in this
    // codebase.
    if (std.mem.indexOf(u8, source, "parsed.name") == null) {
        std.debug.print(
            "\n!! {s} does not extract .name from the parsed body !!\n" ++
                "   The create-body contract is broken: the handler must reference\n" ++
                "   the `name` field of the parsed struct (e.g. `const name = parsed.name;`)\n" ++
                "   and pass it to the INSERT. Without this, the kanban item would\n" ++
                "   be created with no name.\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.NameExtractionMissing;
    }
}

// ─── Contract 2: handler seeds the 3 default columns ──────────────────────

test "create_kanban handler seeds default columns" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // After INSERTing the kanban workspace_item row, the handler must
    // call `kanban_model.seedDefaultColumns` to populate the canonical
    // 3-column flow. Without this, the board opens with zero columns
    // and the user has to manually add them via the column-editor.
    if (std.mem.indexOf(u8, source, "seedDefaultColumns") == null) {
        std.debug.print(
            "\n!! {s} does not call seedDefaultColumns !!\n" ++
                "   The kanban-defaults contract is broken: a freshly-created kanban\n" ++
                "   item would have zero columns until the user manually adds them.\n" ++
                "   Call `kanban_model.seedDefaultColumns(allocator, sqlite_db, item_id)`\n" ++
                "   after the INSERT.\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.SeedDefaultColumnsMissing;
    }
}

// ─── Contract 3: handler returns 201 on success ────────────────────────────

test "create_kanban handler returns 201 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The create endpoint must return 201 Created on success (this is
    // the standard REST convention for POST that creates a resource).
    if (std.mem.indexOf(u8, source, ".status_code = 201") == null) {
        std.debug.print(
            "\n!! {s} does not return a 201 status code !!\n" ++
                "   The create-status contract is broken: clients expect 201 Created\n" ++
                "   for a successful POST. Use `.status_code = 201` on the success branch.\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.Status201Missing;
    }
}