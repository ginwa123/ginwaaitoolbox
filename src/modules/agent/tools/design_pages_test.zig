//! Static regression checks for the set_design_page tool.
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 3, Tool 3.1)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const TOOL_PATH = "src/modules/agent/tools/design_pages.zig";
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/tool_registry.zig";
const ROOT_ZIG_PATH = "src/root.zig";

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

// ─── Tool definition ──────────────────────────────────────────────

test "set_design_page tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".name = \"set_design_page\"") == null) {
        std.debug.print("!! design_pages.zig does not define the tool with .name = 'set_design_page' !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "set_design_page tool description mentions file storage" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".nalar/design/") == null) {
        std.debug.print("!! set_design_page description does not mention .nalar/design/ path !!\n", .{});
        return error.FilePathHintMissing;
    }
}

test "set_design_page input struct has item_id + name + geometry" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    const fields = [_][]const u8{ "item_id", "name", "width", "height", "x", "y" };
    for (fields) |f| {
        if (std.mem.indexOf(u8, source, f) == null) {
            std.debug.print("!! SetDesignPageInput may be missing '{s}' !!\n", .{f});
            return error.InputFieldMissing;
        }
    }
}

test "set_design_page calls design_model.addPage" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.addPage") == null) {
        std.debug.print("!! set_design_page does not call design_model.addPage !!\n", .{});
        return error.AddPageCallMissing;
    }
}

// ─── Tool registry wiring ──────────────────────────────────────────

test "tool_registry.zig imports design_pages module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "const design_pages_mod = nalar_mod.design_pages;") == null) {
        std.debug.print("!! tool_registry.zig does not bind design_pages_mod = nalar_mod.design_pages !!\n", .{});
        return error.DesignPagesModBindingMissing;
    }
}

test "tool_registry.zig defines execSetDesignPage" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub fn execSetDesignPage(") == null) {
        std.debug.print("!! tool_registry.zig does not define pub fn execSetDesignPage !!\n", .{});
        return error.ExecSetDesignPageMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains set_design_page entry" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".name = \"set_design_page\"") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the set_design_page name entry !!\n", .{});
        return error.RegistryNameEntryMissing;
    }
    if (std.mem.indexOf(u8, source, ".exec = execSetDesignPage") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = execSetDesignPage !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (std.mem.indexOf(u8, source, ".tool_def = design_pages_mod.set_design_page_tool") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def binding !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains set_design_page tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_pages_mod.set_design_page_tool,") == null) {
        std.debug.print("!! allAgentTools is missing design_pages_mod.set_design_page_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "nalarcore root.zig exposes design_pages module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, ROOT_ZIG_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub const design_pages = @import(\"modules/agent/tools/design_pages.zig\");") == null) {
        std.debug.print("!! root.zig does not expose design_pages as a top-level module !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}
