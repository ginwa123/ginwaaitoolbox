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

// ===== Regression test for 2026-08-15 "bash tool leak" ===============
//
// The user posted a leaked tool_call record with a bash `arguments`
// payload of literally `$'\xaa\xaa\xaa...'` (22 bytes of 0xAA — Zig's
// DebugAllocator free-fill byte, octal 252). Fix: make `CallResponse`
// arena-owned. Caller passes the per-iteration arena's allocator to
// `Agent.init`. The SSE parser allocates everything on that arena.
// `StreamingAggregator.finalize` returns slice headers that point
// straight at the arena — no copy, no separate `deinit`. Any
// accidental `free`-then-read under DebugAllocator would have
// produced the 0xAA poison the user observed.
//
// Pins the contract:
//   1. `process_chunk` stores inner bytes on the caller's arena.
//   2. `finalize` returns slice headers that point at the SAME arena
//      bytes (no second dupe).
//   3. Reading the returned bytes BEFORE the arena is destroyed
//      returns the real arguments — not 0xAA.
//   4. `CallResponse.deinit` is a documented no-op.
test "CallResponse arena ownership: tool_call.function.arguments points at caller's arena (no .deinit needed)" {
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var agg = agent.StreamingAggregator.init(arena_alloc);
    defer agg.deinit();

    // Stage 1: content_block_start arrives with id + name.
    try agg.process_chunk(.{
        .tool_calls_delta = &[_]agent.ToolCallDelta{.{
            .index = 0,
            .id = "toolu_leak_test",
            .function_name = "bash",
        }},
    });

    // Stage 2: two input_json_delta chunks concatenate to the bash
    // arguments JSON. Real Anthropic / OpenAI streams could carry
    // any byte sequence (including legitimate binary data with
    // 0xAA); the contract must hold regardless of payload content.
    const args_payload =
        \\{"command":"cd /tmp && echo hello","cwd":"/tmp"}
    ;
    try agg.process_chunk(.{
        .tool_calls_delta = &[_]agent.ToolCallDelta{.{
            .index = 0,
            .function_arguments = args_payload[0..20],
        }},
    });
    try agg.process_chunk(.{
        .tool_calls_delta = &[_]agent.ToolCallDelta{.{
            .index = 0,
            .function_arguments = args_payload[20..],
        }},
    });

    const response = try agg.finalize();
    defer response.deinit();

    try expect(response.tool_calls != null);
    try expectEqual(@as(usize, 1), response.tool_calls.?.len);
    const tc = &response.tool_calls.?[0];
    try expectEqualStrings("toolu_leak_test", tc.id);
    try expectEqualStrings("bash", tc.function.name);

    // CRITICAL: `tc.function.arguments` points at the same arena
    // memory the aggregator's internal `arguments` ArrayList holds.
    // Pre-fix the bytes would have been 0xAA (DebugAllocator free-
    // fill) because a per-inner-slice `free` fired before the
    // consumer read the bytes.
    try expectEqualStrings(args_payload, tc.function.arguments);

    // Belt-and-suspenders: pin the contract by asserting no
    // `0xAA` byte appears in the returned slice. Legitimate
    // ASCII/UTF-8/JSON cannot contain this byte.
    try expect(std.mem.indexOfScalar(u8, tc.function.arguments, 0xAA) == null);
}

// ===================================================================

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
// Anthropic usage handling — make total_tokens match OpenAI's semantic
// (prompt_tokens + completion_tokens) so llm_history / compaction
// code that consumes CallResponse.usage gets the same numbers it would
// from an OpenAI profile.
// ============================================================================

test "parse_stream_chunk (anthropic): message_delta usage emits total = input + output (strict API shape — no input in message_delta)" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start caches input_tokens=42 (canonical input — strict API).
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":42,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // message_delta with ONLY output_tokens (strict Anthropic API doesn't
    // repeat input_tokens here). prompt must stay 42 (from message_start),
    // total = 42 + 7.
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":7}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expect(chunk.?.usage != null);
    try expectEqual(@as(usize, 42), chunk.?.usage.?.prompt_tokens);
    try expectEqual(@as(usize, 7), chunk.?.usage.?.completion_tokens);
    try expectEqual(@as(usize, 49), chunk.?.usage.?.total_tokens);
}

test "parse_stream_chunk (anthropic): message_delta input_tokens OVERRIDES message_start (some relays send input=0 at message_start then correct value at message_delta)" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start with input_tokens=0 (this relay returns 0 here).
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // message_delta with the AUTHORITATIVE input_tokens=54 (this relay).
    // The handler must prefer this over the cached 0 from message_start.
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":54,"output_tokens":23}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expect(chunk.?.usage != null);
    try expectEqual(@as(usize, 54), chunk.?.usage.?.prompt_tokens);
    try expectEqual(@as(usize, 23), chunk.?.usage.?.completion_tokens);
    try expectEqual(@as(usize, 77), chunk.?.usage.?.total_tokens);
}

test "parse_stream_chunk (anthropic): message_delta includes cache_creation_input_tokens in total (cache writes ARE billable)" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start: input_tokens=10 (excludes cache_creation).
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // message_delta: cache_creation_input_tokens=5 (a cache write — billable).
    // billable total = 10 (input) + 5 (cache_creation) + 8 (output) = 23.
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"cache_creation_input_tokens":5,"output_tokens":8}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expect(chunk.?.usage != null);
    try expectEqual(@as(usize, 15), chunk.?.usage.?.prompt_tokens); // 10 + 5
    try expectEqual(@as(usize, 8), chunk.?.usage.?.completion_tokens);
    try expectEqual(@as(usize, 23), chunk.?.usage.?.total_tokens); // 15 + 8
}

test "parse_stream_chunk (anthropic): cache_read_input_tokens IS added to prompt + total (cache reads ARE tokens processed)" {
    // Mirrors the spec TL;DR: cache_read counts as tokens the model
    // processed, so prompt = input + cache_read and total = prompt +
    // completion. The cache breakdown is preserved separately on
    // `Usage` so billing code can still apply the discounted rate.
    //
    // Pre-fix: this test asserted prompt=54, total=77 (cache_read=128 was
    // dropped on the floor, matching the sibling-branch contract labelled
    // "FREE"). Post-fix: prompt=182 (54+128), total=205 (182+23). The
    // cache_read count is still 128 on the breakdown for billing.
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start: input_tokens=54, cache_read_input_tokens=128.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":54,"cache_read_input_tokens":128,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // message_delta: input_tokens=54 + cache_creation=0 + cache_read=128
    // (uses cached message_start value because delta omits it)
    // + output_tokens=23.
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":54,"output_tokens":23}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expect(chunk.?.usage != null);
    try expectEqual(@as(usize, 182), chunk.?.usage.?.prompt_tokens); // 54 + 0 + 128
    try expectEqual(@as(usize, 23), chunk.?.usage.?.completion_tokens);
    try expectEqual(@as(usize, 205), chunk.?.usage.?.total_tokens); // 182 + 23
    try expectEqual(@as(usize, 0), chunk.?.usage.?.cache_creation_input_tokens);
    try expectEqual(@as(usize, 128), chunk.?.usage.?.cache_read_input_tokens);
}

// ============================================================================
// Task 1 contract — Agent.Usage struct surface area. Pin the new
// Anthropic cache field names so Tasks 2 + 4 + 5 + 6 can lean on them.
// (OpenAI rows always carry 0 in both fields.)
// ============================================================================

test "Agent.Usage struct has cache_creation_input_tokens + cache_read_input_tokens fields (structural contract)" {
    const u: agent.Usage = .{};
    // New fields default to 0 — no breakage for OpenAI.
    try expectEqual(@as(usize, 0), u.cache_creation_input_tokens);
    try expectEqual(@as(usize, 0), u.cache_read_input_tokens);
    // Existing fields still work.
    try expectEqual(@as(usize, 0), u.prompt_tokens);
    try expectEqual(@as(usize, 0), u.completion_tokens);
    try expectEqual(@as(usize, 0), u.total_tokens);
}

test "Agent.Usage can be constructed with explicit cache values" {
    // Mirrors what parse_anthropic_stream_chunk emits at message_delta
    // when both cache fields are non-zero.
    const u: agent.Usage = .{
        .prompt_tokens = 6500,
        .completion_tokens = 1000,
        .total_tokens = 7500,
        .cache_creation_input_tokens = 500,
        .cache_read_input_tokens = 5000,
    };
    try expectEqual(@as(usize, 6500), u.prompt_tokens);
    try expectEqual(@as(usize, 1000), u.completion_tokens);
    try expectEqual(@as(usize, 7500), u.total_tokens);
    try expectEqual(@as(usize, 500), u.cache_creation_input_tokens);
    try expectEqual(@as(usize, 5000), u.cache_read_input_tokens);
}

test "parse_stream_chunk (anthropic): message_delta includes BOTH cache_creation AND cache_read in prompt + total" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start caches input_tokens=1000.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1000,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // message_delta: cache_creation=500, cache_read=5000, output=1000.
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":5000,"output_tokens":1000}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expect(chunk.?.usage != null);
    try expectEqual(@as(usize, 6500), chunk.?.usage.?.prompt_tokens);
    try expectEqual(@as(usize, 1000), chunk.?.usage.?.completion_tokens);
    try expectEqual(@as(usize, 7500), chunk.?.usage.?.total_tokens);
    try expectEqual(@as(usize, 500), chunk.?.usage.?.cache_creation_input_tokens);
    try expectEqual(@as(usize, 5000), chunk.?.usage.?.cache_read_input_tokens);
}

test "parse_stream_chunk (anthropic): cache_read_only is included in prompt + total" {
    // Cache reads ONLY (no cache writes) — prompt = input + cache_read.
    // Pre-fix this would have been `prompt = input = 10`, dropping the
    // 128 cached-read tokens on the floor.
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":10,"cache_read_input_tokens":128,"output_tokens":7}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expect(chunk != null);
    try expect(chunk.?.usage != null);
    try expectEqual(@as(usize, 138), chunk.?.usage.?.prompt_tokens); // 10 + 128
    try expectEqual(@as(usize, 7), chunk.?.usage.?.completion_tokens);
    try expectEqual(@as(usize, 145), chunk.?.usage.?.total_tokens);
    try expectEqual(@as(usize, 0), chunk.?.usage.?.cache_creation_input_tokens);
    try expectEqual(@as(usize, 128), chunk.?.usage.?.cache_read_input_tokens);
}

test "parse_stream_chunk (anthropic): cache_read from message_start is preserved on first-delta usage chunk" {
    // Some relays send cache_read_input_tokens at message_start but not at
    // message_delta. The first-delta usage chunk needs to fold that into
    // prompt_tokens, mirroring how message_delta folds it later.
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start: input_tokens=20 + cache_read_input_tokens=4096.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":20,"cache_read_input_tokens":4096,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // First delta emits a usage chunk. Prompt must be 20 + 0 + 4096 = 4116.
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const d1 =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}
    ;
    const chunk = a.parse_stream_chunk(d1, arena.allocator());
    try expect(chunk != null);
    try expect(chunk.?.usage != null);
    try expectEqual(@as(usize, 4116), chunk.?.usage.?.prompt_tokens);
    try expectEqual(@as(usize, 0), chunk.?.usage.?.completion_tokens);
    try expectEqual(@as(usize, 4116), chunk.?.usage.?.total_tokens);
    try expectEqual(@as(usize, 0), chunk.?.usage.?.cache_creation_input_tokens);
    try expectEqual(@as(usize, 4096), chunk.?.usage.?.cache_read_input_tokens);
}

test "Agent.Usage can be constructed with explicit cache values (regression pin at end-of-file)" {
    // Pinned at the END of the test file (in addition to the canonical
    // assertion at L436) so the contract surfaces under `rg` near any
    // future Anthropic-Usage changes. Both must pass.
    const u: agent.Usage = .{
        .prompt_tokens = 6500,
        .completion_tokens = 1000,
        .total_tokens = 7500,
        .cache_creation_input_tokens = 500,
        .cache_read_input_tokens = 5000,
    };
    try expectEqual(@as(usize, 6500), u.prompt_tokens);
    try expectEqual(@as(usize, 1000), u.completion_tokens);
    try expectEqual(@as(usize, 7500), u.total_tokens);
    try expectEqual(@as(usize, 500), u.cache_creation_input_tokens);
    try expectEqual(@as(usize, 5000), u.cache_read_input_tokens);
}

// ============================================================================
// Regression test — reproduce the iter-2 SEGV in buildJsonAnthropicRequest
// (the slice-header 0xAA-poisoning crash seen when an Anthropic chat hits
// iter 2 after the model emits tool_calls in iter 1). Build the request
// body directly with a synthetic assistant message that mirrors the shape
// loadHistoryFromDb produces, and assert the body is well-formed UTF-8 JSON.
// If this test crashes (segfault in utf8ValidateSlice) the underlying bug
// is reproduced without needing the full workflow + DB stack.
// ============================================================================

test "buildJsonAnthropicRequest: assistant message with tool_calls + null reasoning_content survives" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.model = "claude-test";
    a.UrlStyle = "anthropic";
    a.thinkingEnabled = true;
    a.userIdentifier = "test-user";

    // Simulate the DB-loaded shape for an assistant message that emitted
    // tool_calls in the previous iteration: reasoning_content is null,
    // content is empty, tool_calls_json has 1 tool call with id+name+args.
    const tc_args_json = "{\"query\":\"recent\"}";
    const tc_id_dup = try testing_allocator.dupe(u8, "toolu_test_123");
    defer testing_allocator.free(tc_id_dup);
    const tc_name_dup = try testing_allocator.dupe(u8, "load_memory");
    defer testing_allocator.free(tc_name_dup);
    const tc_args_dup = try testing_allocator.dupe(u8, tc_args_json);
    defer testing_allocator.free(tc_args_dup);
    const tc_array = try testing_allocator.alloc(agent.ToolCall, 1);
    defer testing_allocator.free(tc_array);
    tc_array[0] = .{
        .id = tc_id_dup,
        .function = .{
            .name = tc_name_dup,
            .arguments = tc_args_dup,
        },
    };

    // 3 messages: system + user + assistant-with-tool-calls.
    // Mirrors what workflow.zig's buildMessages produces for the second
    // iteration of an Anthropic chat that emitted tool_calls in iter 1.
    const system_content = try testing_allocator.dupe(u8, "You are a coding agent.");
    defer testing_allocator.free(system_content);
    const user_content = try testing_allocator.dupe(u8, "please look up memory");
    defer testing_allocator.free(user_content);

    const messages = try testing_allocator.alloc(agent.AgentMessage, 3);
    defer testing_allocator.free(messages);
    messages[0] = .{ .role = .system, .content = system_content };
    messages[1] = .{ .role = .user, .content = user_content };
    messages[2] = .{
        .role = .assistant,
        .content = "", // empty text content — model emitted only tool_calls
        .reasoning_content = null, // no thinking text emitted
        .tool_calls = tc_array,
    };

    const params = agent.AgentCall{ .messages = messages, .tools = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing_allocator.free(body);

    // If we got here without a SEGV, the slice-pointer corruption didn't
    // happen for this synthetic input. If this assertion never fires but
    // the workflow still crashes, the bug needs MORE than just an
    // assistant-with-tool-calls message to trigger — likely tied to
    // specific allocator lifetimes that only manifest under the real
    // workflow's arena setup.
    try expect(body.len > 100);
    try expect(std.mem.startsWith(u8, body, "{"));
}

// ============================================================================
// Part C — Anthropic request body preserves `image_url` content_parts
// (smoke test 2026-08-13: "i cannot send image" with profile `url_style:
// "anthropic"`. Symptom: model says "Sepertinya belum ada gambar yang
// masuk di percakapan ini — saya hanya melihat pesan teks saja" while
// the image is correctly stored in `llm_history.image_urls` and is
// displayed in the frontend UI.
// Root cause: `buildJsonAnthropicRequest` only emits `content` as a
// single-text string OR content_blocks (for assistant tool_use). It
// never reads `msg.content_parts`, so user-attached images are silently
// dropped before the wire.
// Fix: when `msg.content_parts` is set, build `AnthropicContentBlock`
// entries for each part — `text` → `{type:"text", text:...}` and
// `image_url` → `{type:"image", source:{type:"url", url:"data:..."}}`
// (Anthropic accepts the OpenAI-flavored `data:image/...;base64,...`
// URL via its `source.url` field; this matches what every OpenAI-
// compatible Anthropic relay like api.minimax.io/anthropic expects).
// ============================================================================

test "buildJsonAnthropicRequest: user message with image content_parts preserves the image URL" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.model = "claude-test";
    a.UrlStyle = "anthropic";
    a.thinkingEnabled = false;
    a.userIdentifier = "test-user";

    // Synthetic data: text + 1 image, mirroring what
    // `transformLLMHistoryToAgentMessage` produces from a DB row with
    // `image_urls` populated.
    const text_dup = try testing_allocator.dupe(u8, "ini gambar apa ?");
    defer testing_allocator.free(text_dup);
    const url_dup = try testing_allocator.dupe(
        u8,
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
    );
    defer testing_allocator.free(url_dup);

    const parts = try testing_allocator.alloc(agent.ContentPart, 2);
    defer testing_allocator.free(parts);
    parts[0] = .{
        .part_type = "text",
        .text = text_dup,
        .image_url = null,
    };
    parts[1] = .{
        .part_type = "image_url",
        .text = null,
        .image_url = .{ .url = url_dup, .detail = null },
    };

    const messages = try testing_allocator.alloc(agent.AgentMessage, 2);
    defer testing_allocator.free(messages);
    messages[0] = .{ .role = .system, .content = "You are a helpful assistant." };
    messages[1] = .{
        .role = .user,
        .content = null, // text lives in content_parts[0]
        .content_parts = parts,
    };

    const params = agent.AgentCall{ .messages = messages, .tools = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing_allocator.free(body);

    // The body MUST include the user-attached image (otherwise the LLM
    // — and `api.minimax.io/anthropic` — sees an empty user message and
    // replies "i don't see an image"). Before the fix, the only
    // `"type"` strings in the body are `text` / `tool_use` /
    // `tool_result`; the image was silently dropped.
    try expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") != null);
    try expect(std.mem.indexOf(u8, body, url_dup) != null);
    try expect(std.mem.indexOf(u8, body, text_dup) != null);

    // Sanity: the body's still valid JSON with the user message
    // emitted as `role: "user"`.
    try expect(std.mem.startsWith(u8, body, "{"));
    try expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
}

test "buildJsonAnthropicRequest: user message with ONLY image (no text) is preserved" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.model = "claude-test";
    a.UrlStyle = "anthropic";
    a.thinkingEnabled = false;

    const url_dup = try testing_allocator.dupe(
        u8,
        "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD",
    );
    defer testing_allocator.free(url_dup);

    const parts = try testing_allocator.alloc(agent.ContentPart, 1);
    defer testing_allocator.free(parts);
    parts[0] = .{
        .part_type = "image_url",
        .text = null,
        .image_url = .{ .url = url_dup, .detail = null },
    };

    const messages = try testing_allocator.alloc(agent.AgentMessage, 2);
    defer testing_allocator.free(messages);
    messages[0] = .{ .role = .system, .content = "Helper." };
    messages[1] = .{
        .role = .user,
        .content = null,
        .content_parts = parts,
    };

    const params = agent.AgentCall{ .messages = messages, .tools = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing_allocator.free(body);

    try expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") != null);
    try expect(std.mem.indexOf(u8, body, url_dup) != null);
}

test "buildJsonAnthropicRequest: user message with plain text (no image) still emits single-text content (regression)" {
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.model = "claude-test";
    a.UrlStyle = "anthropic";
    a.thinkingEnabled = false;

    const content_dup = try testing_allocator.dupe(u8, "halo dunia");
    defer testing_allocator.free(content_dup);

    const messages = try testing_allocator.alloc(agent.AgentMessage, 2);
    defer testing_allocator.free(messages);
    messages[0] = .{ .role = .system, .content = "Helper." };
    messages[1] = .{
        .role = .user,
        .content = content_dup,
        .content_parts = null,
    };

    const params = agent.AgentCall{ .messages = messages, .tools = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing_allocator.free(body);

    // No images: `content` MUST serialize as a top-level string (the
    // legacy shape Anthropic accepts), not as an array. We assert that
    // by checking the substring `"content":"halo dunia"` is in the
    // body. (It would be `"content":["text:..."]` if we'd broken the
    // backwards-compat path.)
    try expect(std.mem.indexOf(u8, body, "\"content\":\"halo dunia\"") != null);
    try expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") == null);
}

test "buildJsonAnthropicRequest: image content uses Anthropic-native source.url wrapper" {
    // The OpenAI wire format puts the data URL straight under
    // `image_url: { url: "data:..." }`; Anthropic wraps it under
    // `source: { type: "url", url: "data:..." }` inside an
    // `image`-typed content block. This test pins that exact shape
    // so a future refactor can't accidentally emit OpenAI-style
    // blocks onto Anthropic.
    var a: agent.Agent = .init(testing_allocator, std.testing.io);
    defer a.deinit();
    a.model = "claude-test";
    a.UrlStyle = "anthropic";

    const url_dup = try testing_allocator.dupe(u8, "data:image/png;base64,abc123");
    defer testing_allocator.free(url_dup);
    const parts = try testing_allocator.alloc(agent.ContentPart, 1);
    defer testing_allocator.free(parts);
    parts[0] = .{
        .part_type = "image_url",
        .text = null,
        .image_url = .{ .url = url_dup, .detail = null },
    };

    const messages = try testing_allocator.alloc(agent.AgentMessage, 1);
    defer testing_allocator.free(messages);
    messages[0] = .{
        .role = .user,
        .content = null,
        .content_parts = parts,
    };

    const params = agent.AgentCall{ .messages = messages, .tools = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing_allocator.free(body);

    // The Anthropic-native wrapper: `"image"` block + `"source"` with
    // `"type":"url"`. Confirms our serializer emits the right shape
    // (vs. accidentally emitting the OpenAI-flat `"image_url":...`
    // which Anthropic would reject with a 400).
    try expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") != null);
    try expect(std.mem.indexOf(u8, body, "\"source\":{") != null);
    try expect(std.mem.indexOf(u8, body, "\"type\":\"url\"") != null);
    try expect(std.mem.indexOf(u8, body, "\"url\":\"data:image/png;base64,abc123\"") != null);

    // And the OpenAI-style flat shape MUST NOT appear.
    try expect(std.mem.indexOf(u8, body, "\"image_url\":") == null);
    try expect(std.mem.indexOf(u8, body, "\"type\":\"image_url\"") == null);
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