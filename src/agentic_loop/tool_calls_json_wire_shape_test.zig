//! Static-contract tests: tool_calls_json SSE wire shape (task_1787590621966_10)
//!
//! Regression lock for "msg.tool_calls_json?.trim is not a function".
//! Root cause: `on_event_sent.zig` emitted the assistant row's
//! tool_calls as a JSON ARRAY while every other path (REST
//! session_messages_get.zig, insert sse_on_event_send_llm_history.zig,
//! DB TEXT column) uses a JSON STRING. The frontend's ChatView.vue
//! calls `.trim()` on it — arrays crash the render.
//!
//! These are source-contract tests (grep the function body) because a
//! full wire round-trip needs a live event bus + logger; the python
//! functional harness covers the HTTP layer separately.

const std = @import("std");
const testing = std.testing;

const on_event_sent_src = @embedFile("on_event_sent.zig");
const handle_tool_src = @embedFile("handle_tool.zig");

test "static contract: on_event_sent.zig SseEventLLMHistory.tool_calls_json is a string slice" {
    // The payload struct field MUST be ?[]const u8 (string), NOT
    // ?[]const ToolCallJson (array). If a future refactor reverts this,
    // the frontend's .trim() consumer crashes on live SSE again.
    try testing.expect(std.mem.indexOf(u8, on_event_sent_src, "tool_calls_json: ?[]const u8 = null,") != null);
    // The old array-shaped field must NOT reappear in the payload struct.
    try testing.expect(std.mem.indexOf(u8, on_event_sent_src, "tool_calls_json: ?[]const ToolCallJson") == null);
}

test "static contract: on_event_sent.zig serializes via llm_history.serializeToolCalls" {
    // The emitter must serialize ONCE at emit time using the same
    // helper saveMessage uses for the DB TEXT column.
    try testing.expect(std.mem.indexOf(u8, on_event_sent_src, "llm_history.serializeToolCalls(allocator, calls)") != null);
    // The old per-call array build must be gone.
    try testing.expect(std.mem.indexOf(u8, on_event_sent_src, "tool_calls_owned.append(allocator, .{") == null);
}

test "static contract: handle_tool.zig passes the raw array; emitter serializes" {
    // sendSSEForLatestMessage passes the raw []agent.ToolCall through —
    // serialization happens ONCE inside on_event_sent.onEventSendLLMHistory
    // (single point of truth for the wire shape).
    try testing.expect(std.mem.indexOf(u8, handle_tool_src, ".tool_calls_json = tool_calls_json,") != null);
    // The emitter-side serialization must exist (checked in detail above).
    try testing.expect(std.mem.indexOf(u8, on_event_sent_src, "llm_history.serializeToolCalls(allocator, calls)") != null);
}
