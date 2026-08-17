//! Static regression checks for `GET /api/agent-tools/registry`.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/agent_tools_registry.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "agentToolsRegistry: sources from UNIFIED_TOOL_REGISTRY (single source of truth)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "UNIFIED_TOOL_REGISTRY") == null) {
        std.debug.print("\n!! {s} does not source from UNIFIED_TOOL_REGISTRY !!\n", .{HANDLER_PATH});
        return error.RegistrySourceMissing;
    }
}

test "agentToolsRegistry: returns {tools: [{name, description}]} shape" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".tools = ") == null) return error.ToolsFieldMissing;
    if (std.mem.indexOf(u8, source, "description:") == null) return error.DescriptionFieldMissing;
    if (std.mem.indexOf(u8, source, "function.description") == null) {
        std.debug.print("\n!! {s} does not read tool_def.function.description !!\n", .{HANDLER_PATH});
        return error.FunctionDescriptionMissing;
    }
}