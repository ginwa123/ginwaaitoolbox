//! Static regression checks for `DELETE /api/agents/:agent_id/tools/:tool_id`.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/agent_tools_delete.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "agentToolsDelete: scoped WHERE clause + {ok: true} response" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "DELETE FROM agent_tools") == null) return error.DeleteMissing;
    if (std.mem.indexOf(u8, source, "WHERE id = ? AND agent_id = ?") == null) return error.ScopedWhereMissing;
    if (std.mem.indexOf(u8, source, ".ok = true") == null) return error.OkResponseMissing;
}