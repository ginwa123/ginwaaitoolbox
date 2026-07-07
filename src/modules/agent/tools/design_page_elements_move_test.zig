//! Static regression checks for the move_design_element tool.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const TOOL_PATH = "src/modules/agent/tools/design_page_elements_move.zig";
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

test "move_design_element tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".name = \"move_design_element\"") == null) {
        std.debug.print("!! move_design_element.zig does not define the tool with .name = 'move_design_element' !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "move_design_element input struct has element_id, x, y" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    for ([_][]const u8{ "element_id", "x", "y" }) |f| {
        if (std.mem.indexOf(u8, source, f) == null) {
            std.debug.print("!! MoveDesignElementInput may be missing '{s}' !!\n", .{f});
            return error.InputFieldMissing;
        }
    }
}

test "move_design_element calls design_model.moveElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.moveElement") == null) {
        std.debug.print("!! move_design_element does not call design_model.moveElement !!\n", .{});
        return error.MoveElementCallMissing;
    }
}

test "tool_registry.zig wires move_design_element + root.zig exports it" {
    const allocator = testing.allocator;
    const reg_source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(reg_source);

    if (std.mem.indexOf(u8, reg_source, "const design_page_elements_move_mod = nalar_mod.design_page_elements_move;") == null) {
        std.debug.print("!! tool_registry.zig does not bind design_page_elements_move_mod !!\n", .{});
        return error.ModBindingMissing;
    }
    if (std.mem.indexOf(u8, reg_source, "pub fn execMoveDesignElement(") == null) {
        std.debug.print("!! tool_registry.zig does not define execMoveDesignElement !!\n", .{});
        return error.ExecMissing;
    }
    if (std.mem.indexOf(u8, reg_source, ".name = \"move_design_element\"") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY missing move_design_element entry !!\n", .{});
        return error.RegistryNameMissing;
    }
    if (std.mem.indexOf(u8, reg_source, ".exec = execMoveDesignElement") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry missing .exec = execMoveDesignElement !!\n", .{});
        return error.RegistryExecMissing;
    }
    if (std.mem.indexOf(u8, reg_source, ".tool_def = design_page_elements_move_mod.move_design_element_tool") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry missing .tool_def binding !!\n", .{});
        return error.RegistryToolDefMissing;
    }
    if (std.mem.indexOf(u8, reg_source, "design_page_elements_move_mod.move_design_element_tool,") == null) {
        std.debug.print("!! allAgentTools missing move_design_element !!\n", .{});
        return error.AllAgentToolsMissing;
    }

    const root_source = try readSource(allocator, ROOT_ZIG_PATH);
    defer allocator.free(root_source);
    if (std.mem.indexOf(u8, root_source, "pub const design_page_elements_move = @import(\"modules/agent/tools/design_page_elements_move.zig\");") == null) {
        std.debug.print("!! root.zig does not export design_page_elements_move !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}
