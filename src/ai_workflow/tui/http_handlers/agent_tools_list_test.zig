//! Static regression checks for `GET /api/agents/:agent_id/tools`.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/agent_tools_list.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "agentToolsList: queries agent_tools WHERE enabled = 1, ORDER BY tool_name ASC" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "FROM agent_tools") == null) return error.QueryMissing;
    if (std.mem.indexOf(u8, source, "enabled = 1") == null) return error.EnabledFilterMissing;
    if (std.mem.indexOf(u8, source, "ORDER BY tool_name ASC") == null) return error.OrderMissing;
}

test "agentToolsList: returns {tools: [...]} envelope" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".tools = ") == null) return error.ToolsFieldMissing;
}