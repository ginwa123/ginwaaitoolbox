const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const read_file_mod = tree1_mod.read_file;
const tool_models = tree1_mod.tool_models;

/// Stateless read_file tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Read file with options
/// Returns XML-wrapped result with path and content.
///
/// All side effects (DB, logging, socket, message list) must be handled by caller.
pub fn handle_read_file_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to ReadFileInput
    const parsed = try std.json.parseFromSlice(
        tool_models.ReadFileInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const read_opts = read_file_mod.ReadFileOptions{
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
        .show_line_numbers = parsed.value.show_line_numbers,
    };

    const read_result = try read_file_mod.read_file(allocator, parsed.value.path, read_opts);
    defer read_result.deinit(allocator);

    const res_content = try read_file_mod.readFileToString(allocator, read_result);

    // Wrap result in XML with path for proper TUI display
    const xml_result = try std.fmt.allocPrint(allocator,
        \\<path>{s}</path><content>{s}</content>
    , .{
        parsed.value.path,
        res_content,
    });

    // Caller is responsible for freeing this returned string
    return xml_result;
}

// test {
//     _ = @import("handle_read_file_tool_test.zig");
// }
