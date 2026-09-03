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

    /// Render the visible window into a fresh Frame of size
    /// `width x height`. Caller owns the frame.
    ///
    /// Behaviour:
    ///   - Pinned to bottom (scroll_from_bottom == 0): always show the
    ///     LATEST content. Walks logical lines from the END backward,
    ///     summing each line's wrapped visual-row count, until the
    ///     accumulated height would exceed `height`. The remaining
    ///     older lines scroll off the top.
    ///   - Scrolled up (scroll_from_bottom > 0): speeds up the
    ///     compute by skipping that many visual rows from the bottom.
    ///     The skipped rows are accounted for in `scroll_from_bottom`
    ///     (a logical-line approximation — accepted inaccuracy under
    ///     wrap; future improvement is per-line wrapped accounting).
    ///
    /// Round-3 fix: the previous implementation used LOGICAL-line
    /// math (`start = total - height`) which broke when lines
    /// wrapped to multiple visual rows. With height=10 and 15 lines
    /// each wrapping to 2 visual rows (= 30 total), the old code
    /// rendered lines [5..15) (10 logical lines × 2 chunks = 20
    /// visual rows) and clipped the rest, leaving the LATEST lines
    /// invisible. The new code sums wrapped heights bottom-up so the
    /// newest content is always at the bottom.
    pub fn render(self: *const Viewport, allocator: std.mem.Allocator, width: u16, height: u16) !frame_mod.Frame {
        var f = try frame_mod.Frame.init(allocator, width, height);
        errdefer f.deinit(allocator);

        const total = self.lines.items.len;
        if (total == 0) return f;

        // scroll_from_bottom trims the LATEST N lines off the visible
        // window. 0 = pinned to bottom (show the newest content).
        // The unit is LOGICAL lines (matches the round-2 PgUp/PgDn
        // bindings); under wrap this is a slight approximation — the
        // scroll amount in VISUAL rows depends on each line's wrapped
        // height. Acceptable inaccuracy for the common chat case
        // where users rarely scroll when many lines are wrapped.
        const pinned = @min(self.scroll_from_bottom, total);
        const end: usize = total - pinned;

        // Walk from `end - 1` backwards. Accumulate wrapped heights
        // until we exceed `height`. `start_idx` is the oldest line
        // that fits in the viewport.
        var visual_rows: usize = 0;
        var start_idx: usize = end;
        var i: usize = end;
        while (i > 0) {
            i -= 1;
            const h = try self.wrappedHeightOf(allocator, width, i);
            if (visual_rows + h > height) {
                // This line doesn't fit. If we have nothing yet, fall
                // back to the old "logical line" behaviour — show its
                // first `height` chunks. Otherwise stop.
                if (visual_rows == 0) {
                    start_idx = i;
                    visual_rows = h;
                }
                break;
            }
            visual_rows += h;
            start_idx = i;
            if (visual_rows >= height) break;
        }

        // Render top-down from start_idx. Lines whose chunks would
        // overflow the viewport are truncated by the inner loop.
        var row: u16 = 0;
        var j: usize = start_idx;
        while (j < total and row < height) : (j += 1) {
            const text = self.lines.items[j].text;
            const style = self.lines.items[j].style;
            const chunks = try wrapText(allocator, text, width);
            defer {
                for (chunks) |c| allocator.free(c);
                allocator.free(chunks);
            }
            for (chunks) |chunk| {
                if (row >= height) break;
                _ = f.writeText(0, row, chunk, style);
                row += 1;
            }
        }
        return f;
    }

    /// Returns the visual-row count that `line_idx` will occupy when
    /// rendered at `width`. Used by the scroll bindings (Task 5) to
    /// step `scroll_from_bottom` in visual rows rather than logical
    /// lines — without this, wrapped text makes PgUp/PgDn feel
    /// stuck. Caller-owned slice; free with `allocator.free`.
    pub fn wrappedHeightOf(self: *const Viewport, allocator: std.mem.Allocator, width: u16, line_idx: usize) !usize {
        const text = self.lines.items[line_idx].text;
        const chunks = try wrapText(allocator, text, width);
        defer {
            for (chunks) |c| allocator.free(c);
            allocator.free(chunks);
        }
        return chunks.len;
    }
};

// ============================================================================
// wrapText — naive word-wrap for viewport rendering
// ============================================================================
//
// Splits `text` into a list of `[]const u8` chunks, each ≤ `width`
// cols, broken at the last ASCII space that fits. When the line has
// no spaces in the first `width` bytes (e.g. a long URL or token),
// hard-splits at `width`. Trailing whitespace is trimmed from each
// chunk so wrapped rows don't show ragged right-edges.
//
// Returns an owned `[]const []const u8`; caller frees both the outer
// slice and each inner chunk via `allocator.free`. Caller frees the
// outer slice LAST, after any work on the chunks is done.

fn wrapText(allocator: std.mem.Allocator, text: []const u8, width: u16) ![]const []const u8 {
    var chunks: std.ArrayList([]const u8) = .empty;
    defer chunks.deinit(allocator);

    if (text.len == 0) {
        // Single empty chunk keeps the renderer happy (always emits
        // at least one row per Line). Caller still owns the slice.
        try chunks.append(allocator, try allocator.dupe(u8, ""));
        return chunks.toOwnedSlice(allocator);
    }

    // Handle embedded newlines: split on \n first, then wrap each
    // segment. This ensures that a Line containing "a\nb" (from
    // legacy callers or direct Viewport.appendLine) still renders
    // as two visual rows, not one row with a literal \n char.
    // The common path (renderMessage) already splits on \n, so this
    // is a safety net for any remaining callers.
    if (std.mem.indexOfScalar(u8, text, '\n')) |_| {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |segment| {
            const seg_chunks = try wrapText(allocator, segment, width);
            defer {
                for (seg_chunks) |c| allocator.free(c);
                allocator.free(seg_chunks);
            }
            for (seg_chunks) |c| {
                try chunks.append(allocator, try allocator.dupe(u8, c));
            }
        }
        if (chunks.items.len == 0) {
            try chunks.append(allocator, try allocator.dupe(u8, ""));
        }
        return chunks.toOwnedSlice(allocator);
    }

    var rest: []const u8 = text;
    while (rest.len > width) {
        // Look for the last space in rest[0..=width].
        const window = rest[0..width];
        const last_space = std.mem.lastIndexOfScalar(u8, window, ' ');
        if (last_space) |sp| {
            // Split at the space, trim trailing whitespace from the
            // chunk, advance past the space.
            const chunk = std.mem.trim(u8, rest[0..sp], &std.ascii.whitespace);
            if (chunk.len > 0) try chunks.append(allocator, try allocator.dupe(u8, chunk));
            rest = rest[sp + 1 ..];
            // Skip any run of spaces at the start of the next chunk
            // so continuation rows don't visually indent. The
            // naive split-at-last-space leaves the separator on the
            // wrong side — round-3 user screenshot showed
            // "Hai~ 👋       kabarnya hari ini" with several spaces
            // between 👋 and kabarnya.
            while (rest.len > 0 and rest[0] == ' ') {
                rest = rest[1..];
            }
        } else {
            // No space in window — hard split at width.
            try chunks.append(allocator, try allocator.dupe(u8, rest[0..width]));
            rest = rest[width..];
        }
    }
    // Whatever remains fits within width. Trim trailing whitespace
    // and emit (unless it's all whitespace — then skip; otherwise the
    // trailing space would survive into the final row).
    const trimmed = std.mem.trim(u8, rest, &std.ascii.whitespace);
    if (trimmed.len > 0) try chunks.append(allocator, try allocator.dupe(u8, trimmed));

    // Defensive: empty input or all-whitespace input → single empty
    // chunk. The renderer relies on at-least-one-row-per-Line.
    if (chunks.items.len == 0) {
        try chunks.append(allocator, try allocator.dupe(u8, ""));
    }
    return chunks.toOwnedSlice(allocator);
}

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

test "Viewport.render pins to latest content when total > height" {
    // Round-3 user-reported: when the chat grows beyond one screen,
    // the viewport should auto-show the latest content (pin to bottom).
    // Previously the render used LOGICAL-line math that broke under
    // word-wrap — lines [total-height..total] were logical lines, not
    // visual rows, so the LAST lines were clipped off the bottom.
    //
    // Setup: each line below is "line NN hello" (14 chars). At
    // width=12 each wraps to 2 chunks ("line 14" + "hello").
    // 15 lines × 2 = 30 visual rows; only 10 fit. With height=10 we
    // show exactly the last 5 lines (10 visual rows).
    var vp = Viewport.init(testing.allocator);
    defer vp.deinit();
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        const line = try std.fmt.allocPrint(testing.allocator, "line {d:0>2} hello", .{i});
        defer testing.allocator.free(line);
        try vp.appendLine(line, .{});
    }

    var f = try vp.render(testing.allocator, 12, 10);
    defer f.deinit(testing.allocator);

    // Look for "line 14" — the LATEST line's first chunk — somewhere
    // in the viewport. Without the round-3 fix the bottom rows would
    // show earlier lines (e.g. "line 04"), confirming the regression.
    var found_latest = false;
    var row: u16 = 0;
    while (row < 10) : (row += 1) {
        var col: u16 = 0;
        while (col + 6 < 12) : (col += 1) {
            if (f.get(col, row).char == 'l' and
                f.get(col + 1, row).char == 'i' and
                f.get(col + 2, row).char == 'n' and
                f.get(col + 3, row).char == 'e' and
                f.get(col + 4, row).char == ' ' and
                f.get(col + 5, row).char == '1' and
                f.get(col + 6, row).char == '4')
            {
                found_latest = true;
                break;
            }
        }
        if (found_latest) break;
    }
    try testing.expect(found_latest);
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

// ----------------------------------------------------------------------------
// Viewport word-wrap (round-2 — Task 3)
// ----------------------------------------------------------------------------

test "Viewport.render wraps long line into multiple rows" {
    var vp = Viewport.init(testing.allocator);
    defer vp.deinit();
    try vp.appendLine("hello world", .{});

    var f = try vp.render(testing.allocator, 6, 4);
    defer f.deinit(testing.allocator);

    // Wrap "hello world" at width 6 → ["hello", "world"]. The
    // natural split eats the space between them.
    try testing.expectEqual(@as(u21, 'h'), f.get(0, 0).char);
    try testing.expectEqual(@as(u21, 'o'), f.get(4, 0).char);
    // Row 1: "world" (no leading space — wrap eats the separator)
    try testing.expectEqual(@as(u21, 'w'), f.get(0, 1).char);
    try testing.expectEqual(@as(u21, 'd'), f.get(4, 1).char);
}

test "Viewport.render short line renders on a single row" {
    var vp = Viewport.init(testing.allocator);
    defer vp.deinit();
    try vp.appendLine("hi", .{});

    var f = try vp.render(testing.allocator, 20, 4);
    defer f.deinit(testing.allocator);

    try testing.expectEqual(@as(u21, 'h'), f.get(0, 0).char);
    // Row 1 should be blank (no spurious wrapped rows).
    try testing.expectEqual(@as(u21, ' '), f.get(0, 1).char);
}

test "Viewport.render hard-splits a single word longer than width" {
    var vp = Viewport.init(testing.allocator);
    defer vp.deinit();
    try vp.appendLine("abcdefgh", .{});

    var f = try vp.render(testing.allocator, 4, 4);
    defer f.deinit(testing.allocator);

    // Row 0: "abcd"
    try testing.expectEqual(@as(u21, 'a'), f.get(0, 0).char);
    try testing.expectEqual(@as(u21, 'd'), f.get(3, 0).char);
    // Row 1: "efgh"
    try testing.expectEqual(@as(u21, 'e'), f.get(0, 1).char);
    try testing.expectEqual(@as(u21, 'h'), f.get(3, 1).char);
}

test "wrapText: trims leading whitespace on continuation rows" {
    // User-reported (round-3 follow-up): when "Hai~ 👋" wraps, the
    // continuation row should start cleanly with the next word
    // ("kabarnya"), not with the spaces from the wrap split. The
    // naive split-at-last-space eats the separator cleanly for
    // the CURRENT row, but we also have to skip any run of
    // spaces at the start of the NEXT chunk so the row doesn't
    // visually indent.
    const chunks = try wrapText(testing.allocator, "Hai~ 👋 kabarnya", 10);
    defer {
        for (chunks) |c| testing.allocator.free(c);
        testing.allocator.free(chunks);
    }
    try testing.expectEqual(@as(usize, 2), chunks.len);
    try testing.expectEqualStrings("Hai~ 👋", chunks[0]);
    try testing.expectEqualStrings("kabarnya", chunks[1]);
    // Critical: continuation row must NOT start with a space.
    try testing.expect(chunks[1].len == 0 or chunks[1][0] != ' ');
}

test "wrapText: short single word fits in one chunk (no whitespace handling needed)" {
    const chunks = try wrapText(testing.allocator, "hello", 10);
    defer {
        for (chunks) |c| testing.allocator.free(c);
        testing.allocator.free(chunks);
    }
    try testing.expectEqual(@as(usize, 1), chunks.len);
    try testing.expectEqualStrings("hello", chunks[0]);
}

test "Viewport.render trims leading whitespace on continuation rows (round-3)" {
    var vp = Viewport.init(testing.allocator);
    defer vp.deinit();
    // "xx yy zzz" (9 chars) at width=5. Our wrap is "split at the
    // last space ≤ width, trim the chunk, advance past the space":
    //   - "xx yy zzz" → "xx" + rest "yy zzz" (last space at pos 2)
    //   - "yy zzz"   → "yy" + rest "zzz"   (last space at pos 2)
    //   - "zzz"      → "zzz" (≤ 5)
    // Result: ["xx", "yy", "zzz"] (3 rows). No ragged trailing
    // whitespace; the wrap eats the separators cleanly.
    try vp.appendLine("xx yy zzz", .{});

    var f = try vp.render(testing.allocator, 5, 4);
    defer f.deinit(testing.allocator);

    // Row 0: "xx" — col 2 onwards should be blank, not a trailing space.
    try testing.expectEqual(@as(u21, 'x'), f.get(0, 0).char);
    try testing.expectEqual(@as(u21, 'x'), f.get(1, 0).char);
    try testing.expectEqual(@as(u21, ' '), f.get(2, 0).char); // col 2 is blank padding

    // Row 1: "yy"
    try testing.expectEqual(@as(u21, 'y'), f.get(0, 1).char);
    try testing.expectEqual(@as(u21, 'y'), f.get(1, 1).char);
    try testing.expectEqual(@as(u21, ' '), f.get(2, 1).char);

    // Row 2: "zzz"
    try testing.expectEqual(@as(u21, 'z'), f.get(0, 2).char);
    try testing.expectEqual(@as(u21, 'z'), f.get(1, 2).char);
    try testing.expectEqual(@as(u21, 'z'), f.get(2, 2).char);
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


test "wrapText: handles embedded newlines" {
    const chunks = try wrapText(testing.allocator, "line1\nline2\nline3", 20);
    defer {
        for (chunks) |c| testing.allocator.free(c);
        testing.allocator.free(chunks);
    }
    try testing.expectEqual(@as(usize, 3), chunks.len);
    try testing.expectEqualStrings("line1", chunks[0]);
    try testing.expectEqualStrings("line2", chunks[1]);
    try testing.expectEqualStrings("line3", chunks[2]);
}

test "wrapText: handles newline with wrapping" {
    // "hello world\nfoo bar" at width 6 should wrap each segment
    const chunks = try wrapText(testing.allocator, "hello world\nfoo bar", 6);
    defer {
        for (chunks) |c| testing.allocator.free(c);
        testing.allocator.free(chunks);
    }
    // "hello world" -> ["hello", "world"], "foo bar" -> ["foo", "bar"]
    try testing.expectEqual(@as(usize, 4), chunks.len);
    try testing.expectEqualStrings("hello", chunks[0]);
    try testing.expectEqualStrings("world", chunks[1]);
    try testing.expectEqualStrings("foo", chunks[2]);
    try testing.expectEqualStrings("bar", chunks[3]);
}

test "wrapText: handles empty segments from blank lines" {
    const chunks = try wrapText(testing.allocator, "a\n\nb", 10);
    defer {
        for (chunks) |c| testing.allocator.free(c);
        testing.allocator.free(chunks);
    }
    try testing.expectEqual(@as(usize, 3), chunks.len);
    try testing.expectEqualStrings("a", chunks[0]);
    try testing.expectEqualStrings("", chunks[1]);
    try testing.expectEqualStrings("b", chunks[2]);
}

test "Viewport.render handles multiline assistant message" {
    var vp = Viewport.init(testing.allocator);
    defer vp.deinit();
    // Simulate assistant message with 3 lines
    try vp.appendLine("line1", .{});
    try vp.appendLine("line2", .{});
    try vp.appendLine("line3", .{});

    var f = try vp.render(testing.allocator, 20, 5);
    defer f.deinit(testing.allocator);

    try testing.expectEqual(@as(u21, 'l'), f.get(0, 0).char);
    try testing.expectEqual(@as(u21, '1'), f.get(4, 0).char);
    try testing.expectEqual(@as(u21, 'l'), f.get(0, 1).char);
    try testing.expectEqual(@as(u21, '2'), f.get(4, 1).char);
    try testing.expectEqual(@as(u21, 'l'), f.get(0, 2).char);
    try testing.expectEqual(@as(u21, '3'), f.get(4, 2).char);
}

test "Input: cursor cell uses foreground-only caret (round-3: bg inherits black default)" {
    var in = Input.init(testing.allocator);
    defer in.deinit();
    _ = try in.handleKey(.{ .rune = 'a' });
    var f = try in.render(testing.allocator, 20);
    defer f.deinit(testing.allocator);
    // Cursor sits at column 3 ("> a" is 3 chars: '>', ' ', 'a').
    const cursor = f.get(3, 0);
    try testing.expectEqual(@as(u21, '|'), cursor.char);
    // Round-3: bg now inherits the Cell default (.black) via the
    // writeText "preserve existing bg when style.bg is null" rule,
    // so the TUI looks consistent on light-themed terminals. The
    // cursor still has no EXPLICIT bg attribute.
    try testing.expectEqual(@as(?@import("color.zig").Color, .black), cursor.bg);
    try testing.expectEqual(@as(?@import("color.zig").Color, .white), cursor.fg);
    try testing.expect(cursor.bold);
}
