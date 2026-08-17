//! Static regression checks for `POST /agents/:agent_id/knowledge`
//! handler (`agent_knowledge_create.zig`).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/agent_knowledge_create.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "agentKnowledgeCreate: parses body via parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("\n!! {s} missing parseFromSliceLeaky !!\n", .{HANDLER_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
    if (std.mem.indexOf(u8, source, "file_path") == null) return error.FilePathMissing;
    if (std.mem.indexOf(u8, source, "label") == null) return error.LabelMissing;
}

test "agentKnowledgeCreate: validates absolute path" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "isAbsolute") == null) {
        std.debug.print("\n!! {s} missing isAbsolute check !!\n", .{HANDLER_PATH});
        return error.AbsoluteCheckMissing;
    }
    if (std.mem.indexOf(u8, source, "must be absolute") == null) return error.AbsoluteErrorMessageMissing;
}

test "agentKnowledgeCreate: validates item_type='agent' on workspace_items" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "item_type") == null) return error.ItemTypeCheckMissing;
    if (std.mem.indexOf(u8, source, "'agent'") == null) return error.AgentLiteralMissing;
}

test "agentKnowledgeCreate: INSERT uses COALESCE(MAX+1) for position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "INSERT INTO agent_knowledge") == null) {
        return error.InsertMissing;
    }
    if (std.mem.indexOf(u8, source, "COALESCE((SELECT MAX(position)") == null) {
        return error.PositionCoalesceMissing;
    }
}