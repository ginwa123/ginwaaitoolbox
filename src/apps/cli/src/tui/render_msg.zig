//! Render a single backend message into 0..N styled `Line`s for the
//! viewport. Pure function — no state, no side effects. Caller owns
//! the returned slice (each `Line.text` is independently allocated
//! and must be freed).
//!
//! Role dispatch:
//!   - `user`      → one `Line` of "> {content}" in bold green.
//!   - `assistant` → `<think>...</think>` stripped. Thinking-only
//!                   renders as a single dim `… thinking …` chip.
//!   - `tool`      → parsed `<tool>` envelope renders as a compact
//!                   card header (`▶ {name}  {primary}  ✓/✗`). Legacy
//!                   non-envelope content renders as raw dim text.
//!
//! Mirrors the Vue chatview's three-tier behaviour at the textual
//! level — no expansion model in v1 (folded away; see design spec).

const std = @import("std");
const testing = std.testing;

const tui = @import("root.zig");
const Line = tui.widgets.Line;
const Style = tui.frame.Style;
const Color = tui.color.Color;

const think = @import("think.zig");
const tool_envelope = @import("tool_envelope.zig");

/// Trimmed view of a `SessionMessage` (TUI doesn't depend on the
/// backend wire types directly — populated by `App.onMessages`).
pub const MessageView = struct {
    role: []const u8,
    content: []const u8,
    tool_name: []const u8,
    reasoning_content: []const u8,
};

/// Render a message into 1+ `Line`s. Caller owns each `Line.text`
/// and the returned slice itself.
pub fn renderMessage(allocator: std.mem.Allocator, msg: MessageView) ![]Line {
    if (std.mem.eql(u8, msg.role, "user")) {
        const text = try std.fmt.allocPrint(allocator, "> {s}", .{msg.content});
        const lines = try allocator.dupe(Line, &[_]Line{.{
            .text = text,
            .style = .{ .fg = .green, .bold = true },
        }});
        return lines;
    }

    if (std.mem.eql(u8, msg.role, "assistant")) {
        if (try think.isThinkingOnly(allocator, msg.content)) {
            const text = try allocator.dupe(u8, "… thinking …");
            const lines = try allocator.dupe(Line, &[_]Line{.{
                .text = text,
                .style = .{ .fg = .brightBlack },
            }});
            return lines;
        }
        const stripped = try think.stripThinkingTags(allocator, msg.content);
        defer allocator.free(stripped);
        const unwrapped = try think.unwrapContentWrappers(allocator, stripped);
        defer allocator.free(unwrapped);
        const text = try allocator.dupe(u8, unwrapped);
        const lines = try allocator.dupe(Line, &[_]Line{.{
            .text = text,
            .style = .{},
        }});
        return lines;
    }

    if (std.mem.eql(u8, msg.role, "tool")) {
        if (tool_envelope.tryParseToolEnvelope(msg.content)) |env| {
            const primary = tool_envelope.toolEnvelopePrimary(env);
            const badge = if (env.success) "✓" else "✗";
            const text = try std.fmt.allocPrint(allocator, "▶ {s}  {s}  {s}", .{ env.name, primary, badge });
            const lines = try allocator.dupe(Line, &[_]Line{.{
                .text = text,
                .style = .{ .fg = if (env.success) .magenta else .red },
            }});
            return lines;
        }
        // Legacy / malformed envelope — raw content as dim.
        const text = try allocator.dupe(u8, msg.content);
        const lines = try allocator.dupe(Line, &[_]Line{.{
            .text = text,
            .style = .{ .fg = .brightBlack },
        }});
        return lines;
    }

    // Unknown role — render raw dim.
    const text = try allocator.dupe(u8, msg.content);
    const lines = try allocator.dupe(Line, &[_]Line{.{
        .text = text,
        .style = .{ .fg = .brightBlack },
    }});
    return lines;
}

// ----------------------------------------------------------------------------
// Tests (RED — impl added below after tests fail)
// ----------------------------------------------------------------------------

fn freeLines(allocator: std.mem.Allocator, lines: []Line) void {
    for (lines) |l| allocator.free(l.text);
    allocator.free(lines);
}

test "renderMessage: user role yields bold green prompt line" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "user",
        .content = "hello",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("> hello", lines[0].text);
    try testing.expect(lines[0].style.bold);
    try testing.expectEqual(@as(?Color, .green), lines[0].style.fg);
}

test "renderMessage: assistant with think block strips it" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "<think>plan</think>the answer is 42",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("the answer is 42", lines[0].text);
}

test "renderMessage: assistant thinking-only yields dim chip" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "<think>just thinking</think>",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("… thinking …", lines[0].text);
    try testing.expectEqual(@as(?Color, .brightBlack), lines[0].style.fg);
}

test "renderMessage: tool with valid envelope yields card header" {
    const content =
        "<tool><name>read_file</name><parameters></parameters><success>true</success><data><path>/foo.txt</path><content>x</content></data></tool>";
    const lines = try renderMessage(testing.allocator, .{
        .role = "tool",
        .content = content,
        .tool_name = "read_file",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("▶ read_file  /foo.txt  ✓", lines[0].text);
    try testing.expectEqual(@as(?Color, .magenta), lines[0].style.fg);
}

test "renderMessage: tool with error envelope yields ✗ card line" {
    const content =
        "<tool><name>bash</name><parameters></parameters><success>false</success><error>boom</error></tool>";
    const lines = try renderMessage(testing.allocator, .{
        .role = "tool",
        .content = content,
        .tool_name = "bash",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expect(std.mem.indexOf(u8, lines[0].text, "✗") != null);
    try testing.expectEqual(@as(?Color, .red), lines[0].style.fg);
}

test "renderMessage: tool with malformed content falls back to raw dim" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "tool",
        .content = "some plain legacy output",
        .tool_name = "old_tool",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("some plain legacy output", lines[0].text);
    try testing.expectEqual(@as(?Color, .brightBlack), lines[0].style.fg);
}

test "renderMessage: assistant strips <plain> wrapper" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "<plain>saya bisa bantu</plain>",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("saya bisa bantu", lines[0].text);
}

test "renderMessage: assistant strips think AND <plain>" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "assistant",
        .content = "<think>plan</think><plain>the visible answer</plain>",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("the visible answer", lines[0].text);
}

test "renderMessage: unknown role renders raw dim" {
    const lines = try renderMessage(testing.allocator, .{
        .role = "system",
        .content = "system prompt text",
        .tool_name = "",
        .reasoning_content = "",
    });
    defer freeLines(testing.allocator, lines);
    try testing.expectEqualStrings("system prompt text", lines[0].text);
    try testing.expectEqual(@as(?Color, .brightBlack), lines[0].style.fg);
}