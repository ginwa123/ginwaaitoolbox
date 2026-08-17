// src/ai_workflow/tui/agentic_loop/tools_exec_bash_test.zig
//
// Regression tests for the bash exec wrapper's absolute-path validator.
// Mirrors the same shape for the underlying `path_security` unit tests
// in `src/modules/agent/tools/path_security_test.zig` — this is the
// end-to-end wrapper test (validator wired into the right place).
//
// We exercise the ERROR path only (validator rejects absolute cwd →
// returns without touching the DB / bash subprocess). The happy path
// would need a real SqliteBackend + active_loops, which is out of
// scope here; the unit tests in path_security_test.zig cover the
// resolver, and the existing bash.zig + shell.zig test suites cover
// the bash subprocess itself.

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const testing = std.testing;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const execBash = @import("tools_exec_bash.zig").execBash;

/// Build a minimal `ToolExecContext`. Only `allocator` and `cwd` are
/// read on the validation-only error path; the rest are stubbed with
/// `undefined` (safe because execBash returns before touching them).
fn makeTestCtx(allocator: std.mem.Allocator) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = undefined, // not reached on the validator error path
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
        // .cwd_override defaults to null (see tools.zig)
    };
}

test "execBash: rejects absolute cwd with explanatory error envelope" {
    const alloc = testing.allocator;
    const ctx = makeTestCtx(alloc);

    const tool_call = agent.ToolCall{
        .id = "call_1",
        .type = "function",
        .function = .{
            .name = "bash",
            .arguments = "{\"command\":\"echo hi\",\"cwd\":\"/etc\",\"mandatory_timeout\":5}",
        },
    };

    const result = try execBash(ctx, tool_call);
    defer alloc.free(result.output);

    // Validation succeeded → no DB / bash call; the error envelope wraps it.
    try testing.expect(result.output_allocated);

    // The envelope names the security rule, the rejected path, and the
    // active cwd — so the LLM can compute the relative path on retry.
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "absolute paths are not allowed") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "/etc") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "/home/user/proj") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "bash") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "cwd") != null);
}

test "execBash: omitted cwd does not trigger the validator" {
    // Guard against an over-eager validator that runs even when the
    // param is absent. With our `if (parsed.value.cwd) |cwd|` guard,
    // the validator is only called when cwd is present.
    //
    // We don't care about the happy-path success or any unrelated
    // error — only that the validator did NOT produce the "absolute
    // paths are not allowed" envelope.
    const alloc = testing.allocator;
    const ctx = makeTestCtx(alloc);

    const tool_call = agent.ToolCall{
        .id = "call_2",
        .type = "function",
        .function = .{
            .name = "bash",
            .arguments = "{\"command\":\"echo hi\",\"mandatory_timeout\":5}",
        },
    };

    const result = execBash(ctx, tool_call) catch |err| {
        // Any error is acceptable EXCEPT the validator's specific
        // shape — if the validator had fired, execBash returns
        // `ToolExecResult` (not an error). So catching here means
        // the validator didn't run.
        std.debug.print("execBash returned error (acceptable): {s}\n", .{@errorName(err)});
        return;
    };
    defer if (result.output_allocated) alloc.free(result.output);

    // If we got here without catching, the call returned successfully.
    // Either way, the validator's specific envelope must NOT appear.
    try testing.expect(std.mem.indexOf(u8, result.output, "absolute paths are not allowed") == null);
}
