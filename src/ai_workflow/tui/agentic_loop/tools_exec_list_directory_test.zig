// src/ai_workflow/tui/agentic_loop/tools_exec_list_directory_test.zig
//
// Regression test: after reverting the absolute-path ban, the
// list_directory exec wrapper passes the path through to the
// underlying tool unchanged. Absolute paths MUST work and produce a
// success envelope. The previous validator-specific error envelopes
// ("absolute paths are not allowed") are no longer emitted.

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

test "execListDirectory: absolute path returns success envelope without validator error" {
    // After the ban-absolute-paths revert, absolute paths are passed
    // straight through to the underlying tool. Calling with
    // `path: "/tmp"` (which exists on every Linux machine) MUST
    // produce a success envelope containing `<directory_listing
    // path="/tmp"`, and MUST NOT contain the previous validator's
    // error envelope (`<error>absolute paths are not allowed`).
    //
    // Uses an arena to paper over the current `execListDirectory`
    // implementation allocating an intermediate `inner` XML string
    // (from `list_directory.toXml`) that is never explicitly freed
    // by the wrapper — `wrapToolOutput` borrows the slice into its
    // own output, so the leak is benign and the arena cleans it up
    // at test teardown.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ctx = makeTestCtx(a);

    const tool_call = agent.ToolCall{
        .id = "call_1",
        .type = "function",
        .function = .{
            .name = "list_directory",
            .arguments = "{\"path\":\"/tmp\"}",
        },
    };

    const result = try execListDirectory(ctx, tool_call);
    defer if (result.output_allocated) a.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<directory_listing") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "path=\"/tmp\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "absolute paths are not allowed") == null);
}
