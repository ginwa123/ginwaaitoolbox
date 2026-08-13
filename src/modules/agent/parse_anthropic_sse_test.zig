// Tests for the Anthropic /v1/messages SSE parser + the raw-SSE sample
// capture added to Agent.callStreaming. Companion to
// `docs/superpowers/plans/2026-08-13-anthropic-profile-sse-parsing.md`.
//
// Why these are unit tests (not network tests): the existing
// `call_streaming_test.zig` has 3 tests that actually instantiate
// `Agent.callStreaming` and ALL THREE are marked
// `if (true) return error.SkipZigTest;` — `Agent.deinit` hangs in
// `std.Io.Threaded.closeFd` after a real HTTP roundtrip, which is a
// pre-existing issue unrelated to this plan. So end-to-end network
// tests for callStreaming can't run in this CI.
//
// To still get real coverage, we test the units that ARE reachable:
//   1. `Agent.parse_stream_chunk(data, arena)` — the public
//      SSE-line → StreamChunk mapper. We pass crafted JSON data
//      strings directly. No network, no hang.
//   2. `Agent.parse_anthropic_stream_chunk(...)` — the new sibling
//      parser, reached via the public dispatcher on
//      `parse_stream_chunk` when `UrlStyle = "anthropic"`.
//   3. Part A (raw SSE capture) is verified by a static-contract
//      test that inspects the source for the three required sites
//      (buffer declaration, append on null parse, surface in final
//      error message).
//
// All tests are deterministic and run in <1s.

const std = @import("std");
const agent = @import("nalarcore").agent;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;

// ============================================================================
// Part B — parse_stream_chunk for Anthropic SSE
// ============================================================================

test "parse_stream_chunk (anthropic): message_start caches input_tokens, emits no chunk" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    const data =
        \\{"type":"message_start","message":{"id":"msg_x","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":42,"output_tokens":1}}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const chunk = a.parse_stream_chunk(data, arena.allocator());
    // message_start is a pure cache step — no chunk emitted.
    try expect(chunk == null);
}

test "parse_stream_chunk (anthropic): content_block_delta text_delta populates content" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // First emit a message_start so the input_tokens cache gets populated.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    var arena2 = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena2.deinit();

    const delta_data =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello world"}}
    ;
    const chunk = a.parse_stream_chunk(delta_data, arena2.allocator());
    try expect(chunk != null);
    try expectEqualStrings("Hello world", chunk.?.content.?);
    try expect(chunk.?.tool_calls_delta == null);
    try expect(chunk.?.finish_reason == null);
}

test "parse_stream_chunk (anthropic): thinking_delta populates reasoning_content" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const data =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"step 1"}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expectEqualStrings("step 1", chunk.?.reasoning_content.?);
}

test "parse_stream_chunk (anthropic): content_block_start (tool_use) emits tool_calls_delta with id+name" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const data =
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_abc","name":"bash","input":{}}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expect(chunk.?.tool_calls_delta != null);
    try expectEqual(@as(usize, 1), chunk.?.tool_calls_delta.?.len);
    try expectEqualStrings("toolu_abc", chunk.?.tool_calls_delta.?[0].id.?);
    try expectEqualStrings("bash", chunk.?.tool_calls_delta.?[0].function_name.?);
}

test "parse_stream_chunk (anthropic): input_json_delta appends to tool_calls_delta arguments" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const data =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"ls\"}"}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expect(chunk.?.tool_calls_delta != null);
    try expectEqual(@as(usize, 1), chunk.?.tool_calls_delta.?.len);
    try expectEqualStrings("{\"command\":\"ls\"}", chunk.?.tool_calls_delta.?[0].function_arguments.?);
}

test "parse_stream_chunk (anthropic): message_delta stop_reason=end_turn → finish_reason=.stop" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":5}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expectEqual(@as(?agent.FinishReason, .stop), chunk.?.finish_reason);
}

test "parse_stream_chunk (anthropic): message_delta stop_reason=tool_use → finish_reason=.tool_calls" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expectEqual(@as(?agent.FinishReason, .tool_calls), chunk.?.finish_reason);
}

test "parse_stream_chunk (anthropic): message_delta stop_reason=max_tokens → finish_reason=.length" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expectEqual(@as(?agent.FinishReason, .length), chunk.?.finish_reason);
}

test "parse_stream_chunk (anthropic): message_delta stop_reason=refusal → finish_reason=.content_filter" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expectEqual(@as(?agent.FinishReason, .content_filter), chunk.?.finish_reason);
}

test "parse_stream_chunk (anthropic): message_stop returns null (signal-only)" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const data = "{\"type\":\"message_stop\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk == null);
}

test "parse_stream_chunk (anthropic): content_block_stop returns null (signal-only)" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const data = "{\"type\":\"content_block_stop\",\"index\":0}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk == null);
}

test "parse_stream_chunk (anthropic): usage chunk emitted on first delta after message_start with input_tokens" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // Cache input_tokens via message_start.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":7,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // First delta should carry a usage chunk with prompt_tokens=7.
    var arena2 = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena2.deinit();

    const delta_data =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}
    ;
    const chunk = a.parse_stream_chunk(delta_data, arena2.allocator());
    try expect(chunk != null);
    try expect(chunk.?.usage != null);
    try expectEqual(@as(usize, 7), chunk.?.usage.?.prompt_tokens);
}

test "parse_stream_chunk (anthropic): usage emitted exactly once across multiple deltas" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // Cache input_tokens via message_start.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // First delta → usage chunk present.
    var arena1 = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena1.deinit();
    const d1 =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a"}}
    ;
    const c1 = a.parse_stream_chunk(d1, arena1.allocator());
    try expect(c1 != null);
    try expect(c1.?.usage != null);

    // Second delta → no usage chunk (already emitted).
    var arena2 = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena2.deinit();
    const d2 =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"b"}}
    ;
    const c2 = a.parse_stream_chunk(d2, arena2.allocator());
    try expect(c2 != null);
    try expect(c2.?.usage == null);
}

// ============================================================================
// Part B — OpenAI parser is NOT affected by the dispatch (regression check)
// ============================================================================

test "parse_stream_chunk (openai): OpenAI-shaped data still parses as before" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "openai"; // explicit

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const data =
        \\{"id":"chatcmpl-x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"hello"}}]}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expectEqualStrings("hello", chunk.?.content.?);
}

test "parse_stream_chunk (default UrlStyle): falls through to OpenAI parser" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    // Don't set UrlStyle — it's "" by default. Should behave like openai.

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const data =
        \\{"id":"chatcmpl-x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"world"}}]}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expectEqualStrings("world", chunk.?.content.?);
}

// ============================================================================
// Part A — Raw SSE sample capture (structural contract test)
//
// We can't run callStreaming end-to-end here (Agent.deinit hangs after a
// real HTTP roundtrip — see call_streaming_test.zig:415-441 for the
// root cause). Instead we verify by source inspection that:
//   1. callStreaming builds a raw_sse_sample buffer
//   2. The buffer is appended when parse_stream_chunk returns null AND
//      chunk_count == 0
//   3. The final-error message includes a truncated sample
// These are the three sites that must change together — a regression
// in any one would re-hide the server's actual payload.
// ============================================================================

const AGENT_SOURCE_PATH = "src/modules/agent/Agent.zig";

test "callStreaming captures raw SSE sample when chunk_count stays at 0 (structural contract)" {
    const source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        AGENT_SOURCE_PATH,
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| {
        std.debug.print("!! cannot read {s}: {{}} !!\n", .{AGENT_SOURCE_PATH});
        return err;
    };
    defer std.testing.allocator.free(source);

    // Contract 1: raw_sse_sample buffer must be declared in callStreaming.
    if (std.mem.indexOf(u8, source, "raw_sse_sample") == null) {
        std.debug.print(
            "!! {s} does not declare `raw_sse_sample` — Part A (raw SSE sample capture) regressed !!\n",
            .{AGENT_SOURCE_PATH},
        );
        return error.RawSseSampleBufferMissing;
    }

    // Contract 2: max_raw_sse_sample_len must be defined (we use 2 KiB).
    if (std.mem.indexOf(u8, source, "max_raw_sse_sample_len") == null) {
        std.debug.print(
            "!! {s} does not define `max_raw_sse_sample_len` — sample cap is missing !!\n",
            .{AGENT_SOURCE_PATH},
        );
        return error.MaxRawSseSampleLenMissing;
    }

    // Contract 3: the buffer must be appended in the parse_stream_chunk
    // null branch, gated on chunk_count == 0.
    const append_pattern = "raw_sse_sample.appendSlice";
    if (std.mem.indexOf(u8, source, append_pattern) == null) {
        std.debug.print(
            "!! {s} does not call `raw_sse_sample.appendSlice` — sample is never captured !!\n",
            .{AGENT_SOURCE_PATH},
        );
        return error.RawSseSampleAppendMissing;
    }
    if (std.mem.indexOf(u8, source, "chunk_count == 0") == null) {
        std.debug.print(
            "!! {s} does not gate the sample append on `chunk_count == 0` — would capture redundant data on every chunk !!\n",
            .{AGENT_SOURCE_PATH},
        );
        return error.ChunkCountGateMissing;
    }

    // Contract 4: the final error message must mention "first server lines"
    // so the user knows where to find the sample in the log.
    if (std.mem.indexOf(u8, source, "first server lines") == null) {
        std.debug.print(
            "!! {s} final-error message does not include 'first server lines' — the raw sample is captured but not surfaced !!\n",
            .{AGENT_SOURCE_PATH},
        );
        return error.FirstServerLinesLabelMissing;
    }
}

// ============================================================================
// Part B — Anthropic parser structural contract (regression check)
// ============================================================================

test "Agent.zig defines parse_anthropic_stream_chunk (structural contract)" {
    const source = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        AGENT_SOURCE_PATH,
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| {
        std.debug.print("!! cannot read {s}: {{}} !!\n", .{AGENT_SOURCE_PATH});
        return err;
    };
    defer std.testing.allocator.free(source);

    // Contract 1: the new function must exist.
    if (std.mem.indexOf(u8, source, "parse_anthropic_stream_chunk") == null) {
        std.debug.print(
            "!! {s} does not define `parse_anthropic_stream_chunk` — Part B (Anthropic SSE parser) regressed !!\n",
            .{AGENT_SOURCE_PATH},
        );
        return error.ParseAnthropicStreamChunkMissing;
    }

    // Contract 2: the dispatcher must branch on UrlStyle.
    if (std.mem.indexOf(u8, source, "self.UrlStyle") == null) {
        std.debug.print(
            "!! {s} does not reference `self.UrlStyle` — UrlStyle dispatch is missing !!\n",
            .{AGENT_SOURCE_PATH},
        );
        return error.UrlStyleDispatchMissing;
    }

    // Contract 3: stop_reason mapping helper must exist.
    if (std.mem.indexOf(u8, source, "map_anthropic_stop_reason") == null) {
        std.debug.print(
            "!! {s} does not define `map_anthropic_stop_reason` — Anthropic→OpenAI stop_reason translation is missing !!\n",
            .{AGENT_SOURCE_PATH},
        );
        return error.StopReasonMappingMissing;
    }

    // Contract 4: input_tokens cache field on Agent.
    if (std.mem.indexOf(u8, source, "_anthropic_input_tokens") == null) {
        std.debug.print(
            "!! {s} does not declare `_anthropic_input_tokens` — input_tokens cache is missing !!\n",
            .{AGENT_SOURCE_PATH},
        );
        return error.InputTokensCacheMissing;
    }

    // Contract 5: usage-emitted-once flag on Agent.
    if (std.mem.indexOf(u8, source, "_anthropic_usage_emitted") == null) {
        std.debug.print(
            "!! {s} does not declare `_anthropic_usage_emitted` — usage-chunk-once guard is missing !!\n",
            .{AGENT_SOURCE_PATH},
        );
        return error.UsageEmittedFlagMissing;
    }
}