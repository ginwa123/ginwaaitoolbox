//! Static regression checks for the `GET /workspaces/:wsId/items/:itemId/agent`
//! handler (`agents_get.zig`).
//!
//! Matches the project's static-test pattern (see
//! `workspace_items_create_kanban_test.zig`).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/agents_get.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "agents_get handler validates workspace_id + item_id params" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Must extract both params.
    if (std.mem.indexOf(u8, source, "workspace_id") == null) return error.WorkspaceIdMissing;
    if (std.mem.indexOf(u8, source, "item_id") == null) return error.ItemIdMissing;
}

test "agents_get handler queries workspace_items and validates item_type='agent'" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "FROM workspace_items") == null) {
        std.debug.print("\n!! {s} does not query workspace_items !!\n", .{HANDLER_PATH});
        return error.WorkspaceItemsQueryMissing;
    }
    if (std.mem.indexOf(u8, source, "'agent'") == null) {
        std.debug.print("\n!! {s} does not check item_type='agent' !!\n", .{HANDLER_PATH});
        return error.ItemTypeValidationMissing;
    }
    if (std.mem.indexOf(u8, source, "ItemNotAgent") == null) {
        std.debug.print("\n!! {s} does not declare ItemNotAgent error !!\n", .{HANDLER_PATH});
        return error.ItemNotAgentErrorMissing;
    }
}

test "agents_get handler returns {agent, knowledge, tools} envelope" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The envelope must include all 3 fields.
    if (std.mem.indexOf(u8, source, "agent: ") == null) return error.AgentFieldMissing;
    if (std.mem.indexOf(u8, source, "knowledge: ") == null) return error.KnowledgeFieldMissing;
    if (std.mem.indexOf(u8, source, "tools: ") == null) return error.ToolsFieldMissing;
}

test "agents_get handler queries agent_knowledge ORDER BY position DESC" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "FROM agent_knowledge") == null) {
        std.debug.print("\n!! {s} does not query agent_knowledge !!\n", .{HANDLER_PATH});
        return error.AgentKnowledgeQueryMissing;
    }
    if (std.mem.indexOf(u8, source, "ORDER BY position DESC") == null) {
        std.debug.print("\n!! {s} does not order by position DESC !!\n", .{HANDLER_PATH});
        return error.PositionDescMissing;
    }
}

test "agents_get handler queries agent_tools filtered to enabled=1, ordered by tool_name ASC" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "FROM agent_tools") == null) {
        std.debug.print("\n!! {s} does not query agent_tools !!\n", .{HANDLER_PATH});
        return error.AgentToolsQueryMissing;
    }
    if (std.mem.indexOf(u8, source, "enabled = 1") == null) {
        std.debug.print("\n!! {s} does not filter to enabled = 1 !!\n", .{HANDLER_PATH});
        return error.EnabledFilterMissing;
    }
    if (std.mem.indexOf(u8, source, "ORDER BY tool_name ASC") == null) {
        std.debug.print("\n!! {s} does not order by tool_name ASC !!\n", .{HANDLER_PATH});
        return error.ToolNameAscMissing;
    }
}