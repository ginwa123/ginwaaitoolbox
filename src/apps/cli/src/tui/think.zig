//! Strip `<think>...</think>` blocks from assistant content.
//!
//! Mirrors `src/apps/desktop/src/helpers/stripTags.ts:5-80` — pure
//! functions on borrowed input. The slow path (with think blocks)
//! allocates a new owned slice via `allocator`; the fast path (no
//! tags) duplicates the trimmed input. The caller owns the returned
//! slice and must `allocator.free(slice)` when done.
//!
//! Behaviour summary:
//!   - `stripThinkingTags(allocator, content)` returns a freshly
//!     allocated `[]u8` with every `<think>...</think>` block removed
//!     (tags + inner content) and surrounding whitespace trimmed. When
//!     no tags are present it returns a dupe of the trimmed input.
//!   - `isThinkingOnly(allocator, content)` is `true` when stripping
//!     leaves nothing — used by the assistant branch of
//!     `renderMessage` to decide between rendering text vs. a
//!     `… thinking …` chip. The caller still owns the returned slice.

const std = @import("std");
const testing = std.testing;

/// Return an owned slice (caller frees via `allocator.free`) with
/// every `<think>...</think>` block removed.
pub fn stripThinkingTags(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    // Fast path — no tags at all. Return a dupe of the trimmed input.
    if (std.mem.indexOf(u8, content, "<think>") == null) {
        const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
        return allocator.dupe(u8, trimmed);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, content.len);

    var cursor: usize = 0;
    while (cursor < content.len) {
        if (std.mem.startsWith(u8, content[cursor..], "<think>")) {
            const after_open = cursor + "<think>".len;
            const close_at = std.mem.indexOf(u8, content[after_open..], "</think>") orelse {
                // Unclosed think block — copy the rest verbatim and
                // stop. Avoids spinning if the LLM emits a partial
                // stream during a poll mid-write.
                try out.appendSlice(allocator, content[cursor..]);
                break;
            };
            cursor = after_open + close_at + "</think>".len;
            continue;
        }
        try out.append(allocator, content[cursor]);
        cursor += 1;
    }
    const trimmed = std.mem.trim(u8, out.items, &std.ascii.whitespace);
    return allocator.dupe(u8, trimmed);
}

/// True when `content` contains only `<think>...</think>` blocks
/// (possibly multiple, possibly with surrounding whitespace) and no
/// visible text remains after stripping.
pub fn isThinkingOnly(allocator: std.mem.Allocator, content: []const u8) !bool {
    const stripped = try stripThinkingTags(allocator, content);
    defer allocator.free(stripped);
    return stripped.len == 0;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "stripThinkingTags: removes single think block" {
    const got = try stripThinkingTags(testing.allocator, "<think>hidden</think>visible");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("visible", got);
}

test "stripThinkingTags: returns content unchanged when no tags" {
    const got = try stripThinkingTags(testing.allocator, "plain assistant text");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("plain assistant text", got);
}

test "stripThinkingTags: handles leading think + trailing text" {
    const got = try stripThinkingTags(testing.allocator, "<think>plan</think>the answer is 42");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("the answer is 42", got);
}

test "stripThinkingTags: removes multiple think blocks" {
    const got = try stripThinkingTags(testing.allocator, "<think>a</think>x<think>b</think>y");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("xy", got);
}

test "stripThinkingTags: handles text before and after a think block" {
    const got = try stripThinkingTags(testing.allocator, "pre<think>mid</think>post");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("prepost", got);
}

test "stripThinkingTags: trims surrounding whitespace" {
    const got = try stripThinkingTags(testing.allocator, "  <think>plan</think>answer   ");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("answer", got);
}

test "stripThinkingTags: handles unclosed think block gracefully" {
    // No closing tag — strip everything up to but not including the
    // unclosed opener, leaving the rest of the content intact.
    const got = try stripThinkingTags(testing.allocator, "pre<think>never closes");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("pre<think>never closes", got);
}

test "isThinkingOnly: true when only think block present" {
    try testing.expect(try isThinkingOnly(testing.allocator, "<think>plan</think>"));
}

test "isThinkingOnly: true when multiple think blocks only" {
    try testing.expect(try isThinkingOnly(testing.allocator, "<think>a</think><think>b</think>"));
}

test "isThinkingOnly: true for whitespace + think blocks" {
    try testing.expect(try isThinkingOnly(testing.allocator, " <think>plan</think>  "));
}

test "isThinkingOnly: false when visible text remains" {
    try testing.expect(!(try isThinkingOnly(testing.allocator, "<think>plan</think>answer")));
}

test "isThinkingOnly: false when no tags" {
    try testing.expect(!(try isThinkingOnly(testing.allocator, "plain")));
}