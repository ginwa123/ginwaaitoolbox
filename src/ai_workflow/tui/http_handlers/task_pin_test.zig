//! Static regression checks for the task pin handler.
//!
//! The pin endpoint is a thin handler around `llm_history.setTaskPinned`.
//! These tests assert the structural contract:
//!   1. The handler reads `is_pinned` from the request body.
//!   2. The handler calls `setTaskPinned`.
//!   3. The response uses `makeTaskPinResponse` (typed).
//!   4. `setTaskPinned` is exposed in `llm_history.zig`.
//!   5. `TaskPinResponse` + helper exist in `http_response.zig`.
//!   6. Migration 050 declares the new columns.
//!
//! Plan: docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_pin.zig";
const LLM_HISTORY_PATH = "src/ai_workflow/tui/agentic_loop/llm_history.zig";
const RESPONSE_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";
const MIGRATION_PATH = "src/migrations/migration.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

test "task_pin handler parses is_pinned from the request body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "\"is_pinned\"") == null and
        std.mem.indexOf(u8, source, "'is_pinned'") == null)
    {
        std.debug.print(
            "\n!! {s} does not reference the `is_pinned` field !!\n" ++
                "   The pin endpoint is broken. The frontend POSTs\n" ++
                "   {{is_pinned: bool}} and expects a 200 + new position.\n" ++
                "   Restore the field name in the handler body parser.\n" ++
                "   See docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md.\n",
            .{HANDLER_PATH},
        );
        return error.IsPinnedParamMissing;
    }
}

test "task_pin handler calls setTaskPinned use case" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "setTaskPinned") == null) {
        std.debug.print(
            "\n!! {s} does not call setTaskPinned !!\n" ++
                "   The pin endpoint is silently a no-op (no DB write).\n" ++
                "   Add: const new_pos = ...setTaskPinned(...);\n",
            .{HANDLER_PATH},
        );
        return error.SetTaskPinnedNotCalled;
    }
}

test "task_pin handler uses a typed response (makeTaskPinResponse)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "makeTaskPinResponse") == null) {
        std.debug.print(
            "\n!! {s} does not call makeTaskPinResponse !!\n" ++
                "   The response is being constructed manually.\n" ++
                "   Use the typed helper in http_response.zig instead:\n" ++
                "     try http_response.makeTaskPinResponse(allocator, id, is_pinned, pinned_position)\n",
            .{HANDLER_PATH},
        );
        return error.TypedResponseMissing;
    }
}

test "llm_history exposes setTaskPinned" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    const sig = "pub fn setTaskPinned(";
    if (std.mem.indexOf(u8, source, sig) == null) {
        std.debug.print(
            "\n!! {s} does not define `setTaskPinned` !!\n" ++
                "   The pin handler has no use case to call. Add it next to\n" ++
                "   `updateWorkspaceItemTask` / `deleteWorkspaceItemTask`.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.SetTaskPinnedMissing;
    }
}

test "TaskPinResponse and makeTaskPinResponse exist in http_response.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, RESPONSE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "TaskPinResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing TaskPinResponse !!\n" ++
                "   Add: pub const TaskPinResponse = struct {{ success: bool = true, id, is_pinned: bool, pinned_position: i64 }};\n",
            .{RESPONSE_PATH},
        );
        return error.TaskPinResponseStructMissing;
    }
    if (std.mem.indexOf(u8, source, "makeTaskPinResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing makeTaskPinResponse !!\n" ++
                "   Add: pub fn makeTaskPinResponse(allocator, id, is_pinned, pinned_position) ![]u8 {{ ... }}.\n",
            .{RESPONSE_PATH},
        );
        return error.MakeTaskPinResponseMissing;
    }
}

test "Migration050 declares is_pinned and pinned_position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MIGRATION_PATH);
    defer allocator.free(source);

    const has_version = std.mem.indexOf(u8, source, "Migration050AddPinnedToWorkspaceItemTasks") != null;
    const has_is_pinned = std.mem.indexOf(u8, source, "is_pinned") != null;
    const has_pinned_position = std.mem.indexOf(u8, source, "pinned_position") != null;
    if (!has_version or !has_is_pinned or !has_pinned_position) {
        std.debug.print(
            "\n!! {s} is missing Migration 050 or its columns !!\n" ++
                "   Fresh databases will not have an is_pinned column,\n" ++
                "   and the pin handler will fail at ALTER TABLE.\n" ++
                "   See docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md.\n",
            .{MIGRATION_PATH},
        );
        return error.Migration050Missing;
    }
}
