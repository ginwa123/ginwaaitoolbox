//! Static regression checks for the design LLM tools.
//!
//! The behavioral tests live in `design_model_test.zig`. This file
//! only enforces the contracts between `tool_registry.zig` and
//! `design_tools.zig`:
//!
//!   1. `tool_registry.zig` imports `design_tools_mod = nalar_mod.design_tools`
//!   2. The three tools are registered in `UNIFIED_TOOL_REGISTRY`
//!   3. The three tools are exposed to the LLM via `allAgentTools`
//!   4. Each tool's name + description are present in `design_tools.zig`
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 3).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/tool_registry.zig";
const DESIGN_TOOLS_PATH = "src/modules/agent/tools/design_tools.zig";
const ROOT_PATH = "src/root.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "root.zig imports design_tools" {
    const source = try readSource(testing.allocator, ROOT_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "@import(\"modules/agent/tools/design_tools.zig\")") == null) {
        std.debug.print("!! {s} does not re-export design_tools !!\n", .{ROOT_PATH});
        return error.DesignToolsExportMissing;
    }
}

test "tool_registry.zig imports design_tools_mod" {
    const source = try readSource(testing.allocator, TOOL_REGISTRY_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "design_tools_mod = nalar_mod.design_tools") == null) {
        std.debug.print("!! {s} does not alias nalar_mod.design_tools !!\n", .{TOOL_REGISTRY_PATH});
        return error.DesignToolsModAliasMissing;
    }
}

test "tool_registry.zig registers set_design_page" {
    const source = try readSource(testing.allocator, TOOL_REGISTRY_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, ".name = \"set_design_page\"") == null) {
        std.debug.print("!! {s} does not register set_design_page !!\n", .{TOOL_REGISTRY_PATH});
        return error.SetDesignPageRegistrationMissing;
    }
}

test "tool_registry.zig registers delete_design_page" {
    const source = try readSource(testing.allocator, TOOL_REGISTRY_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, ".name = \"delete_design_page\"") == null) {
        std.debug.print("!! {s} does not register delete_design_page !!\n", .{TOOL_REGISTRY_PATH});
        return error.DeleteDesignPageRegistrationMissing;
    }
}

test "tool_registry.zig registers list_design_pages" {
    const source = try readSource(testing.allocator, TOOL_REGISTRY_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, ".name = \"list_design_pages\"") == null) {
        std.debug.print("!! {s} does not register list_design_pages !!\n", .{TOOL_REGISTRY_PATH});
        return error.ListDesignPagesRegistrationMissing;
    }
}

test "tool_registry.zig exposes design tools to the LLM via allAgentTools" {
    const source = try readSource(testing.allocator, TOOL_REGISTRY_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "design_tools_mod.set_design_page_tool") == null or
        std.mem.indexOf(u8, source, "design_tools_mod.delete_design_page_tool") == null or
        std.mem.indexOf(u8, source, "design_tools_mod.list_design_pages_tool") == null)
    {
        std.debug.print("!! {s} does not expose all 3 design tools in allAgentTools !!\n", .{TOOL_REGISTRY_PATH});
        return error.AllAgentToolsIncomplete;
    }
}

test "design_tools.zig declares all 3 AgentTool definitions" {
    const source = try readSource(testing.allocator, DESIGN_TOOLS_PATH);
    defer testing.allocator.free(source);
    const required = [_][]const u8{
        "set_design_page_tool",
        "delete_design_page_tool",
        "list_design_pages_tool",
    };
    for (required) |name| {
        if (std.mem.indexOf(u8, source, name) == null) {
            std.debug.print("!! {s} does not declare {s} !!\n", .{ DESIGN_TOOLS_PATH, name });
            return error.AgentToolDefinitionMissing;
        }
    }
}

test "design_tools.zig references on_event_sent_design for SSE" {
    const source = try readSource(testing.allocator, DESIGN_TOOLS_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "onEventSendDesignPageUpdated") == null or
        std.mem.indexOf(u8, source, "onEventSendDesignPageDeleted") == null)
    {
        std.debug.print("!! {s} does not reference both design SSE emitters !!\n", .{DESIGN_TOOLS_PATH});
        return error.SseEmitterMissing;
    }
}