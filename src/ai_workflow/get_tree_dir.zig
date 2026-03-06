const std = @import("std");
const tree1_mod = @import("tree1");
const tool_models = tree1_mod.tool_models;
const bash_tool = tree1_mod.bash_tool;
const bash_helper = tree1_mod.helperTool;


pub fn run(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const treeBashInput = tool_models.BashInput{
        .command = "tree",
        .cwd = cwd,
        .timeout = 30,
    };
    const treeDir = try bash_tool.executeBash(allocator, treeBashInput);
    const treeDirTrim = std.mem.trim(u8, treeDir, "\n");
    const treeDirStdout = bash_helper.extractTag(treeDirTrim, "stdout", allocator) orelse return "";
    return treeDirStdout;
}
