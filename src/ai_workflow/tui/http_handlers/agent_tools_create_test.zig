//! Static regression checks for `POST /api/agents/:agent_id/tools`.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/agent_tools_create.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "agentToolsCreate: validates tool_name against UNIFIED_TOOL_REGISTRY" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "UNIFIED_TOOL_REGISTRY") == null) {
        std.debug.print("\n!! {s} does not validate against UNIFIED_TOOL_REGISTRY !!\n", .{HANDLER_PATH});
        return error.RegistryValidationMissing;
    }
    if (std.mem.indexOf(u8, source, "isKnownTool") == null) return error.IsKnownToolMissing;
}

test "agentToolsCreate: maps UNIQUE violation to 409" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "409") == null) return error.ConflictStatusMissing;
}

test "agentToolsCreate: returns 400 for unknown tool_name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "not in the registry") == null) return error.UnknownToolMessageMissing;
}