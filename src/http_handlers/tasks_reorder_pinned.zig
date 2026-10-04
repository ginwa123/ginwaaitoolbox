//! `POST /api/workspaces/:workspace_id/items/:item_id/tasks/reorder_pinned`.
//!
//! Body: `{ "ordered_ids": ["id1", "id2", ..., "idN"] }` (top-to-bottom
//! display order of the pinned subset).
//!
//! Behavior: assigns `pinned_position = N-1 - i` to the i-th id.
//! The list lister's `ORDER BY is_pinned DESC, pinned_position DESC,
//! id DESC` then renders them in the user's chosen order. Rows that
//! aren't currently pinned (is_pinned=0) or that belong to a
//! different workspace_item are silently skipped (defense in depth,
//! consistent with the workspace reorder endpoints).
//!
//! Idempotent: a second call with the same array leaves the data
//! unchanged (positions are recomputed but the final state is the
//! same).
//!
//! Layered as `useCase` (parse body + collect ids + reorder) and a
//! thin handler that maps errors to status codes / JSON.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

pub const TasksReorderPinnedError = error{
    ItemIdRequired,
    BodyRequired,
    InvalidJson,
    OrderedIdsRequired,
    OrderedIdsMustBeArray,
    ReorderFailed,
    /// `makeTasksReorderPinnedResponse` / `std.json.Stringify.valueAlloc`
    /// can fail with `OutOfMemory`. Unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const TasksReorderPinnedInput = struct {
    item_id: []const u8,
    /// Pre-extracted array of task ids (the use-case doesn't have to
    /// know about `std.json.Value`).
    ordered_ids: []const []const u8,
};

pub const TasksReorderPinnedResult = struct {
    count: usize,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    input: TasksReorderPinnedInput,
) TasksReorderPinnedError!TasksReorderPinnedResult {
    if (input.item_id.len == 0) return error.ItemIdRequired;

    const di = pabrikcore.getSingleton() catch return error.ReorderFailed;
    pabrikcore.ai_mod.workspace_item_tasks.reorderPinnedTasks(
        allocator,
        di.db,
        input.item_id,
        input.ordered_ids,
    ) catch return error.ReorderFailed;

    return .{ .count = input.ordered_ids.len };
}

// =====================================================================
// Handler
// =====================================================================

pub fn tasksReorderPinnedHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }),
        });
    }

    // Parse JSON. The body shape is `{ ordered_ids: string[] }`.
    // We use `std.json.Value` because we want to extract a
    // dynamic-length string array without a dedicated struct
    // (the field name is the contract; the inner type is `[]string`).
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    const root = parsed.object;
    const ordered_ids_val = root.get("ordered_ids") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            // The contract substring "ordered_ids" must appear in the
            // source for the static-contract test (see tasks_reorder_pinned_test.zig).
            // Keeping the human-readable message here matches the
            // test's check: it asserts `std.mem.indexOf(u8, source, "ordered_ids") == null` → false.
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids required" }),
        });
    };
    if (ordered_ids_val != .array) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids must be an array" }),
        });
    }

    // Collect the string ids into an ArrayList. Non-string entries
    // (numbers, bools, objects) are silently skipped — the model
    // function only handles strings, and a defensive parse matches
    // the "silently skip invalid rows" contract used elsewhere.
    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (ordered_ids_val.array.items) |item| {
        if (item == .string) try ids.append(allocator, item.string);
    }

    const outcome = useCase(allocator, .{
        .item_id = item_id,
        .ordered_ids = ids.items,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.BodyRequired => 400,
            error.InvalidJson => 400,
            error.OrderedIdsRequired => 400,
            error.OrderedIdsMustBeArray => 400,
            error.ReorderFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.BodyRequired => "body required",
            error.InvalidJson => "Invalid JSON",
            error.OrderedIdsRequired => "ordered_ids required",
            error.OrderedIdsMustBeArray => "ordered_ids must be an array",
            error.ReorderFailed => "Failed to reorder pinned tasks",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeTasksReorderPinnedResponse(allocator, outcome.count),
    });
}

// ===== Tests merged from tasks_reorder_pinned_test.zig (2026-09-11 flatten) =====
// Static regression checks for the pinned-task reorder handler.
// 
// Mirrors the `workspace_items_reorder_test.zig` pattern. The
// pinned-task reorder endpoint assigns a new pinned_position per
// row in the payload, scoped to a single workspace_item. These tests
// assert the structural contract:
//   1. The handler reads `ordered_ids` from the body.
//   2. The handler calls `reorderPinnedTasks`.
//   3. The use case filters by `is_pinned = 1` so unpinned rows
//      in the payload are silently skipped.
//   4. The use case uses `count - 1 - i` for the position formula.
//   5. The response uses `makeTasksReorderPinnedResponse` (typed).
//   6. `reorderPinnedTasks` is exposed in `llm_history.zig`.
//   7. `TasksReorderPinnedResponse` + helper exist in
//      `http_response.zig`.
// 
// Plan: docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/tasks_reorder_pinned.zig";
const LLM_HISTORY_PATH = "src/agentic_loop/llm_history.zig";
const RESPONSE_PATH = "src/http_handlers/http_response.zig";

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

test "tasks_reorder_pinned handler parses ordered_ids" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "ordered_ids") == null) {
        std.debug.print(
            "\n!! {s} does not reference `ordered_ids` !!\n" ++
                "   The reorder endpoint is broken. The frontend POSTs\n" ++
                "   {{ordered_ids: [...]}} and expects a 200 + position updates.\n" ++
                "   See docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md.\n",
            .{HANDLER_PATH},
        );
        return error.OrderedIdsMissing;
    }
}

test "tasks_reorder_pinned handler calls reorderPinnedTasks use case" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "reorderPinnedTasks") == null) {
        std.debug.print(
            "\n!! {s} does not call reorderPinnedTasks !!\n" ++
                "   The reorder endpoint is silently a no-op.\n",
            .{HANDLER_PATH},
        );
        return error.ReorderPinnedTasksNotCalled;
    }
}

test "tasks_reorder_pinned scopes UPDATE by is_pinned = 1" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The use case should filter by is_pinned = 1 so a payload
    // containing unpinned rows is a silent no-op for them.
    if (std.mem.indexOf(u8, source, "is_pinned = 1") == null) {
        std.debug.print(
            "\n!! {s} does not filter by `is_pinned = 1` !!\n" ++
                "   An unpinned row in the payload would get a new\n" ++
                "   pinned_position without being pinned. Add: WHERE ... AND is_pinned = 1\n",
            .{LLM_HISTORY_PATH},
        );
        return error.IsPinnedFilterMissing;
    }
}

test "tasks_reorder_pinned use case uses position = (count - 1 - i) formula" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "count - 1 -") == null) {
        std.debug.print(
            "\n!! {s} is missing the `count - 1 - i` position formula !!\n" ++
                "   The reorder endpoint will assign positions in the\n" ++
                "   wrong direction (bottom-to-top instead of top-to-bottom).\n" ++
                "   Restore: const new_pos: i64 = count - 1 - @as(i64, @intCast(i));\n",
            .{LLM_HISTORY_PATH},
        );
        return error.PositionFormulaMissing;
    }
}

test "tasks_reorder_pinned handler uses makeTasksReorderPinnedResponse" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "makeTasksReorderPinnedResponse") == null) {
        std.debug.print(
            "\n!! {s} does not call makeTasksReorderPinnedResponse !!\n" ++
                "   Use the typed response helper in http_response.zig:\n" ++
                "     try http_response.makeTasksReorderPinnedResponse(allocator, count)\n",
            .{HANDLER_PATH},
        );
        return error.TypedResponseMissing;
    }
}

test "llm_history exposes reorderPinnedTasks" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    const sig = "pub fn reorderPinnedTasks(";
    if (std.mem.indexOf(u8, source, sig) == null) {
        std.debug.print(
            "\n!! {s} does not define `reorderPinnedTasks` !!\n" ++
                "   The handler has no use case to call. Add it next to\n" ++
                "   `setTaskPinned` in llm_history.zig.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.ReorderPinnedTasksMissing;
    }
}

test "TasksReorderPinnedResponse and helper exist in http_response.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, RESPONSE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "TasksReorderPinnedResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing TasksReorderPinnedResponse !!\n" ++
                "   Add: pub const TasksReorderPinnedResponse = struct {{ success: bool = true, count: usize }};\n",
            .{RESPONSE_PATH},
        );
        return error.TasksReorderPinnedResponseStructMissing;
    }
    if (std.mem.indexOf(u8, source, "makeTasksReorderPinnedResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing makeTasksReorderPinnedResponse !!\n" ++
                "   Add: pub fn makeTasksReorderPinnedResponse(allocator, count) ![]u8 {{ ... }}.\n",
            .{RESPONSE_PATH},
        );
        return error.MakeTasksReorderPinnedResponseMissing;
    }
}
