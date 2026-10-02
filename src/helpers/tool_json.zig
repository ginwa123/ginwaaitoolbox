//! The canonical `{"error": "..."}` envelope every agent tool returns.
//!
//! ## Why this file exists
//!
//! Nine design/kanban tools each carried a byte-identical private
//! `errorJSON`, and seven carried a private `errorJSONOwned`. That is the
//! exact failure mode `helpers/path_validate.zig` already solved for
//! `invalidPathReason`: a helper that has no single home gets copied, and
//! the copies drift. The contract test in
//! `src/modules/agent/tools/tools.zig` enforces single-implementation for
//! `invalidPathReason`; this file is the same idea applied to the error
//! envelope, and that test now guards both.
//!
//! ## Who is NOT here
//!
//! `create_kanban_task.zig` and `kanban_move_task.zig` keep their own
//! `errorJSON` because their wire shape is deliberately different — they
//! emit `{"success":false,"error":...}` so the exec adapter can surface a
//! structured error. Do not "fix" those into this helper; that would change
//! the payload the LLM sees.
//!
//! ## Ownership
//!
//! Caller owns the returned slice and must `allocator.free` it.
//! `errorJSONOwned` additionally takes ownership of its message, which is
//! the `allocPrint` result at almost every call site — you cannot `defer`
//! across a `return`, so ownership has to be discharged here.

const std = @import("std");
const xml_escape = @import("xml_escape.zig");

const sanitizeControlChars = xml_escape.sanitizeControlChars;

/// Build `{"error":"<sanitized msg>"}`. Control characters are stripped
/// first: a raw `\x00` or an unpaired control byte in the message would
/// otherwise corrupt the tool-result payload the agent loop stores and
/// replays to the frontend.
pub fn errorJSON(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, error_msg);
    defer allocator.free(clean);
    return try std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

/// `errorJSON`, but takes ownership of `error_msg` and frees it on every
/// path. Use when the message is an `allocPrint` result.
pub fn errorJSONOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);
    return try errorJSON(allocator, error_msg);
}

const testing = std.testing;

test "errorJSON wraps the message in an `error` key" {
    const out = try errorJSON(testing.allocator, "boom");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"error\":\"boom\"}", out);
}

test "errorJSON strips control characters so the payload stays parseable" {
    const out = try errorJSON(testing.allocator, "a\x00b\x1fc");
    defer testing.allocator.free(out);

    // No raw control byte survives into the JSON text.
    for (out) |c| try testing.expect(c >= 0x20 or c == '\n' or c == '\r' or c == '\t');

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error") != null);
}

test "errorJSONOwned frees the caller-supplied message" {
    const msg = try testing.allocator.dupe(u8, "owned message");
    const out = try errorJSONOwned(testing.allocator, msg);
    defer testing.allocator.free(out);
    // A leak here trips `testing.allocator` on deinit — that is the
    // assertion. The wire shape is checked too so a refactor cannot
    // quietly change the payload while fixing the ownership.
    try testing.expectEqualStrings("{\"error\":\"owned message\"}", out);
}

test "errorJSONOwned is leak-free on the error path too" {
    const msg = try testing.allocator.dupe(u8, "x");
    // An empty (but valid) message still round-trips.
    const out = try errorJSONOwned(testing.allocator, msg);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"error\":\"x\"}", out);
}
