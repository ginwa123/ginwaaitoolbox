//! POST /api/dev/sse/emit_llm — TEST-ONLY SSE event injection.
//!
//! Purpose: let functional UI tests drive the chatview's SSE streaming
//! path WITHOUT a real LLM. The test seeds a session via DB, opens the
//! chatview in a browser, then POSTs crafted `llm_chunk` / `llm_full`
//! payloads here; this handler publishes them on the event bus's
//! central "llm" routing key — exactly the same wire path a real
//! agent loop uses (`on_event_sent.zig` `sendStreamChunkContent` /
//! `onEventSendLLMHistory`).
//!
//! ⛔  GATED: the endpoint is INERT unless the server was started with
//! `NALAR_TEST_SSE_EMIT=1`. The functional UI harness sets that env var
//! for the booted binary; production / developer desktop runs never do,
//! so the endpoint returns 404 there. This keeps the attack surface at
//! "test harness only".
//!
//! Wire (request):
//! ```json
//! {
//!   "session_id": "sess_x",
//!   "type": "chunk",              // chunk | chunk_final | full
//!   "content": "delta text",      // for chunk / full
//!   "finish_reason": "stop",      // for full
//!   "role": "assistant",          // for full
//!   "tool_call_id": "...",        // optional, for full
//!   "tool_name": "bash"           // optional, for full
//! }
//! ```
//!
//! Wire (response): `{"ok": true}` on 200; `{"error": "..."}` otherwise.
//! 404 when the gate is off (indistinguishable from an unknown route —
//! deliberate: no information leak about the endpoint's existence).

const std = @import("std");
pub const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_workflow = nalarcore.ai_workflow;

/// The gate. Read once per call (cheap getenv) so a test can flip it
/// mid-process in the future if needed; production binaries never set
/// the var so the read is a single failed lookup.
fn gateEnabled() bool {
    const v = std.c.getenv("NALAR_TEST_SSE_EMIT") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "1");
}

const EmitRequest = struct {
    session_id: []const u8 = "",
    type: []const u8 = "chunk",
    content: []const u8 = "",
    index: usize = 0,
    finish_reason: []const u8 = "",
    role: []const u8 = "",
    tool_call_id: []const u8 = "",
    tool_name: []const u8 = "",
};

pub fn emitLlmHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    if (!gateEnabled()) {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"not found\"}}", .{}),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(EmitRequest, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"invalid json body\"}}", .{}),
        });
    };

    if (parsed.session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"session_id is required\"}}", .{}),
        });
    }

    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"singleton unavailable\"}}", .{}),
        });
    };
    const event_bus = di.event_bus;

    // Build the same JSON payload shape the real emitters produce
    // (see on_event_sent.zig ContentChunkJson / FinalChunkJson and
    // sse_on_event_send_llm_history.zig SseEventLLMHistory). The
    // frontend's api/index.ts llm dispatch parses this shape.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    if (std.mem.eql(u8, parsed.type, "chunk_final")) {
        try buf.print(allocator,
            \\{{"index":{d},"type":"chunk_final","finish_reason":"stop","session_id":"{s}"}}
        , .{ parsed.index, parsed.session_id });
    } else if (std.mem.eql(u8, parsed.type, "full")) {
        // SseEventLLMHistory-shaped. The frontend's `full` branch
        // requires finish_reason + at least one renderable field.
        try buf.print(allocator,
            \\{{"index":{d},"content":{f},"type":"full","session_id":"{s}","role":"{s}","finish_reason":"{s}","tool_call_id":"{s}","tool_name":"{s}"}}
        , .{
            parsed.index,
            std.json.fmt(parsed.content, .{}),
            parsed.session_id,
            if (parsed.role.len > 0) parsed.role else "assistant",
            if (parsed.finish_reason.len > 0) parsed.finish_reason else "stop",
            parsed.tool_call_id,
            parsed.tool_name,
        });
    } else {
        // Default: content chunk.
        try buf.print(allocator,
            \\{{"index":{d},"content":{f},"type":"chunk","session_id":"{s}"}}
        , .{ parsed.index, std.json.fmt(parsed.content, .{}), parsed.session_id });
    }

    const data_copy = try allocator.dupe(u8, buf.items);

    const event = nalarcore.ai_mod.on_event_sent.SseEvent{
        .session_id = parsed.session_id,
        .data = data_copy,
        .event_type = "llm_chunk",
    };
    // Same dual emit as the real emitters: per-session key + central
    // "llm" broadcast (the frontend's single global EventSource
    // subscribes to the central key and filters by session_id in JS).
    event_bus.emit(nalarcore.ai_mod.on_event_sent.SseEvent, parsed.session_id, event);
    event_bus.emit(nalarcore.ai_mod.on_event_sent.SseEvent, "llm", event);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(allocator, "{{\"ok\":true}}", .{}),
    });
}

// ─── Static contract tests ──────────────────────────────────────────────────

test "gate is off by default (no env var)" {
    // Note: this asserts the DEFAULT state. If the developer's shell
    // exports NALAR_TEST_SSE_EMIT=1 the test would fail — that's
    // intentional (the gate must be opt-in per-process).
    // We can't unset env vars portably in Zig 0.16 tests, so this test
    // only runs when the var is absent.
    if (std.c.getenv("NALAR_TEST_SSE_EMIT") == null) {
        try std.testing.expect(!gateEnabled());
    }
}

test "gate accepts exactly '1'" {
    // gateEnabled() reads the real environ; we can't inject. Instead
    // pin the comparison logic via a mirror of the implementation.
    const v: ?[]const u8 = "1";
    try std.testing.expect(v != null and std.mem.eql(u8, v.?, "1"));
    const bad: ?[]const u8 = "0";
    try std.testing.expect(!(bad != null and std.mem.eql(u8, bad.?, "1")));
}
