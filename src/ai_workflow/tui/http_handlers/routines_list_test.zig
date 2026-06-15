//! Static regression checks for the `GET /api/routines` handler.
//!
//! Why this file exists
//! ────────────────────
//! The "list every routine with its next_run_at" endpoint is part of
//! the Add Task Routines feature. If the handler is renamed, removed,
//! or its route is dropped, the user can no longer see "what's about
//! to fire and when" at a glance — they'd have to enumerate every
//! workspace item and filter by `task_type === 'routine'` themselves.
//!
//! The `task_create_routines_test.zig` precedent established static
//! substring checks as the project's regression-test pattern (no
//! in-memory DB; the project has no precedent for spinning up
//! `nalarcore.getSingleton()` in tests because the singleton needs a
//! live `ContextIPCTui` with a server, logger, and event bus). If
//! the contract is broken, these tests fail at
//! `zig build test:ai_workflow:tui` time, before the bug reaches a
//! running server.

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/routines_list.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
const HTTP_RESPONSE_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── Contract 1: handler function exists in routines_list.zig ─────────────

test "routinesListHandler exists in routines_list.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    const sig = "pub fn routinesListHandler(";
    if (std.mem.indexOf(u8, source, sig) == null) {
        std.debug.print(
            "\n!! {s} does not define `routinesListHandler` !!\n" ++
                "   The GET /api/routines contract is broken — the handler\n" ++
                "   is missing, so the route would 404.\n" ++
                "   Restore the function:\n" ++
                "     pub fn routinesListHandler(\n" ++
                "         ctx: gserverz.HttpContext, req: gserverz.HttpRequest,\n" ++
                "         res: gserverz.HttpResponse,\n" ++
                "     ) !gserverz.HttpResponse {{ ... }}\n" ++
                "   See docs/plans/2026-06-15-routines-list-endpoint.md.\n",
            .{HANDLER_PATH},
        );
        return error.RoutinesListHandlerMissing;
    }
}

// ─── Contract 2: mod.zig re-exports the handler ───────────────────────────

test "mod.zig re-exports routinesListHandler" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    const re_export = "pub const routinesListHandler = @import(\"routines_list.zig\").routinesListHandler;";
    if (std.mem.indexOf(u8, source, re_export) == null) {
        std.debug.print(
            "\n!! {s} does not re-export `routinesListHandler` !!\n" ++
                "   The handler is unreachable from main.zig because the\n" ++
                "   http_handlers module doesn't expose it. main.zig will\n" ++
                "   fail to compile with \"unresolved identifier routinesListHandler\".\n" ++
                "   Restore the re-export next to the existing routinesRunHandler line:\n" ++
                "     pub const routinesListHandler = @import(\"routines_list.zig\").routinesListHandler;\n",
            .{MOD_PATH},
        );
        return error.RoutinesListHandlerNotReExported;
    }
}

// ─── Contract 3: main.zig registers GET /api/routines ─────────────────────

test "main.zig registers GET /api/routines" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    // The route line looks like:
    //   try gs.router.get("/api/routines", ai_mod.http_handlers.routinesListHandler);
    const expected = "gs.router.get(\"/api/routines\"";
    if (std.mem.indexOf(u8, source, expected) == null) {
        std.debug.print(
            "\n!! {s} does not register `GET /api/routines` !!\n" ++
                "   Even if the handler and re-export are correct, the route\n" ++
                "   is never bound to the GinwaServer, so the endpoint is\n" ++
                "   unreachable (404 on every call).\n" ++
                "   Restore the route registration next to the existing\n" ++
                "   routinesRunHandler line:\n" ++
                "     try gs.router.get(\"/api/routines\", ai_mod.http_handlers.routinesListHandler);\n",
            .{MAIN_PATH},
        );
        return error.RoutinesListRouteMissing;
    }
}

// ─── Contract 4: RoutinesListEntry struct has the expected fields ─────────

test "RoutinesListEntry has schedule + next_run_at + last_status" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);

    const struct_sig = "pub const RoutinesListEntry = struct";
    const sig_idx = std.mem.indexOf(u8, source, struct_sig) orelse
        return error.RoutinesListEntryMissing;
    const after_sig = sig_idx + struct_sig.len;
    const end_marker = std.mem.indexOfPos(u8, source, after_sig, "};") orelse source.len;
    const body = source[after_sig..end_marker];

    if (std.mem.indexOf(u8, body, "schedule") == null) return error.ScheduleFieldMissing;
    if (std.mem.indexOf(u8, body, "next_run_at") == null) return error.NextRunAtFieldMissing;
    if (std.mem.indexOf(u8, body, "last_status") == null) return error.LastStatusFieldMissing;
    if (std.mem.indexOf(u8, body, "workspace_id") == null) return error.WorkspaceIdFieldMissing;
}

// ─── Contract 5: SQL JOINs the routines ↔ workspace_item_tasks ↔ workspace_items chain

test "routinesListHandler SQL JOINs workspace_item_tasks and workspace_items" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "JOIN workspace_item_tasks") == null) {
        std.debug.print(
            "\n!! {s} does not JOIN workspace_item_tasks !!\n" ++
                "   Without the join, the response can't carry task_name —\n" ++
                "   the listing would be a wall of routine ids with no way\n" ++
                "   to tell which task each row corresponds to.\n",
            .{HANDLER_PATH},
        );
        return error.WorkspaceItemTasksJoinMissing;
    }
    if (std.mem.indexOf(u8, source, "JOIN workspace_items") == null) {
        std.debug.print(
            "\n!! {s} does not JOIN workspace_items !!\n" ++
                "   Without the join, the response can't carry workspace_id\n" ++
                "   — the caller would have no way to navigate from the\n" ++
                "   listing back to the source workspace.\n",
            .{HANDLER_PATH},
        );
        return error.WorkspaceItemsJoinMissing;
    }
}
