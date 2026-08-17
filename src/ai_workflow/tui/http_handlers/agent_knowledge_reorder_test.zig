//! Static regression checks for `PATCH /agents/:agent_id/knowledge/reorder`.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/agent_knowledge_reorder.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "agentKnowledgeReorder: parses ordered_ids array" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "ordered_ids") == null) return error.OrderedIdsMissing;
}

test "agentKnowledgeReorder: wraps UPDATE in BEGIN/COMMIT" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "\"BEGIN\"") == null) return error.BeginMissing;
    if (std.mem.indexOf(u8, source, "\"COMMIT\"") == null) return error.CommitMissing;
}

test "agentKnowledgeReorder: WHERE clause scopes by id + agent_id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "WHERE id = ? AND agent_id = ?") == null) return error.ScopedWhereMissing;
}