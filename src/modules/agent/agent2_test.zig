//! Static-contract tests for Agent2.zig.
//!
//! These tests grep Agent2.zig's source to verify:
//!   - The file exists and exposes the Agent2 struct.
//!   - It imports custom_http_client (libcurl) and uses its Client.
//!   - It does NOT fall back to std.http.Client.
//!   - The StreamWatchdog / apply_tcp_keepalive / KEEPIDLE watchdog machinery
//!     from Agent.zig was deleted (not left as dead code).
//!   - All the public types Agent.zig exposes are also present in Agent2.zig
//!     (so callers can swap Agent ↔ Agent2 with no API change).
//!   - Both OpenAI and Anthropic request builders exist.
//!   - The Anthropic URL is the correct /v1/messages (Agent.zig uses /messages,
//!     a pre-existing bug we don't replicate).
//!
//! Behavioural streaming tests are deferred — they need a GinwaServer fixture
//! (see custom_http_client/src/streaming_test.zig for the pattern), which is
//! a separate module-dep wiring concern.

const std = @import("std");
const testing = std.testing;
const Agent2 = @import("Agent2.zig");

const AGENT2_PATH = "src/modules/agent/Agent2.zig";
const TEST_RUNNER_PATH = "src/modules/agent/test_runner.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(4 * 1024 * 1024),
    );
}

test "Agent2.zig exists" {
    const source = try readSource(testing.allocator, AGENT2_PATH);
    defer testing.allocator.free(source);
    try testing.expect(source.len > 100);
}

test "Agent2.zig exposes Agent2 struct (not Agent)" {
    const source = try readSource(testing.allocator, AGENT2_PATH);
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "pub const Agent2 = struct") != null);
    // The legacy Agent struct should NOT exist (it's been renamed).
    try testing.expect(std.mem.indexOf(u8, source, "pub const Agent = struct") == null);
}

test "Agent2.zig uses custom_http_client (no std.http.Client fallback)" {
    const source = try readSource(testing.allocator, AGENT2_PATH);
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "@import(\"custom_http_client\")") != null);
    try testing.expect(std.mem.indexOf(u8, source, "client: custom_http_client.Client") != null);
    // Zero std.http.Client references — the file is a clean transport swap.
    try testing.expect(std.mem.indexOf(u8, source, "std.http.Client") == null);
}

test "Agent2.zig has no StreamWatchdog / keepalive leftovers" {
    const source = try readSource(testing.allocator, AGENT2_PATH);
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "StreamWatchdog") == null);
    try testing.expect(std.mem.indexOf(u8, source, "apply_tcp_keepalive") == null);
    try testing.expect(std.mem.indexOf(u8, source, "KEEPIDLE") == null);
    try testing.expect(std.mem.indexOf(u8, source, "KEEPALIVE") == null);
}

test "Agent2.zig re-exports the same public types as Agent.zig" {
    const source = try readSource(testing.allocator, AGENT2_PATH);
    defer testing.allocator.free(source);

    // Each pub const that should be present in Agent2.zig (either defined
    // locally or aliased from common types).
    const required = [_][]const u8{
        "pub const ContentPart",
        "pub const ImageUrl",
        "pub const ToolCall",
        "pub const FinishReason",
        "pub const AgentMessage",
        "pub const Usage",
        "pub const StreamChunk",
        "pub const StreamingAggregator",
        "pub const AgentCall",
        "pub const HttpOptions",
        "pub const CallResponse",
        "pub const Role",
        "pub const CallError",
    };
    for (required) |needle| {
        try testing.expect(std.mem.indexOf(u8, source, needle) != null);
    }
}

test "Agent2.zig has both buildJsonOpenAIRequest and buildJsonAnthropicRequest" {
    const source = try readSource(testing.allocator, AGENT2_PATH);
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "pub fn buildJsonOpenAIRequest") != null);
    try testing.expect(std.mem.indexOf(u8, source, "pub fn buildJsonAnthropicRequest") != null);
}

test "Agent2.zig uses correct Anthropic URL (/v1/messages, not /messages)" {
    const source = try readSource(testing.allocator, AGENT2_PATH);
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "/v1/messages") != null);
}

test "Agent2.zig is registered in test_runner.zig" {
    const source = try readSource(testing.allocator, TEST_RUNNER_PATH);
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "@import(\"agent2_test.zig\")") != null);
}

test "Agent2.zig is exposed via the agent2 module (root.zig re-export)" {
    const agent2_mod = @import("Agent2.zig");
    _ = agent2_mod.Agent2;
    // Just ensure compile — if Agent2 isn't there, the import fails.
}
