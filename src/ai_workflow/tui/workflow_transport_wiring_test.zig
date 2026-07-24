//! Static-contract tests for the workflow.zig transport wiring (Agent.zig
//! vs Agent2.zig). Verifies that:
//!   - callDynamicAgentNew accepts a transport parameter
//!   - It branches on "custom_http" to instantiate Agent2 instead of Agent
//!   - The effective_transport resolver follows the same profile-fallback
//!     pattern as the other effective_* slices (api_key, model, base_url,
//!     url_style).
//!
//! Plan 2026-07-24-agent2-custom-http. Behavioural streaming tests against
//! a mock server are deferred (same GinwaServer-dep concern as the
//! Agent2.zig static-contract tests).

const std = @import("std");
const testing = std.testing;

const WORKFLOW_PATH = "src/ai_workflow/tui/workflow.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(4 * 1024 * 1024),
    );
}

test "workflow.zig: callDynamicAgentNew has a transport parameter" {
    const source = try readSource(testing.allocator, WORKFLOW_PATH);
    defer testing.allocator.free(source);

    // The signature must include a `transport: []const u8` argument
    // positioned just before `session_id` (matching the call-site order).
    try testing.expect(std.mem.indexOf(u8, source,
        \\transport: []const u8,
        \\    session_id: []const u8,
    ) != null or std.mem.indexOf(u8, source,
        \\url_style: []const u8,
        \\    transport: []const u8,
    ) != null);
}

test "workflow.zig: callDynamicAgentNew branches on custom_http to Agent2" {
    const source = try readSource(testing.allocator, WORKFLOW_PATH);
    defer testing.allocator.free(source);

    // The custom_http branch must instantiate Agent2, not Agent.
    try testing.expect(std.mem.indexOf(u8, source, "agent.Agent2.init(") != null);
    try testing.expect(std.mem.indexOf(u8, source, "agent.Agent2.AgentCall{") != null);
    try testing.expect(std.mem.indexOf(u8, source, "dynamic_agent2.callStreaming(") != null);

    // The custom_http branch must be guarded by an eql check on the
    // transport string.
    try testing.expect(std.mem.indexOf(u8, source, "std.mem.eql(u8, selected_transport, \"custom_http\")") != null);
}

test "workflow.zig: callDynamicAgentNew default path stays on Agent.zig" {
    const source = try readSource(testing.allocator, WORKFLOW_PATH);
    defer testing.allocator.free(source);

    // The default (non-custom_http) path must still instantiate Agent.zig.
    try testing.expect(std.mem.indexOf(u8, source, "agent.Agent.init(allocator, io)") != null);
    try testing.expect(std.mem.indexOf(u8, source, "dynamic_agent.callStreaming(") != null);
}

test "workflow.zig: effective_transport resolver exists with profile-fallback pattern" {
    const source = try readSource(testing.allocator, WORKFLOW_PATH);
    defer testing.allocator.free(source);

    // The resolver block must:
    //  1. Be a `const` (not `var` — the value isn't reassigned downstream).
    //  2. Read profile.transport first when selected_profile_model is set.
    //  3. Fall back to config.transport.
    try testing.expect(std.mem.indexOf(u8, source, "const effective_transport: []const u8 = blk: {") != null);
    try testing.expect(std.mem.indexOf(u8, source, "if (profile.transport.len > 0) break :blk profile.transport;") != null);
    try testing.expect(std.mem.indexOf(u8, source, "break :blk config.transport;") != null);
}

test "workflow.zig: effective_transport is passed to callDynamicAgentNew" {
    const source = try readSource(testing.allocator, WORKFLOW_PATH);
    defer testing.allocator.free(source);

    // The call site must include effective_transport as the 10th positional
    // argument (after url_style, before session_id).
    try testing.expect(std.mem.indexOf(u8, source,
        \\effective_url_style, effective_transport, copy_session_id, merged_tools
    ) != null);
}
