//! Frame: a 2-D grid of styled cells + the diff algorithm that turns
//! two frames into a minimal byte stream of cursor moves, SGR codes,
//! and UTF-8 runes.

const std = @import("std");
const color = @import("color.zig");

pub const Cell = struct {
    char: u21 = ' ',
    fg: ?color.Color = null,
    bg: ?color.Color = null,
    bold: bool = false,
};

pub const Cursor = struct { x: u16, y: u16 };

pub const Frame = struct {
    width: u16,
    height: u16,
    /// Row-major, len == width * height. Owned by the frame.
    cells: []Cell,
    cursor: ?Cursor = null,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Frame {
        const cells = try allocator.alloc(Cell, @as(usize, width) * height);
        @memset(cells, Cell{});
        return .{ .width = width, .height = height, .cells = cells };
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn get(self: *const Frame, x: u16, y: u16) Cell {
        if (x >= self.width or y >= self.height) return .{};
        return self.cells[@as(usize, y) * self.width + x];
    }

    pub fn set(self: *Frame, x: u16, y: u16, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[@as(usize, y) * self.width + x] = cell;
    }

    /// Write `text` starting at (x, y), clipped to the frame bounds.
    /// Returns the x position just past the last written char.
    pub fn writeText(self: *Frame, x: u16, y: u16, text: []const u8, style: Style) u16 {
        var cx = x;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |cp| {
            if (cx >= self.width) break;
            self.set(cx, y, .{
                .char = cp,
                .fg = style.fg,
                .bg = style.bg,
                .bold = style.bold,
            });
            cx += 1;
        }
        return cx;
    }
};

/// Per-cell style flags used by `writeText` (mirrors style.Style but
/// without allocation).
pub const Style = struct {
    fg: ?color.Color = null,
    bg: ?color.Color = null,
    bold: bool = false,
};

/// Diff `next` against `prev`, returning an owned byte stream that
/// repaints only what changed. The first draw (prev == null or
/// dimensions changed) is a full repaint preceded by clear-screen.
///
/// The emitted stream uses:
///   - `\x1b[<row>;<col>H`  — move cursor (1-based)
///   - `\x1b[<n>m`          — SGR (bold / fg / bg), only on change
///   - `\x1b[0m`            — reset when leaving a styled run
///   - UTF-8 bytes          — the rune itself
pub fn diff(
    allocator: std.mem.Allocator,
    prev: ?*const Frame,
    next: *const Frame,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const full_repaint = blk: {
        const p = prev orelse break :blk true;
        break :blk p.width != next.width or p.height != next.height;
    };

    if (full_repaint) {
        try w.writeAll("\x1b[2J"); // clear screen
    }

    var cur_style = Style{};
    var need_move = full_repaint;

    var y: u16 = 0;
    while (y < next.height) : (y += 1) {
        var x: u16 = 0;
        while (x < next.width) : (x += 1) {
            const c = next.get(x, y);
            const unchanged = blk: {
                if (full_repaint) break :blk false;
                const p = prev.?.get(x, y);
                break :blk std.meta.eql(p, c);
            };
            if (unchanged) continue;

            // Move cursor if we're not already there.
            if (need_move or x != last_x + 1 or y != last_y) {
                try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
            }
            // Emit SGR only when the style changed.
            const new_style = Style{ .fg = c.fg, .bg = c.bg, .bold = c.bold };
            if (!std.meta.eql(cur_style, new_style)) {
                try writeSgr(w, new_style);
                cur_style = new_style;
            }
            // Write the rune as UTF-8.
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c.char, &buf) catch blk: {
                buf[0] = '?';
                break :blk 1;
            };
            try w.writeAll(buf[0..n]);

            last_x = x;
            last_y = y;
            need_move = false;
        }
    }

    // Position the terminal cursor where the frame wants it (input line).
    if (next.cursor) |cur| {
        try w.print("\x1b[{d};{d}H", .{ cur.y + 1, cur.x + 1 });
    } else {
        // Park at bottom-left to avoid stray artifacts.
        try w.print("\x1b[{d};1H", .{next.height});
    }

    return aw.toOwnedSlice();
}

// Module-level "last emitted position" for diff(). Not thread-safe by
// design — Program.run() is single-threaded on the render path.
var last_x: i32 = -2;
var last_y: i32 = -2;

fn writeSgr(w: anytype, s: Style) !void {
    // Reset then re-apply; simplest correct sequence for arbitrary
    // transitions (bold off requires an explicit 22 on some terminals).
    try w.writeAll("\x1b[0");
    if (s.bold) try w.writeAll(";1");
    if (s.fg) |fg| try w.print(";{d}", .{fg.fgCode()});
    if (s.bg) |bg| try w.print(";{d}", .{bg.bgCode()});
    try w.writeAll("m");
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "Frame: init zeroes cells and get/set round-trips" {
    var f = try Frame.init(testing.allocator, 10, 5);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u21, ' '), f.get(3, 2).char);
    f.set(3, 2, .{ .char = 'x' });
    try testing.expectEqual(@as(u21, 'x'), f.get(3, 2).char);
}

test "Frame: set out of bounds is a no-op" {
    var f = try Frame.init(testing.allocator, 4, 4);
    defer f.deinit(testing.allocator);
    f.set(100, 100, .{ .char = '!' }); // must not crash
    try testing.expectEqual(@as(u21, ' '), f.get(0, 0).char);
}

test "Frame: writeText clips to width" {
    var f = try Frame.init(testing.allocator, 4, 1);
    defer f.deinit(testing.allocator);
    // Writing "abcdef" from x=2 fills x=2..3 with 'a','b' and clips.
    const end_x = f.writeText(2, 0, "abcdef", .{});
    try testing.expectEqual(@as(u16, 4), end_x);
    try testing.expectEqual(@as(u21, 'a'), f.get(2, 0).char);
    try testing.expectEqual(@as(u21, 'b'), f.get(3, 0).char);
}

test "diff: identical frames produce no cell writes" {
    var a = try Frame.init(testing.allocator, 8, 3);
    defer a.deinit(testing.allocator);
    var b = try Frame.init(testing.allocator, 8, 3);
    defer b.deinit(testing.allocator);
    a.set(1, 1, .{ .char = 'h' });
    b.set(1, 1, .{ .char = 'h' });

    const out = try diff(testing.allocator, &a, &b);
    defer testing.allocator.free(out);
    // Only the trailing cursor-park sequence is emitted.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") == null);
    try testing.expectEqualStrings("\x1b[3;1H", out);
}

test "diff: first draw is a full repaint with clear-screen" {
    var b = try Frame.init(testing.allocator, 4, 2);
    defer b.deinit(testing.allocator);
    b.set(0, 0, .{ .char = 'h' });

    const out = try diff(testing.allocator, null, &b);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") != null);
    try testing.expect(std.mem.indexOf(u8, out, "h") != null);
}

test "diff: single cell change emits one move + one rune" {
    var a = try Frame.init(testing.allocator, 8, 2);
    defer a.deinit(testing.allocator);
    var b = try Frame.init(testing.allocator, 8, 2);
    defer b.deinit(testing.allocator);
    b.set(3, 1, .{ .char = 'X', .bold = true });

    const out = try diff(testing.allocator, &a, &b);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2;4H") != null); // row 2 col 4
    try testing.expect(std.mem.indexOf(u8, out, "X") != null);
    try testing.expect(std.mem.indexOf(u8, out, ";1m") != null); // bold SGR
}

test "diff: resize triggers full repaint" {
    var a = try Frame.init(testing.allocator, 8, 2);
    defer a.deinit(testing.allocator);
    var b = try Frame.init(testing.allocator, 6, 2);
    defer b.deinit(testing.allocator);

    const out = try diff(testing.allocator, &a, &b);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") != null);
}
