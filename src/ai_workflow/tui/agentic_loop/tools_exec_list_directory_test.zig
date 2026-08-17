// src/ai_workflow/tui/agentic_loop/tools_exec_list_directory_test.zig
//
// Regression test: the list_directory exec wrapper must reject
// absolute paths (security policy) and return a clear error envelope.
// Mirrors tools_exec_bash_test.zig.

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const testing = std.testing;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const execListDirectory = @import("tools_exec_list_directory.zig").execListDirectory;

fn makeTestCtx(allocator: std.mem.Allocator) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test_session",
        .model = "test",
        .cwd = "/home/user/proj",
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .active_loops = undefined,
    };
}

test "execListDirectory: rejects absolute path with explanatory error envelope" {
    const alloc = testing.allocator;
    const ctx = makeTestCtx(alloc);

    const tool_call = agent.ToolCall{
        .id = "call_1",
        .type = "function",
        .function = .{
            .name = "list_directory",
            .arguments = "{\"path\":\"/etc\"}",
        },
    };

    const result = try execListDirectory(ctx, tool_call);
    defer alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "absolute paths are not allowed") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "list_directory") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "path") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "/etc") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "/home/user/proj") != null);
}

test "execListDirectory: omitted path does not trigger the validator (defaults to \".\")" {
    // Over-eager-validator guard: omitting path should fall through to
    // the resolver (which defaults to ctx.cwd_override ?? ctx.cwd).
    // The validator's specific envelope must NOT appear.
    const alloc = testing.allocator;
    const ctx = makeTestCtx(alloc);

    const tool_call = agent.ToolCall{
        .id = "call_2",
        .type = "function",
        .function = .{
            .name = "list_directory",
            .arguments = "{}",
        },
    };

    // The flow proceeds past the validator (because path is omitted),
    // hits `openDirAbsolute("/home/user/proj")` which exists on most
    // Linux test machines, and returns either success or an
    // unrelated error. Either way, the validator's specific envelope
    // must NOT appear.
    const result = execListDirectory(ctx, tool_call) catch |err| {
        std.debug.print("execListDirectory returned error (acceptable): {s}\n", .{@errorName(err)});
        return;
    };
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(std.mem.indexOf(u8, result.output, "absolute paths are not allowed") == null);
}
