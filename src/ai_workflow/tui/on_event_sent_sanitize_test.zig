const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");

/// Regression test for the "bash tool returns corrupt value" bug where
/// tool result content containing invalid UTF-8 bytes (e.g. \x89, \x93 from
/// a test binary that prints raw bytes) was serialized as an ARRAY of bytes
/// instead of a JSON string. Zig 0.16's std.json.fmt emits invalid-UTF-8
/// strings as arrays (see /usr/local/lib/zig/std/json/Stringify.zig:506 —
/// `if (!emit_strings_as_arrays and utf8ValidateSlice(slice))` falls through
/// to the array branch when utf8ValidateSlice returns false).
///
/// The fix is in `src/ai_workflow/tui/on_event_sent.zig` — the
/// `onEventSendLLMHistory` function calls `helpers.sanitize.sanitizeUtf8`
/// on both `input.content` and `input.reasoning_content` before passing
/// them to the payload struct (and thus to `std.json.fmt`).
///
/// The original message that triggered the bug was id
/// `1782446723214101839` in `~/.config/nalar/agent.db`, with content bytes
/// `<total>...</total><times>...</times>3\n^W^C^C^Dy|;\x89+\x93^YI"s\n`
/// (the `\x89` and `\x93` bytes are invalid UTF-8).

const ON_EVENT_SENT_PATH = "src/ai_workflow/tui/on_event_sent.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .unlimited);
}

test "on_event_sent.zig imports helpers" {
    const source = try readSource(testing.allocator, ON_EVENT_SENT_PATH);
    defer testing.allocator.free(source);

    // The fix needs `helpers.sanitize.sanitizeUtf8`, so the helpers import
    // must be present.
    if (std.mem.indexOf(u8, source, "const helpers = tree1_mod.helpers;") == null) {
        std.debug.print("!! on_event_sent.zig missing `const helpers = tree1_mod.helpers;` !!\n", .{});
        return error.HelpersImportMissing;
    }
}

test "on_event_sent.zig calls sanitizeUtf8 on content" {
    const source = try readSource(testing.allocator, ON_EVENT_SENT_PATH);
    defer testing.allocator.free(source);

    // The payload content must come from sanitizeUtf8(... input.content).
    // Accept either the direct form or via a `blk:` helper const.
    const direct = std.mem.indexOf(u8, source, "sanitizeUtf8(allocator, input.content)") != null;
    const via_const = std.mem.indexOf(u8, source, "sanitizeUtf8(allocator, c)") != null and
        std.mem.indexOf(u8, source, "input.content") != null;
    if (!direct and !via_const) {
        std.debug.print("!! on_event_sent.zig does not sanitize input.content before JSON serialization !!\n", .{});
        return error.ContentSanitizationMissing;
    }
}

test "on_event_sent.zig calls sanitizeUtf8 on reasoning_content" {
    const source = try readSource(testing.allocator, ON_EVENT_SENT_PATH);
    defer testing.allocator.free(source);

    // The payload reasoning_content must come from sanitizeUtf8(... input.reasoning_content).
    // Either direct form (`sanitizeUtf8(allocator, input.reasoning_content)`) or via
    // a `blk:` helper const is acceptable.
    const direct = std.mem.indexOf(u8, source, "sanitizeUtf8(allocator, input.reasoning_content)") != null;
    const via_const = std.mem.indexOf(u8, source, "sanitizeUtf8(allocator, r)") != null and
        std.mem.indexOf(u8, source, "input.reasoning_content") != null;
    if (!direct and !via_const) {
        std.debug.print("!! on_event_sent.zig does not sanitize input.reasoning_content !!\n", .{});
        return error.ReasoningSanitizationMissing;
    }
}

test "sanitizeUtf8 fixes the exact bytes from the bug" {
    // Real bytes from the corrupt message at id 1782446723214101839,
    // offset 0x190-0x1A0: 3\n^W^C^C^Dy|;\x89+\x93^YI"s\n
    const corrupt_bytes = [_]u8{
        0x33, 0x0a, 0x5e, 0x57, 0x5e, 0x43, 0x5e, 0x43, 0x5e, 0x44,
        0x79, 0x7c, 0x3b,
        0x89, // INVALID UTF-8 (continuation byte without start)
        0x2b,
        0x93, // INVALID UTF-8 (continuation byte without start)
        0x5e, 0x59, 0x49, 0x22, 0x73, 0x0a,
    };

    // Confirm the test data is actually invalid UTF-8 (otherwise the test
    // would pass on no-op behavior).
    try testing.expect(!std.unicode.utf8ValidateSlice(&corrupt_bytes));

    const sanitize = nalarcore.helpers.sanitize;
    const sanitized = try sanitize.sanitizeUtf8(testing.allocator, &corrupt_bytes);
    defer testing.allocator.free(sanitized);

    // After sanitization, the result must be valid UTF-8 — otherwise the
    // SSE payload would still be emitted as an array of bytes.
    try testing.expect(std.unicode.utf8ValidateSlice(sanitized));

    // The two invalid bytes (0x89, 0x93) should have been replaced with
    // U+FFFD (EF BF BD) by sanitizeUtf8.
    try testing.expect(std.mem.indexOf(u8, sanitized, &[_]u8{ 0xEF, 0xBF, 0xBD }) != null);
}

test "SseEventLLMHistory with sanitized UTF-8 emits content as JSON string" {
    // Demonstrates the contract: when content is valid UTF-8, std.json.fmt
    // emits it as a JSON string (not an array of bytes). The bash fix relies
    // on sanitizeUtf8 being called BEFORE this serialization step.
    const on_event_sent = @import("on_event_sent.zig");

    // Build a payload with valid UTF-8 content (post-sanitization).
    const payload = on_event_sent.SseEventLLMHistory{
        .content = "<total>3</total><stdout>hello</stdout>",
        .session_id = "s1",
        .model = "m1",
        .cwd = "/cwd",
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = false,
        .is_output = true,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.print(testing.allocator, "{f}", .{std.json.fmt(payload, .{ .whitespace = .minified })});

    const json = buf.items;
    // Valid UTF-8 content MUST be quoted as a JSON string, not as an array.
    try testing.expect(std.mem.indexOf(u8, json, "\"content\":\"<total>3</total><stdout>hello</stdout>\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"content\":[") == null);
}

test "SseEventLLMHistory with INVALID UTF-8 emits content as byte ARRAY (demonstrates the bug)" {
    // This test documents the BUG that the sanitize fix prevents. If you
    // remove the sanitizeUtf8 call from onEventSendLLMHistory, this test
    // would describe the user-visible symptom (frontend receives array of
    // bytes instead of a string).
    const on_event_sent = @import("on_event_sent.zig");

    // Same payload but with raw invalid-UTF-8 content (as it came from
    // the bash tool before sanitization).
    const invalid_content = [_]u8{ '<', 't', 'a', 'g', '>', 0x89, '<', '/', 't', 'a', 'g', '>' };
    const payload = on_event_sent.SseEventLLMHistory{
        .content = &invalid_content,
        .session_id = "s1",
        .model = "m1",
        .cwd = "/cwd",
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = false,
        .is_output = true,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.print(testing.allocator, "{f}", .{std.json.fmt(payload, .{ .whitespace = .minified })});

    const json = buf.items;
    // Zig 0.16 std.json.fmt behavior: invalid-UTF-8 string is emitted as
    // a JSON array of byte values. This is EXACTLY what the user saw in
    // the bug report ("content": [60, 116, 111, 116, 97, 108, ...]).
    try testing.expect(std.mem.indexOf(u8, json, "\"content\":[") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"content\":\"<tag>") == null);
}