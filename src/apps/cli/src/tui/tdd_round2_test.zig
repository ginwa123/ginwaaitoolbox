//! TDD round 2 — regression tests written BEFORE the fixes.
//!
//! Each `test` in this file documents a real bug found by inspection
//! after PR #342's initial pass:
//!
//!   1. `transport.buildSendBody` — messages containing quotes,
//!      backslashes, or newlines produced INVALID JSON (raw fmt
//!      interpolation, no escaping). Server would reject with 400.
//!   2. `sse.parse` — CRLF-terminated frames (`\r\n\r\n`) were not
//!      recognized as frame separators, so a real backend that emits
//!      CRLF never yielded any events.
//!   3. `app.onMessages` — a JSON body with escaped quotes
//!      (`"content":"say \"hi\""`) crashed the cheap stringField scan
//!      path? No — onMessages uses std.json (safe). But `role`
//!      detection for the streaming-done heuristic must be
//!      case-insensitive to match the server ("Assistant" variants).
//!
//! RED phase: these tests fail against the unfixed code. GREEN phase:
//! minimal fixes land in transport.zig / sse.zig / app.zig.

const std = @import("std");
const testing = std.testing;

const transport = @import("transport.zig");
const sse = @import("sse.zig");
const app_mod = @import("app.zig");

// ============================================================================
// 1. transport.buildSendBody — JSON injection safety
// ============================================================================

test "buildSendBody: plain message round-trips" {
    const body = try transport.buildSendBody(testing.allocator, "session-1", "hi");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "{\"session_id\":\"session-1\",\"queue_message\":\"hi\",\"allowed_tools\":\"all\",\"cwd_session\":\"\",\"image_urls\":\"\",\"selected_profile_model\":\"\",\"is_auto_retry_until_stop\":\"\"}",
        body,
    );
}

test "buildSendBody: embedded double quote is escaped (was raw -> invalid JSON)" {
    const body = try transport.buildSendBody(testing.allocator, "s", "say \"hi\"");
    defer testing.allocator.free(body);
    // The body must PARSE as JSON and carry the quote through.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const qm = parsed.value.object.get("queue_message").?;
    try testing.expectEqualStrings("say \"hi\"", qm.string);
}

test "buildSendBody: backslash is escaped" {
    const body = try transport.buildSendBody(testing.allocator, "s", "path C:\\tmp");
    defer testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const qm = parsed.value.object.get("queue_message").?;
    try testing.expectEqualStrings("path C:\\tmp", qm.string);
}

test "buildSendBody: newline is escaped (multi-line message)" {
    const body = try transport.buildSendBody(testing.allocator, "s", "line1\nline2");
    defer testing.allocator.free(body);
    // Body must remain a SINGLE line of JSON (no raw control byte).
    try testing.expect(std.mem.indexOfScalar(u8, body, '\n') == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const qm = parsed.value.object.get("queue_message").?;
    try testing.expectEqualStrings("line1\nline2", qm.string);
}

test "buildSendBody: session id with quote cannot break out of the field" {
    const body = try transport.buildSendBody(testing.allocator, "evil\"}", "x");
    defer testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const sid = parsed.value.object.get("session_id").?;
    try testing.expectEqualStrings("evil\"}", sid.string);
}

// ============================================================================
// 2. sse.parse — CRLF frames + multi-line data
// ============================================================================

test "sse parse: CRLF-terminated frame yields one event" {
    var events = std.ArrayList(sse.Event).empty;
    defer events.deinit(testing.allocator);
    const input = "event: llm_history\r\ndata: {\"a\":1}\r\n\r\n";
    const consumed = try sse.parse(input, &events, testing.allocator);
    try testing.expectEqual(input.len, consumed);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("llm_history", events.items[0].name);
    try testing.expectEqualStrings("{\"a\":1}", events.items[0].data);
}

test "sse parse: multi-line data lines are joined with newline" {
    var events = std.ArrayList(sse.Event).empty;
    defer {
        for (events.items) |ev| testing.allocator.free(@constCast(ev.data));
        events.deinit(testing.allocator);
    }
    const input = "event: x\ndata: line1\ndata: line2\n\n";
    _ = try sse.parse(input, &events, testing.allocator);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("line1\nline2", events.items[0].data);
}

test "sse parse: single-line data still borrows into input" {
    var events = std.ArrayList(sse.Event).empty;
    defer events.deinit(testing.allocator);
    const input = "event: x\ndata: one\n\n";
    _ = try sse.parse(input, &events, testing.allocator);
    // Borrowed slice points inside `input` — no allocation needed.
    try testing.expect(events.items[0].data.ptr == input.ptr + "event: x\ndata: ".len);
}

// ============================================================================
// 3. app.onMessages — role heuristic robustness
// ============================================================================

fn testApp() !app_mod.App {
    return app_mod.App.init(testing.allocator, undefined, .{ .server = "http://test" });
}

test "onMessages: assistant role stops streaming regardless of case" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const body = "{\"messages\":[{\"role\":\"ASSISTANT\",\"content\":\"done\"}]}";
    try app.onMessages(body);
    try testing.expect(!app.is_streaming);
}

test "onMessages: malformed JSON body is ignored, not a crash" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    try app.onMessages("this is not json {{{");
    // State unchanged; still waiting for the reply.
    try testing.expect(app.is_streaming);
}

test "onMessages: non-object message entries are skipped" {
    var app = try testApp();
    defer app.deinit();
    const body = "{\"messages\":[\"junk\",42,null,{\"role\":\"assistant\",\"content\":\"ok\"}]}";
    try app.onMessages(body);
    // welcome + the one valid assistant message
    try testing.expectEqual(@as(usize, 2), app.viewport.lines.items.len);
}
