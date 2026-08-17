//! Static regression checks for `PATCH /workspaces/:wsId/items/:itemId/agent`
//! handler (`agents_update.zig`).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/agents_update.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "agents_update handler parses body via parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("\n!! {s} does not use parseFromSliceLeaky !!\n", .{HANDLER_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
    if (std.mem.indexOf(u8, source, "description") == null) return error.DescriptionFieldMissing;
}

test "agents_update handler validates item_type='agent' before UPDATE" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "item_type") == null) {
        std.debug.print("\n!! {s} does not check item_type !!\n", .{HANDLER_PATH});
        return error.ItemTypeValidationMissing;
    }
    if (std.mem.indexOf(u8, source, "\"agent\"") == null) {
        std.debug.print("\n!! {s} does not check \"agent\" literal !!\n", .{HANDLER_PATH});
        return error.AgentItemTypeMissing;
    }
}

test "agents_update handler issues UPDATE agents SET description" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "UPDATE agents SET description") == null) {
        std.debug.print("\n!! {s} does not UPDATE agents.description !!\n", .{HANDLER_PATH});
        return error.UpdateAgentsMissing;
    }
    if (std.mem.indexOf(u8, source, "datetime('now')") == null) {
        std.debug.print("\n!! {s} does not bump updated_at !!\n", .{HANDLER_PATH});
        return error.UpdatedAtBumpMissing;
    }
}

test "agents_update handler returns 404 for missing workspace_item + 400 for non-agent" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "404") == null) return error.NotFoundStatusMissing;
    if (std.mem.indexOf(u8, source, "is not an agent") == null) return error.NotAgentMessageMissing;
}