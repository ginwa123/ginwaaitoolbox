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
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;

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

    const di = nalarcore.getSingleton() catch return error.ReorderFailed;
    nalarcore.ai_mod.workspace_item_tasks.reorderPinnedTasks(
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