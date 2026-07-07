//! Static regression checks for the set_design_element tool.
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 3, Tool 3.2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const TOOL_PATH = "src/modules/agent/tools/design_page_elements.zig";
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

test "set_design_element tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".name = \"set_design_element\"") == null) {
        std.debug.print("!! design_page_elements.zig does not define the tool with .name = 'set_design_element' !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "set_design_element tool description mentions file storage" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".nalar/design/") == null) {
        std.debug.print("!! set_design_element description does not mention .nalar/design/ path !!\n", .{});
        return error.FilePathHintMissing;
    }
}

test "set_design_element input struct has page_id, name, html" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    for ([_][]const u8{ "page_id", "name", "html", "x", "y", "width", "height", "z_index" }) |f| {
        if (std.mem.indexOf(u8, source, f) == null) {
            std.debug.print("!! SetDesignElementInput may be missing '{s}' !!\n", .{f});
            return error.InputFieldMissing;
        }
    }
}

test "set_design_element calls design_model.addElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.addElement") == null) {
        std.debug.print("!! set_design_element does not call design_model.addElement !!\n", .{});
        return error.AddElementCallMissing;
    }
}

test "tool_registry.zig imports design_page_elements module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "const design_page_elements_mod = nalar_mod.design_page_elements;") == null) {
        std.debug.print("!! tool_registry.zig does not bind design_page_elements_mod !!\n", .{});
        return error.DesignPageElementsModBindingMissing;
    }
}

test "tool_registry.zig defines execSetDesignElement + UNIFIED registry + allAgentTools" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub fn execSetDesignElement(") == null) {
        std.debug.print("!! tool_registry.zig does not define pub fn execSetDesignElement !!\n", .{});
        return error.ExecSetDesignElementMissing;
    }
    if (std.mem.indexOf(u8, source, ".name = \"set_design_element\"") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY missing set_design_element entry !!\n", .{});
        return error.RegistryNameMissing;
    }
    if (std.mem.indexOf(u8, source, ".exec = execSetDesignElement") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry missing .exec = execSetDesignElement !!\n", .{});
        return error.RegistryExecMissing;
    }
    if (std.mem.indexOf(u8, source, ".tool_def = design_page_elements_mod.set_design_element_tool") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry missing .tool_def binding !!\n", .{});
        return error.RegistryToolDefMissing;
    }
    if (std.mem.indexOf(u8, source, "design_page_elements_mod.set_design_element_tool,") == null) {
        std.debug.print("!! allAgentTools comptime list missing set_design_element !!\n", .{});
        return error.AllAgentToolsMissing;
    }
}

test "nalarcore root.zig exposes design_page_elements module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, ROOT_ZIG_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub const design_page_elements = @import(\"modules/agent/tools/design_page_elements.zig\");") == null) {
        std.debug.print("!! root.zig does not expose design_page_elements !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}
