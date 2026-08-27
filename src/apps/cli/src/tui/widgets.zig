//! Widgets: reusable view components with their own state machines.

const std = @import("std");
const frame_mod = @import("frame.zig");
const key_mod = @import("key.zig");

pub const Style = frame_mod.Style;

/// A single logical line of text with a style. Owned by the widget's
/// allocator; widgets dupe strings passed in.
pub const Line = struct {
    text: []u8,
    style: Style = .{},
};

// ============================================================================
// Viewport — scrollable buffer of lines
// ============================================================================

pub const Viewport = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(Line) = .empty,
    /// Scroll offset in lines from the bottom (0 = pinned to bottom).
    scroll_from_bottom: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Viewport {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Viewport) void {
        for (self.lines.items) |l| self.allocator.free(l.text);
        self.lines.deinit(self.allocator);
    }

    /// Append a line (dupes `text`).
    pub fn appendLine(self: *Viewport, text: []const u8, style: Style) !void {
        const dup = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(dup);
        try self.lines.append(self.allocator, .{ .text = dup, .style = style });
        // Keep memory bounded: cap at 10k lines, drop oldest.
        if (self.lines.items.len > 10_000) {
            const old = self.lines.orderedRemove(0);
            self.allocator.free(old.text);
            if (self.scroll_from_bottom > 0) self.scroll_from_bottom -= 1;
        }
    }

    pub fn scrollUp(self: *Viewport, n: usize) void {
        const max = if (self.lines.items.len == 0) 0 else self.lines.items.len - 1;
        self.scroll_from_bottom = @min(self.scroll_from_bottom + n, max);
    }

    pub fn scrollDown(self: *Viewport, n: usize) void {
        self.scroll_from_bottom -= @min(n, self.scroll_from_bottom);
    }

    /// Render the last `height` visible lines into a fresh Frame of
    /// size `width x height`. Caller owns the frame.
    pub fn render(self: *const Viewport, allocator: std.mem.Allocator, width: u16, height: u16) !frame_mod.Frame {
        var f = try frame_mod.Frame.init(allocator, width, height);
        errdefer f.deinit(allocator);

        const total = self.lines.items.len;
        const h: usize = height;
        const end = total - @min(self.scroll_from_bottom, total);
        const start = end - @min(end, h);

        var row: u16 = 0;
        var i = start;
        while (i < end and row < height) : ({
            i += 1;
            row += 1;
        }) {
            _ = f.writeText(0, row, self.lines.items[i].text, self.lines.items[i].style);
        }
        return f;
    }
};

// ============================================================================
// Input — single-line input with cursor + history
// ============================================================================

pub const Input = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Cursor position in BYTES within buf.
    cursor: usize = 0,
    history: std.ArrayList([]u8) = .empty,
    /// History navigation index; == history.items.len when not browsing.
    hist_idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Input {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Input) void {
        self.buf.deinit(self.allocator);
        for (self.history.items) |h| self.allocator.free(h);
        self.history.deinit(self.allocator);
    }

    /// Handle a key. Returns true if the input was submitted (Enter).
    pub fn handleKey(self: *Input, k: key_mod.Key) !bool {
        switch (k) {
            .rune => |cp| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return false;
                try self.buf.insertSlice(self.allocator, self.cursor, buf[0..n]);
                self.cursor += n;
                return false;
            },
            .backspace => {
                if (self.cursor > 0) {
                    // Walk back one UTF-8 sequence.
                    var start = self.cursor - 1;
                    while (start > 0 and (self.buf.items[start] & 0xC0) == 0x80) : (start -= 1) {}
                    const removed = self.cursor - start;
                    try self.buf.replaceRange(self.allocator, start, removed, "");
                    self.cursor = start;
                }
                return false;
            },
            .delete => {
                if (self.cursor < self.buf.items.len) {
                    var end = self.cursor + 1;
                    while (end < self.buf.items.len and (self.buf.items[end] & 0xC0) == 0x80) : (end += 1) {}
                    try self.buf.replaceRange(self.allocator, self.cursor, end - self.cursor, "");
                }
                return false;
            },
            .left => {
                if (self.cursor > 0) {
                    self.cursor -= 1;
                    while (self.cursor > 0 and (self.buf.items[self.cursor] & 0xC0) == 0x80) : (self.cursor -= 1) {}
                }
                return false;
            },
            .right => {
                if (self.cursor < self.buf.items.len) {
                    self.cursor += 1;
                    while (self.cursor < self.buf.items.len and (self.buf.items[self.cursor] & 0xC0) == 0x80) : (self.cursor += 1) {}
                }
                return false;
            },
            .home => {
                self.cursor = 0;
                return false;
            },
            .end => {
                self.cursor = self.buf.items.len;
                return false;
            },
            .up => {
                if (self.history.items.len == 0) return false;
                if (self.hist_idx > 0) self.hist_idx -= 1;
                try self.setFromHistory();
                return false;
            },
            .down => {
                if (self.hist_idx < self.history.items.len) {
                    self.hist_idx += 1;
                    try self.setFromHistory();
                }
                return false;
            },
            .ctrl_u => {
                try self.buf.replaceRange(self.allocator, 0, self.cursor, "");
                self.cursor = 0;
                return false;
            },
            .ctrl_w => {
                // Delete the word before the cursor.
                var start = self.cursor;
                while (start > 0 and self.buf.items[start - 1] == ' ') : (start -= 1) {}
                while (start > 0 and self.buf.items[start - 1] != ' ') : (start -= 1) {}
                try self.buf.replaceRange(self.allocator, start, self.cursor - start, "");
                self.cursor = start;
                return false;
            },
            .enter => {
                const submitted_text = try self.allocator.dupe(u8, self.buf.items);
                try self.history.append(self.allocator, submitted_text);
                self.hist_idx = self.history.items.len;
                self.buf.clearRetainingCapacity();
                self.cursor = 0;
                return true;
            },
            else => return false,
        }
    }

    fn setFromHistory(self: *Input) !void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        if (self.hist_idx < self.history.items.len) {
            const h = self.history.items[self.hist_idx];
            try self.buf.appendSlice(self.allocator, h);
            self.cursor = h.len;
        }
    }

    pub fn text(self: *const Input) []const u8 {
        return self.buf.items;
    }

    /// Render into a single-row frame. Caller owns the frame.
    pub fn render(self: *const Input, allocator: std.mem.Allocator, width: u16) !frame_mod.Frame {
        var f = try frame_mod.Frame.init(allocator, width, 1);
        errdefer f.deinit(allocator);
        const prompt = "> ";
        var cx = f.writeText(0, 0, prompt, .{ .bold = true });
        cx = f.writeText(cx, 0, self.buf.items, .{});
        // Cursor cell: bold `|` caret, foreground only. The previous
        // implementation used a background-fill block (`.bg = .white`)
        // which several terminal palettes (iTerm2, Solarized, GNOME
        // default) render as a yellow block. A fg-only caret is
        // universally supported and matches how Claude Code / lazygit
        // / k9s render their input.
        if (cx < width) {
            f.set(cx, 0, .{ .char = '|', .fg = .white, .bold = true });
        }
        f.cursor = .{ .x = cx, .y = 0 };
        return f;
    }
};

// ============================================================================
// Spinner — animated braille frames
// ============================================================================

pub const Spinner = struct {
    pub const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    frame_idx: usize = 0,
    label: []const u8 = "thinking",

    pub fn tick(self: *Spinner) void {
        self.frame_idx = (self.frame_idx + 1) % frames.len;
    }

    /// Render "⠋ thinking..." into a single-row frame. Caller owns.
    pub fn render(self: *const Spinner, allocator: std.mem.Allocator, width: u16) !frame_mod.Frame {
        var f = try frame_mod.Frame.init(allocator, width, 1);
        errdefer f.deinit(allocator);
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} {s}...", .{ frames[self.frame_idx], self.label }) catch "";
        _ = f.writeText(0, 0, text, .{ .fg = .cyan });
        return f;
    }
};

// ============================================================================
// StatusBar — fixed-height footer
// ============================================================================

pub const StatusBar = struct {
    left: [64]u8 = undefined,
    left_len: usize = 0,
    right: [64]u8 = undefined,
    right_len: usize = 0,

    pub fn setLeft(self: *StatusBar, text: []const u8) void {
        const n = @min(text.len, self.left.len);
        @memcpy(self.left[0..n], text[0..n]);
        self.left_len = n;
    }

    pub fn setRight(self: *StatusBar, text: []const u8) void {
        const n = @min(text.len, self.right.len);
        @memcpy(self.right[0..n], text[0..n]);
        self.right_len = n;
    }

    /// Render into a single-row frame: left-aligned text, right-aligned
    /// text at the far edge. Caller owns the frame.
    pub fn render(self: *const StatusBar, allocator: std.mem.Allocator, width: u16) !frame_mod.Frame {
        var f = try frame_mod.Frame.init(allocator, width, 1);
        errdefer f.deinit(allocator);
        // Dim background bar across the full width.
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            f.set(x, 0, .{ .char = ' ', .bg = .brightBlack });
        }
        _ = f.writeText(0, 0, self.left[0..self.left_len], .{ .bg = .brightBlack });
        const right_text = self.right[0..self.right_len];
        if (right_text.len < width) {
            const rx = width - @as(u16, @intCast(right_text.len));
            _ = f.writeText(rx, 0, right_text, .{ .bg = .brightBlack });
        }
        return f;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "Viewport: append + render bottom-pinned" {
    var vp = Viewport.init(testing.allocator);
    defer vp.deinit();
    try vp.appendLine("hello", .{});
    try vp.appendLine("world", .{});

    var f = try vp.render(testing.allocator, 20, 1);
    defer f.deinit(testing.allocator);
    // Only the LAST line fits in a 1-row viewport.
    try testing.expectEqual(@as(u21, 'w'), f.get(0, 0).char);
}

test "Viewport: scroll up reveals older lines" {
    var vp = Viewport.init(testing.allocator);
    defer vp.deinit();
    try vp.appendLine("one", .{});
    try vp.appendLine("two", .{});
    try vp.appendLine("three", .{});
    vp.scrollUp(2); // now showing "one"

    var f = try vp.render(testing.allocator, 20, 1);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u21, 'o'), f.get(0, 0).char);
}

test "Viewport: scroll down clamps at bottom" {
    var vp = Viewport.init(testing.allocator);
    defer vp.deinit();
    try vp.appendLine("a", .{});
    vp.scrollDown(5); // must not underflow
    try testing.expectEqual(@as(usize, 0), vp.scroll_from_bottom);
}

test "Input: typing runes appends" {
    var in = Input.init(testing.allocator);
    defer in.deinit();
    _ = try in.handleKey(.{ .rune = 'h' });
    _ = try in.handleKey(.{ .rune = 'i' });
    try testing.expectEqualStrings("hi", in.text());
}

test "Input: backspace deletes before cursor" {
    var in = Input.init(testing.allocator);
    defer in.deinit();
    _ = try in.handleKey(.{ .rune = 'a' });
    _ = try in.handleKey(.{ .rune = 'b' });
    _ = try in.handleKey(.backspace);
    try testing.expectEqualStrings("a", in.text());
}

test "Input: enter submits and clears" {
    var in = Input.init(testing.allocator);
    defer in.deinit();
    _ = try in.handleKey(.{ .rune = 'x' });
    const submitted = try in.handleKey(.enter);
    try testing.expect(submitted);
    try testing.expectEqualStrings("", in.text());
}

test "Input: arrow-up recalls last submission" {
    var in = Input.init(testing.allocator);
    defer in.deinit();
    _ = try in.handleKey(.{ .rune = 'f' });
    _ = try in.handleKey(.enter);
    _ = try in.handleKey(.up);
    try testing.expectEqualStrings("f", in.text());
}

test "Input: ctrl-u clears to start" {
    var in = Input.init(testing.allocator);
    defer in.deinit();
    _ = try in.handleKey(.{ .rune = 'a' });
    _ = try in.handleKey(.{ .rune = 'b' });
    _ = try in.handleKey(.left);
    _ = try in.handleKey(.ctrl_u);
    try testing.expectEqualStrings("b", in.text());
}

test "Spinner: tick advances frames cyclically" {
    var sp = Spinner{};
    const first = sp.frame_idx;
    sp.tick();
    try testing.expectEqual(first + 1, sp.frame_idx);
    sp.frame_idx = Spinner.frames.len - 1;
    sp.tick();
    try testing.expectEqual(@as(usize, 0), sp.frame_idx);
}

test "StatusBar: left/right render at edges" {
    var sb = StatusBar{};
    sb.setLeft("session-1");
    sb.setRight("streaming");
    var f = try sb.render(testing.allocator, 30);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u21, 's'), f.get(0, 0).char);
    // Right-aligned: last chars of "streaming" land at x=29.
    try testing.expectEqual(@as(u21, 'g'), f.get(29, 0).char);
}

test "Input: cursor cell uses foreground-only caret (no bg)" {
    var in = Input.init(testing.allocator);
    defer in.deinit();
    _ = try in.handleKey(.{ .rune = 'a' });
    var f = try in.render(testing.allocator, 20);
    defer f.deinit(testing.allocator);
    // Cursor sits at column 3 ("> a" is 3 chars: '>', ' ', 'a').
    const cursor = f.get(3, 0);
    try testing.expectEqual(@as(u21, '|'), cursor.char);
    try testing.expect(cursor.bg == null); // NO background fill — the old
    // cursor cell used `.bg = .white` which several terminal
    // palettes (iTerm2, Solarized, GNOME default) render as a
    // yellow block. The fg-only caret is universally supported.
    try testing.expectEqual(@as(?@import("color.zig").Color, .white), cursor.fg);
    try testing.expect(cursor.bold);
}
