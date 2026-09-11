//! `POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/pin`.
//!
//! Body: `{ "is_pinned": true | false }`.
//!
//! Flips the `is_pinned` flag on the row. When pinning (true), the
//! row's `pinned_position` is bumped to MAX(pinned_position WHERE
//! is_pinned=1) + 1 so it lands at the BOTTOM of the pinned region.
//! When unpinning (false), the row's `pinned_position` is reset to 0.
//!
//! Idempotent: pinning an already-pinned row is a no-op for the
//! position bump (MAX still includes the row's own value, so the
//! new position equals the current one). Unpinning an
//! already-unpinned row is also a no-op.
//!
//! Layered as `useCase` (parse body + flip pin + return new position)
//! and a thin handler that maps the outcome + errors to status
//! codes / JSON.

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;

pub const TaskPinError = error{
    TaskIdRequired,
    BodyRequired,
    InvalidJson,
    IsPinnedRequired,
    IsPinnedMustBeBool,
    TaskNotFound,
    PinUpdateFailed,
    /// `makeTaskPinResponse` / `std.json.Stringify.valueAlloc` can
    /// fail with `OutOfMemory`. Unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const TaskPinInput = struct {
    task_id: []const u8,
    is_pinned: bool,
};

/// Tagged outcome: returns the new pinned_position (or 0 if
/// unpinning).
pub const TaskPinResult = struct {
    new_pos: i64,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    input: TaskPinInput,
) TaskPinError!TaskPinResult {
    if (input.task_id.len == 0) return error.TaskIdRequired;

    const di = nalarcore.getSingleton() catch return error.PinUpdateFailed;
    const new_pos = nalarcore.ai_mod.workspace_item_tasks.setTaskPinned(
        allocator,
        di.db,
        input.task_id,
        input.is_pinned,
    ) catch |err| {
        // The model function returns a wider error set; the only
        // domain-meaningful variant is `TaskNotFound` (404). All
        // other errors collapse to `PinUpdateFailed` (500).
        if (err == error.TaskNotFound) return error.TaskNotFound;
        return error.PinUpdateFailed;
    };

    return .{ .new_pos = new_pos };
}

// =====================================================================
// Handler
// =====================================================================

pub fn taskPinHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // 1. Validate path param.
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    // 2. Validate body presence.
    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }),
        });
    }

    // 3. Parse JSON and extract `is_pinned`. The body shape is
    // `{ is_pinned: bool }` — we parse as a `std.json.Value` so we
    // can validate the field type without a dedicated struct
    // (the field is a single bool; a dedicated struct adds noise).
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    const is_pinned_val = parsed.object.get("is_pinned") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_pinned required" }),
        });
    };
    if (is_pinned_val != .bool) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_pinned must be a boolean" }),
        });
    }
    const is_pinned = is_pinned_val.bool;

    // 4. Delegate to the use-case.
    const outcome = useCase(allocator, .{
        .task_id = task_id,
        .is_pinned = is_pinned,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.TaskIdRequired => 400,
            error.BodyRequired => 400,
            error.InvalidJson => 400,
            error.IsPinnedRequired => 400,
            error.IsPinnedMustBeBool => 400,
            error.TaskNotFound => 404,
            error.PinUpdateFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.TaskIdRequired => "task_id required",
            error.BodyRequired => "body required",
            error.InvalidJson => "Invalid JSON",
            error.IsPinnedRequired => "is_pinned required",
            error.IsPinnedMustBeBool => "is_pinned must be a boolean",
            error.TaskNotFound => "Task not found",
            error.PinUpdateFailed => "Failed to update task pin",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeTaskPinResponse(allocator, task_id, is_pinned, outcome.new_pos),
    });
}

// ===== Tests merged from task_pin_test.zig (2026-09-11 flatten) =====
// Static regression checks for the task pin handler.
// 
// The pin endpoint is a thin handler around `llm_history.setTaskPinned`.
// These tests assert the structural contract:
//   1. The handler reads `is_pinned` from the request body.
//   2. The handler calls `setTaskPinned`.
//   3. The response uses `makeTaskPinResponse` (typed).
//   4. `setTaskPinned` is exposed in `llm_history.zig`.
//   5. `TaskPinResponse` + helper exist in `http_response.zig`.
//   6. Migration 050 declares the new columns.
// 
// Plan: docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/task_pin.zig";
const LLM_HISTORY_PATH = "src/agentic_loop/llm_history.zig";
const RESPONSE_PATH = "src/http_handlers/http_response.zig";
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
