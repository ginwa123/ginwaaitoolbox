//! Static regression checks for the empty-name validation in both
//! `POST /api/workspaces/:wsId/items` (folder create) and
//! `POST /api/workspaces/:wsId/items/kanban` (kanban create).
//!
//! Why this file exists
//! ────────────────────
//! User reported an "empty workspace item with a red border" in the
//! sidebar after attempting to create a workspace item. Reproduced:
//! a `POST` with `{"name":""}` was accepted with HTTP 201 and an empty
//! `name` field persisted. The frontend AddItemDialog disabled the
//! submit button when `name.trim()` was empty, so the bug was
//! reachable only via non-UI paths (scripts, agent runs, future
//! code that forgets the frontend trim) — but the persistence of the
//! empty row rendered as a name-less, focused-looking row.
//!
//! Three contracts are asserted here via static substring checks
//! (matching `workspace_items_create_kanban_test.zig`'s pattern):
//!
//!   1. `workspace_items_create.zig` declares an `EmptyName` error
//!      variant (so a whitespace-only name can be distinguished from
//!      a missing-field name without text-matching the body).
//!   2. Both handlers trim leading/trailing ASCII whitespace from the
//!      `name` field before INSERTing, so `"  My Project  "` stores
//!      `"My Project"` (no surrounding whitespace).
//!   3. Both handlers reject empty-after-trim names. The folder
//!      handler maps the rejection to a 400 with body `{"error":"name required"}`;
//!      the kanban handler maps to its own 400 with the same body
//!      string ("name is required").
//!
//! Plan: docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const FOLDER_HANDLER_PATH = "src/ai_workflow/tui/http_handlers/workspace_items_create.zig";
const KANBAN_HANDLER_PATH = "src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test` runs). Mirrors
/// `workspace_items_create_kanban_test.zig:readSource`.
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

// ─── Contract 1: folder handler declares `EmptyName` error variant ────────

test "folder create handler declares EmptyName error variant" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FOLDER_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must declare a distinct `EmptyName` variant in its
    // error set so the trimmed-empty case is identifiable (the
    // frontend distinguishes it from a missing field by checking
    // the response body's `error` string).
    if (std.mem.indexOf(u8, source, "EmptyName") == null) {
        std.debug.print(
            "\n!! {s} does not declare EmptyName error variant !!\n" ++
                "   The folder-create handler must distinguish 'name field missing'\n" ++
                "   (MissingName) from 'name present but empty after trim' (EmptyName)\n" ++
                "   so the 400 response surfaces the correct diagnostic. Add\n" ++
                "   `EmptyName,` to the WorkspaceItemsCreateError error set.\n" ++
                "   See docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.\n",
            .{FOLDER_HANDLER_PATH},
        );
        return error.EmptyNameVariantMissing;
    }
}

// ─── Contract 2: folder handler trims the name before INSERT ──────────────

test "folder create handler trims leading/trailing whitespace from name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FOLDER_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `std.mem.trim` on the parsed name slice
    // before INSERTing. Without this, leading/trailing whitespace
    // round-trips through the DB and breaks the sidebar's
    // `.truncate` rendering (a 0-visible-character row followed by
    // a long whitespace gap looks empty in the screenshot even
    // after Task 4's fallback rendering kicks in).
    if (std.mem.indexOf(u8, source, "std.mem.trim") == null) {
        std.debug.print(
            "\n!! {s} does not call std.mem.trim on the name !!\n" ++
                "   The folder-create handler must call `std.mem.trim(u8, name, ...)`\n" ++
                "   (or equivalent) before the INSERT to strip leading/trailing\n" ++
                "   whitespace. Without trimming, '  My Project  ' stores as\n" ++
                "   '  My Project  ' in the DB and renders oddly in the sidebar.\n" ++
                "   See docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.\n",
            .{FOLDER_HANDLER_PATH},
        );
        return error.TrimCallMissing;
    }
}

// ─── Contract 3: folder handler returns 400 + "name required" for EmptyName ─

test "folder create handler maps EmptyName to 400 with 'name required' body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FOLDER_HANDLER_PATH);
    defer allocator.free(source);

    // The handler's error switch must handle EmptyName with status
    // 400 and message "name required". Without this arm, the
    // useCase's EmptyName error would fall through to the generic
    // catch and be serialized as the default error name (e.g.
    // `"error":"EmptyName"`) which the frontend can't render as a
    // user-friendly message.
    const has_status_arm = std.mem.indexOf(u8, source, "error.EmptyName") != null;
    const has_message_arm = std.mem.indexOf(u8, source, "=> \"name required\"") != null;
    if (!has_status_arm or !has_message_arm) {
        std.debug.print(
            "\n!! {s} does not map EmptyName to 400 / 'name required' !!\n" ++
                "   The folder-create handler's catch block must include both:\n" ++
                "     - error.EmptyName  in the status switch (-> 400)\n" ++
                "     - error.EmptyName => \"name required\"  in the message switch\n" ++
                "   Without these, the frontend shows the raw error name (e.g.\n" ++
                "   'EmptyName') instead of a user-friendly message.\n" ++
                "   See docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.\n",
            .{FOLDER_HANDLER_PATH},
        );
        return error.EmptyNameMappingMissing;
    }
}

// ─── Contract 4: kanban handler trims + rejects whitespace-only names ─────

test "kanban create handler trims whitespace and rejects empty-after-trim" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, KANBAN_HANDLER_PATH);
    defer allocator.free(source);

    // The kanban handler must call std.mem.trim AND check the
    // trimmed length. Without the trim, a request of `{"name":"   "}`
    // would create a kanban named `   ` (and the 3 default columns),
    // which would render as an empty row in the sidebar — the same
    // bug class as the folder handler.
    const has_trim = std.mem.indexOf(u8, source, "std.mem.trim") != null;
    const has_len_zero_check_after_trim = std.mem.indexOf(u8, source, ".len == 0") != null;
    if (!has_trim or !has_len_zero_check_after_trim) {
        std.debug.print(
            "\n!! {s} does not trim+reject whitespace-only names !!\n" ++
                "   The kanban-create handler must call `std.mem.trim` on the name\n" ++
                "   and reject whitespace-only names with a 400. This mirrors the\n" ++
                "   folder handler's EmptyName contract. Look for the substring\n" ++
                "   `std.mem.trim(...)` AND `.len == 0`.\n" ++
                "   See docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.\n",
            .{KANBAN_HANDLER_PATH},
        );
        return error.KanbanTrimMissing;
    }
}

// ─── Contract 5: folder handler ref-free — no `allocator.free(trimmed_name)` ─

test "folder create handler does NOT free the trimmed name slice" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FOLDER_HANDLER_PATH);
    defer allocator.free(source);

    // Defensive assertion: `std.mem.trim` returns a slice into the
    // same backing memory as the input (no allocation), so the
    // handler must NOT call `allocator.free` on the trimmed slice
    // (it'd be a use-after-free since the memory is owned by the
    // per-request arena that the request handler reaps at the
    // end). This regression locks that invariant in.
    //
    // We tolerate any free-pattern that does NOT include the literal
    // substring `allocator.free(trimmed_name` or
    // `allocator.free(trimmed` (which would catch the typo too).
    if (std.mem.indexOf(u8, source, "allocator.free(trimmed_name") != null or
        std.mem.indexOf(u8, source, "allocator.free(trimmed ") != null)
    {
        std.debug.print(
            "\n!! {s} frees the trimmed-name slice — that's a use-after-free !!\n" ++
                "   std.mem.trim returns a slice into the JSON-input backing memory\n" ++
                "   (owned by the per-request arena, reaped by GinwaServer.handle).\n" ++
                "   Calling allocator.free on it would crash in debug builds.\n" ++
                "   Remove the offending `allocator.free(trimmed*)` call.\n" ++
                "   See docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.\n",
            .{FOLDER_HANDLER_PATH},
        );
        return error.TrimmedNameDoubleFree;
    }
}
