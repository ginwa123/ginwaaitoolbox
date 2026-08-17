//! Static regression checks for `PATCH /agents/:agent_id/knowledge/:knowledge_id`.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/agent_knowledge_update.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "agentKnowledgeUpdate: parses optional file_path + label" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "file_path: ?") == null) return error.FilePathOptionalMissing;
    if (std.mem.indexOf(u8, source, "label: ?") == null) return error.LabelOptionalMissing;
}

test "agentKnowledgeUpdate: validates absolute path when file_path is provided" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "isAbsolute") == null) return error.AbsoluteCheckMissing;
}

test "agentKnowledgeUpdate: rejects empty update (neither field provided)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "file_path or label required") == null) return error.EmptyUpdateMessageMissing;
}

test "agentKnowledgeUpdate: WHERE clause scopes by id + agent_id (security)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "WHERE id = ? AND agent_id = ?") == null) {
        return error.ScopedWhereMissing;
    }
}