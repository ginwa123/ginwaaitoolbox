//! `GET /api/workspaces/:ws_id/items/:item_id/kanban/tags?limit=N&offset=K`.
//!
//! Returns one page of distinct tags from tasks belonging to the
//! given kanban workspace item, ordered by frequency DESC then
//! most-recent usage DESC. Powers the kanban task detail dialog's
//! tag autocomplete dropdown. Pagination is via `limit` + `offset`.
//!
//! Response: `{ tags: [{name, count, last_used_at}], has_more }`.
//!
//! Mirrors the layered shape of `tasks_list.zig` (useCase + thin
//! handler that maps errors to status codes / JSON).
//!
//! Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const llm_history = ai_mod.llm_history;

const DEFAULT_LIMIT: u32 = 8;
const MAX_LIMIT: u32 = 50;

pub const KanbanTagsListError = error{
    OutOfMemory,
    DbError,
};

pub const KanbanTagsListInput = struct {
    workspace_item_id: []const u8,
    limit: u32,
    offset: u32,
};

pub const KanbanTagsListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: KanbanTagsListInput,
) KanbanTagsListError!KanbanTagsListResult {
    const page = llm_history.listKanbanDistinctTags(
        allocator,
        db,
        input.workspace_item_id,
        input.limit,
        input.offset,
    ) catch return KanbanTagsListError.DbError;
    defer page.deinit(allocator);

    var response_suggestions: std.ArrayList(http_response.KanbanTagSuggestionResponse) = .empty;
    defer response_suggestions.deinit(allocator);

    for (page.tags) |s| {
        try response_suggestions.append(allocator, .{
            .name = s.name,
            .count = s.count,
            .last_used_at = s.last_used_at,
        });
    }

    return http_response.makeKanbanTagsListResponse(
        allocator,
        response_suggestions.items,
        page.has_more,
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn kanbanTagsListHandler(
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

    // Parse `limit` query param with clamping. Default 8, max 50.
    const limit_str = req.query.get("limit") orelse "8";
    const limit_parsed = std.fmt.parseInt(u32, limit_str, 10) catch DEFAULT_LIMIT;
    const limit: u32 = if (limit_parsed == 0)
        DEFAULT_LIMIT
    else if (limit_parsed > MAX_LIMIT)
        MAX_LIMIT
    else
        limit_parsed;

    // Parse `offset` query param. Default 0. No upper clamp (a
    // user-paginating past the end just gets an empty page).
    const offset_str = req.query.get("offset") orelse "0";
    const offset = std.fmt.parseInt(u32, offset_str, 10) catch 0;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const data = useCase(allocator, sqlite_db, .{
        .workspace_item_id = item_id,
        .limit = limit,
        .offset = offset,
    }) catch |err| {
        const status: u16 = switch (err) {
            KanbanTagsListError.DbError => 500,
            KanbanTagsListError.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            KanbanTagsListError.DbError => "Failed to fetch tag suggestions",
            KanbanTagsListError.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}