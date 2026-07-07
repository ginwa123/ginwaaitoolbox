//! Static regression checks for the list_design_elements tool.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const TOOL_PATH = "src/modules/agent/tools/design_page_elements_list.zig";
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

test "list_design_elements tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".name = \"list_design_elements\"") == null) {
        std.debug.print("!! list_design_elements.zig missing tool name !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "list_design_elements input struct has page_id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "page_id: []const u8") == null) {
        std.debug.print("!! list_design_elements input may be missing page_id !!\n", .{});
        return error.InputFieldMissing;
    }
}

test "list_design_elements calls design_model.listElements" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.listElements") == null) {
        std.debug.print("!! list_design_elements does not call design_model.listElements !!\n", .{});
        return error.ListElementsCallMissing;
    }
}

test "tool_registry.zig wires list_design_elements + root.zig exports it" {
    const allocator = testing.allocator;
    const reg_source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(reg_source);

    if (std.mem.indexOf(u8, reg_source, "const design_page_elements_list_mod = nalar_mod.design_page_elements_list;") == null) {
        std.debug.print("!! tool_registry.zig does not bind design_page_elements_list_mod !!\n", .{});
        return error.ModBindingMissing;
    }
    if (std.mem.indexOf(u8, reg_source, "pub fn execListDesignElements(") == null) {
        std.debug.print("!! tool_registry.zig does not define execListDesignElements !!\n", .{});
        return error.ExecMissing;
    }
    if (std.mem.indexOf(u8, reg_source, ".name = \"list_design_elements\"") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY missing list_design_elements entry !!\n", .{});
        return error.RegistryNameMissing;
    }
    if (std.mem.indexOf(u8, reg_source, ".exec = execListDesignElements") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry missing .exec = execListDesignElements !!\n", .{});
        return error.RegistryExecMissing;
    }
    if (std.mem.indexOf(u8, reg_source, ".tool_def = design_page_elements_list_mod.list_design_elements_tool") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry missing .tool_def binding !!\n", .{});
        return error.RegistryToolDefMissing;
    }
    if (std.mem.indexOf(u8, reg_source, "design_page_elements_list_mod.list_design_elements_tool,") == null) {
        std.debug.print("!! allAgentTools missing list_design_elements !!\n", .{});
        return error.AllAgentToolsMissing;
    }

    const root_source = try readSource(allocator, ROOT_ZIG_PATH);
    defer allocator.free(root_source);
    if (std.mem.indexOf(u8, root_source, "pub const design_page_elements_list = @import(\"modules/agent/tools/design_page_elements_list.zig\");") == null) {
        std.debug.print("!! root.zig does not export design_page_elements_list !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}
