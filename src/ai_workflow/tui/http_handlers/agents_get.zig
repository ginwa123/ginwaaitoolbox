//! `GET /api/workspaces/:workspace_id/items/:item_id/agent`.
//!
//! Returns `{agent, knowledge, tools}` for the agent bound to this
//! workspace_item. The frontend's AgentView consumes this payload to
//! populate both the Knowledge panel and the Tools panel in one
//! round-trip.
//!
//! - `agent` — the `agents` row (description, timestamps)
//! - `knowledge` — array of `AgentKnowledgeRow` ordered by position DESC
//! - `tools` — array of `string` (tool_names) ordered by tool_name ASC,
//!             filtered to `enabled = 1` only
//!
//! Returns 400 when the workspace_item's `item_type` is not `'agent'`,
//! 404 when the workspace_item doesn't exist.
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 5)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

/// Wire shape for a knowledge row in the GET response.
pub const AgentKnowledgeRow = struct {
    id: []const u8,
    agent_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Wire shape for the agent row in the GET response.
pub const AgentRow = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const AgentGetError = error{
    WorkspaceIdRequired,
    ItemIdRequired,
    ItemNotFound,
    ItemNotAgent,
    DatabaseError,
    OutOfMemory,
};

const WorkspaceAndItemId = struct {
    workspace_id: []const u8,
    item_id: []const u8,
};

fn validateIds(
    workspace_id: []const u8,
    item_id: []const u8,
) AgentGetError!WorkspaceAndItemId {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (item_id.len == 0) return error.ItemIdRequired;
    return .{ .workspace_id = workspace_id, .item_id = item_id };
}

/// Validate that the workspace_item exists AND has item_type='agent'.
/// Returns the agent row id on success (= workspace_item_id per D3).
fn loadAgentRowId(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
) AgentGetError![]u8 {
    var q = db.query(allocator,
        "SELECT id, item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{item_id},
    ) catch return error.DatabaseError;
    defer q.deinit();
    const row = (q.next() catch null) orelse return error.ItemNotFound;
    defer row.deinit(allocator);
    const item_type = row.values[1];
    if (!std.mem.eql(u8, item_type, "agent")) return error.ItemNotAgent;
    return try allocator.dupe(u8, row.values[0]);
}

/// Load the agents row (description + timestamps).
fn loadAgentRow(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    agent_id: []const u8,
) AgentGetError!AgentRow {
    var q = db.query(allocator,
        "SELECT id, workspace_item_id, description, IFNULL(created_at, ''), IFNULL(updated_at, '') FROM agents WHERE id = ?",
        &[_][]const u8{agent_id},
    ) catch return error.DatabaseError;
    defer q.deinit();
    const row = (q.next() catch null) orelse return error.ItemNotFound;
    defer row.deinit(allocator);
    return .{
        .id = try allocator.dupe(u8, row.values[0]),
        .workspace_item_id = try allocator.dupe(u8, row.values[1]),
        .description = try allocator.dupe(u8, row.values[2]),
        .created_at = try allocator.dupe(u8, row.values[3]),
        .updated_at = try allocator.dupe(u8, row.values[4]),
    };
}

/// Load all knowledge rows for the agent, ordered by position DESC.
fn loadKnowledgeRows(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    agent_id: []const u8,
) AgentGetError![]AgentKnowledgeRow {
    var list: std.ArrayList(AgentKnowledgeRow) = .empty;
    errdefer {
        for (list.items) |k| {
            allocator.free(k.id);
            allocator.free(k.agent_id);
            allocator.free(k.file_path);
            if (k.label.len > 0) allocator.free(k.label);
            if (k.created_at.len > 0) allocator.free(k.created_at);
            if (k.updated_at.len > 0) allocator.free(k.updated_at);
        }
        list.deinit(allocator);
    }

    var q = db.query(allocator,
        \\SELECT id, agent_id, file_path, label, position,
        \\       IFNULL(created_at, ''), IFNULL(updated_at, '')
        \\FROM agent_knowledge WHERE agent_id = ?
        \\ORDER BY position DESC
    , &[_][]const u8{agent_id}) catch return error.DatabaseError;
    defer q.deinit();

    while ((q.next() catch null)) |row| {
        defer row.deinit(allocator);
        const position = std.fmt.parseInt(i64, row.values[4], 10) catch 0;
        try list.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .agent_id = try allocator.dupe(u8, row.values[1]),
            .file_path = try allocator.dupe(u8, row.values[2]),
            .label = try allocator.dupe(u8, row.values[3]),
            .position = position,
            .created_at = try allocator.dupe(u8, row.values[5]),
            .updated_at = try allocator.dupe(u8, row.values[6]),
        });
    }
    return try list.toOwnedSlice(allocator);
}

/// Load all enabled tool names for the agent, ordered by tool_name ASC.
fn loadEnabledToolNames(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    agent_id: []const u8,
) AgentGetError![]const []u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |n| allocator.free(n);
        list.deinit(allocator);
    }

    var q = db.query(allocator,
        "SELECT tool_name FROM agent_tools WHERE agent_id = ? AND enabled = 1 ORDER BY tool_name ASC",
        &[_][]const u8{agent_id}) catch return error.DatabaseError;
    defer q.deinit();

    while ((q.next() catch null)) |row| {
        defer row.deinit(allocator);
        try list.append(allocator, try allocator.dupe(u8, row.values[0]));
    }
    return try list.toOwnedSlice(allocator);
}

pub fn agentsGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    const ids = validateIds(workspace_id, item_id) catch |err| {
        const status: u16 = if (err == error.ItemNotFound) 404 else 400;
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.ItemIdRequired => "item_id required",
            error.ItemNotFound => "workspace_item not found",
            error.ItemNotAgent => "workspace_item is not an agent",
            else => "validation failed",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // 1. Validate workspace_item exists and is an agent; get agent_id (=.
    //    workspace_item_id per D3).
    const agent_id = loadAgentRowId(allocator, sqlite_db, ids.item_id) catch |err| {
        const status: u16 = switch (err) {
            error.ItemNotFound => 404,
            error.ItemNotAgent => 400,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemNotFound => "workspace_item not found",
            error.ItemNotAgent => "workspace_item is not an agent",
            error.DatabaseError => "Failed to query workspace_item",
            error.OutOfMemory => "Out of memory",
            else => "internal error",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer allocator.free(agent_id);

    // 2. Load agent row.
    const agent_row = loadAgentRow(allocator, sqlite_db, agent_id) catch |err| {
        const status: u16 = if (err == error.ItemNotFound) 404 else 500;
        const message: []const u8 = "Failed to load agent row";
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer {
        allocator.free(agent_row.id);
        allocator.free(agent_row.workspace_item_id);
        allocator.free(agent_row.description);
        allocator.free(agent_row.created_at);
        allocator.free(agent_row.updated_at);
    }

    // 3. Load knowledge rows.
    const knowledge = loadKnowledgeRows(allocator, sqlite_db, agent_id) catch {
        const message: []const u8 = "Failed to load agent knowledge";
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer {
        for (knowledge) |k| {
            allocator.free(k.id);
            allocator.free(k.agent_id);
            allocator.free(k.file_path);
            if (k.label.len > 0) allocator.free(k.label);
            if (k.created_at.len > 0) allocator.free(k.created_at);
            if (k.updated_at.len > 0) allocator.free(k.updated_at);
        }
        allocator.free(knowledge);
    }

    // 4. Load enabled tool names.
    const tools = loadEnabledToolNames(allocator, sqlite_db, agent_id) catch {
        const message: []const u8 = "Failed to load agent tools";
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer {
        for (tools) |t| allocator.free(t);
        allocator.free(tools);
    }

    // 5. Serialize.
    const envelope = struct {
        agent: AgentRow,
        knowledge: []AgentKnowledgeRow,
        tools: []const []const u8,
    }{ .agent = agent_row, .knowledge = knowledge, .tools = tools };
    const data = try std.json.Stringify.valueAlloc(allocator, envelope, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}