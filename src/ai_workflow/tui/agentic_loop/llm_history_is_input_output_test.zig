//! Wire-format regression tests for `is_input` / `is_output` in the
//! session-messages REST response.
//!
//! The `SessionMessage.is_input` / `is_output` fields are typed `bool` in
//! the Zig struct and must be emitted as JSON booleans (`true`/`false`)
//! and XML text (`<is_input>true</is_input>`) — NOT as the old string
//! form (`"is_input":"1"`, `<is_input>1</is_input>`) or as JSON numbers.
//!
//! These tests guard against future regressions where a well-meaning
//! refactor swaps the wire format back to a string or number.
//!
//! Plan: docs/plans/2026-07-01-is-input-output-bool-consistency.md
//! (Chunk 3, Task 3.1).

const std = @import("std");
const testing = std.testing;

const llm_history = @import("llm_history.zig");

fn makeResponse(messages: []llm_history.SessionMessage) llm_history.SessionMessageResponse {
    return .{
        .messages = messages,
        .has_more = false,
        .next_cursor = null,
        .max_total_tokens = 0,
        .max_capacity_total_tokens = 0,
    };
}

test "buildSessionMessagesJson emits is_input/is_output as JSON booleans" {
    const allocator = testing.allocator;

    // Build a minimal SessionMessageResponse with known bool values:
    // is_input: true, is_output: false.
    const messages = [_]llm_history.SessionMessage{
        .{
            .id = "m1",
            .session_id = "s1",
            .role = "user",
            .content = "hi",
            .timestamp = "1700000000",
            .is_input = true,
            .is_output = false,
            .tool_name = "",
            .finish_reason = "",
            .reasoning_content = "",
        },
    };
    const response = makeResponse(@constCast(&messages));

    const json = try llm_history.buildSessionMessagesJson(allocator, &response);
    defer allocator.free(json);

    // Must contain boolean form (no quotes around true/false):
    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\":false") != null);
    // Must NOT contain string form (the old wrong format):
    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\":\"1\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\":\"0\"") == null);
    // Must NOT contain string form with bare 'true'/'false' wrapped in quotes:
    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\":\"true\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\":\"false\"") == null);
    // Must NOT contain number form (the alternative refactor that was rejected):
    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\": 1") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\": 0") == null);
}

test "buildSessionMessagesXml emits is_input/is_output as text 'true'/'false'" {
    const allocator = testing.allocator;

    const messages = [_]llm_history.SessionMessage{
        .{
            .id = "m1",
            .session_id = "s1",
            .role = "user",
            .content = "hi",
            .timestamp = "1700000000",
            .is_input = true,
            .is_output = false,
            .tool_name = "",
            .finish_reason = "",
            .reasoning_content = "",
        },
    };
    const response = makeResponse(@constCast(&messages));

    const xml = try llm_history.buildSessionMessagesXml(allocator, &response);
    defer allocator.free(xml);

    // XML text content: <is_input>true</is_input> (bool rendered as text).
    try testing.expect(std.mem.indexOf(u8, xml, "<is_input>true</is_input>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<is_output>false</is_output>") != null);
    // Must NOT contain the old "1"/"0" text form:
    try testing.expect(std.mem.indexOf(u8, xml, "<is_input>1</is_input>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<is_output>0</is_output>") == null);
}

test "buildSessionMessagesJson emits true/false values in both directions" {
    // Defense-in-depth: confirm that BOTH true AND false round-trip through
    // the bool wire format. The single-message test above only exercises
    // (is_input=true, is_output=false); this one flips them.
    const allocator = testing.allocator;

    const messages = [_]llm_history.SessionMessage{
        .{
            .id = "m2",
            .session_id = "s1",
            .role = "assistant",
            .content = "ok",
            .timestamp = "1700000001",
            .is_input = false,
            .is_output = true,
            .tool_name = "",
            .finish_reason = "stop",
            .reasoning_content = "",
        },
    };
    const response = makeResponse(@constCast(&messages));

    const json = try llm_history.buildSessionMessagesJson(allocator, &response);
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\":true") != null);
}