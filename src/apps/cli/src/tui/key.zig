//! Key events parsed from raw terminal input.

const std = @import("std");

pub const Key = union(enum) {
    /// A printable rune (Unicode scalar value).
    rune: u21,
    enter,
    tab,
    backspace,
    delete,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    /// SGR-encoded mouse wheel up (button 64). See the test block
    /// below for the wire shape.
    wheel_up,
    /// SGR-encoded mouse wheel down (button 65).
    wheel_down,
    ctrl_c,
    ctrl_d,
    ctrl_u,
    ctrl_w,
    ctrl_l,
};

/// Parse one key from the head of `buf`. Returns the key and how many
/// bytes it consumed. Returns null if `buf` is empty or starts with an
/// incomplete escape sequence (caller should read more bytes).
///
/// Supported sequences:
///   - Single-byte control codes: 0x03 Ctrl-C, 0x04 Ctrl-D, 0x08/0x7F
///     Backspace, 0x09 Tab, 0x0A/0x0D Enter, 0x0C Ctrl-L, 0x15 Ctrl-U,
///     0x17 Ctrl-W.
///   - `\x1b` alone → escape.
///   - `\x1b[A/B/C/D` → arrows; `\x1b[H` / `\x1b[F` → Home/End;
///     `\x1b[5~` / `\x1b[6~` → PageUp/PageDown; `\x1b[3~` → Delete.
///   - UTF-8 multi-byte runes (2–4 byte lead + continuation bytes).
pub fn parse(buf: []const u8) !?struct { key: Key, len: usize } {
    if (buf.len == 0) return null;
    const b = buf[0];
    switch (b) {
        0x03 => return .{ .key = .ctrl_c, .len = 1 },
        0x04 => return .{ .key = .ctrl_d, .len = 1 },
        0x08, 0x7F => return .{ .key = .backspace, .len = 1 },
        0x09 => return .{ .key = .tab, .len = 1 },
        0x0A, 0x0D => return .{ .key = .enter, .len = 1 },
        0x0C => return .{ .key = .ctrl_l, .len = 1 },
        0x15 => return .{ .key = .ctrl_u, .len = 1 },
        0x17 => return .{ .key = .ctrl_w, .len = 1 },
        0x1B => {
            if (buf.len == 1) return .{ .key = .escape, .len = 1 };
            // CSI sequences: ESC [ <params> <final>
            if (buf[1] == '[') {
                // SGR mouse: ESC [ < button ; col ; row M (or m for release).
                // Distinguish from ordinary CSI by the '<' prefix character
                // and the final byte (M or m). We treat the rest of the
                // existing CSI dispatch as a fallback.
                // NB: need buf.len > 2 (strict) so index 2 is in-range.
                if (buf.len > 2 and buf[2] == '<') {
                    var i: usize = 3;
                    while (i < buf.len and (std.ascii.isDigit(buf[i]) or buf[i] == ';')) : (i += 1) {}
                    if (i >= buf.len) return null; // incomplete
                    const final = buf[i];
                    if (final != 'M' and final != 'm') return null; // not SGR mouse
                    const consumed = i + 1;
                    // Parse the button field (params[0]) — col/row are
                    // ignored in v1 (no click handling). button is the
                    // FIRST ';'-separated number after '<'.
                    const semicolon = std.mem.indexOfScalar(u8, buf[3..i], ';') orelse 0;
                    const button_str = buf[3 .. 3 + semicolon];
                    const button = std.fmt.parseInt(u16, button_str, 10) catch {
                        return null;
                    };
                    const k: ?Key = switch (button) {
                        64 => .wheel_up,
                        65 => .wheel_down,
                        else => null, // 0/1/2 = clicks — ignore for v1
                    };
                    if (k) |key| return .{ .key = key, .len = consumed };
                    return null; // unhandled SGR mouse event — drop
                }

                var i: usize = 2;
                while (i < buf.len and (std.ascii.isDigit(buf[i]) or buf[i] == ';')) : (i += 1) {}
                if (i >= buf.len) return null; // incomplete — need more bytes
                const final = buf[i];
                const params = buf[2..i];
                const consumed = i + 1;
                const k: ?Key = switch (final) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    '~' => blk: {
                        if (params.len == 1 and std.ascii.isDigit(params[0])) {
                            switch (params[0]) {
                                '3' => break :blk .delete,
                                '5' => break :blk .page_up,
                                '6' => break :blk .page_down,
                                else => break :blk null,
                            }
                        }
                        break :blk null;
                    },
                    else => null,
                };
                if (k) |key| return .{ .key = key, .len = consumed };
                // Unknown CSI — swallow it so we don't loop forever.
                return .{ .key = .escape, .len = consumed };
            }
            // Unknown escape prefix (e.g. Alt-key) — consume ESC only.
            return .{ .key = .escape, .len = 1 };
        },
        else => {
            // UTF-8 rune. Determine sequence length from the lead byte.
            const seq_len: usize = std.unicode.utf8ByteSequenceLength(b) catch {
                // Invalid lead byte — skip it.
                return .{ .key = .{ .rune = 0xFFFD }, .len = 1 };
            };
            if (buf.len < seq_len) return null; // incomplete
            const cp = std.unicode.utf8Decode(buf[0..seq_len]) catch {
                return .{ .key = .{ .rune = 0xFFFD }, .len = seq_len };
            };
            return .{ .key = .{ .rune = cp }, .len = seq_len };
        },
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "parse: ascii runes" {
    const r = (try parse("a")).?;
    try testing.expectEqual(Key{ .rune = 'a' }, r.key);
    try testing.expectEqual(@as(usize, 1), r.len);

    const z = (try parse("Z")).?;
    try testing.expectEqual(Key{ .rune = 'Z' }, z.key);

    const five = (try parse("5")).?;
    try testing.expectEqual(Key{ .rune = '5' }, five.key);
}

test "parse: backspace variants" {
    try testing.expectEqual(Key.backspace, (try parse(&.{0x7F})).?.key);
    try testing.expectEqual(Key.backspace, (try parse(&.{0x08})).?.key);
}

test "parse: ctrl-c" {
    try testing.expectEqual(Key.ctrl_c, (try parse(&.{0x03})).?.key);
}

test "parse: enter (CR and LF)" {
    try testing.expectEqual(Key.enter, (try parse(&.{0x0D})).?.key);
    try testing.expectEqual(Key.enter, (try parse(&.{0x0A})).?.key);
}

test "parse: arrow keys" {
    try testing.expectEqual(Key.up, (try parse("\x1b[A")).?.key);
    try testing.expectEqual(Key.down, (try parse("\x1b[B")).?.key);
    try testing.expectEqual(Key.right, (try parse("\x1b[C")).?.key);
    try testing.expectEqual(Key.left, (try parse("\x1b[D")).?.key);
}

test "parse: home/end/delete/page keys" {
    try testing.expectEqual(Key.home, (try parse("\x1b[H")).?.key);
    try testing.expectEqual(Key.end, (try parse("\x1b[F")).?.key);
    try testing.expectEqual(Key.delete, (try parse("\x1b[3~")).?.key);
    try testing.expectEqual(Key.page_up, (try parse("\x1b[5~")).?.key);
    try testing.expectEqual(Key.page_down, (try parse("\x1b[6~")).?.key);
}

// ----------------------------------------------------------------------------
// SGR mouse wheel (round-2 — Task 5)
// ----------------------------------------------------------------------------
//
// Format: \x1b[<button;col;rowM (uppercase M = press, lowercase m = release).
//   button 64 = wheel up, 65 = wheel down (no modifier). Other buttons
//   (clicks, drags) are ignored in v1 — parser returns null so the
//   dispatcher drops them without entering an infinite loop.
//
// We enable SGR mode (CSI ? 1006 h) and basic mouse tracking (CSI ?
// 1000 h) on program startup, so the terminal is guaranteed to send
// the modern format. X10 mode (legacy \x1b[M + 3 bytes) is NOT
// supported in v1.

test "parse: SGR mouse wheel up = button 64" {
    const got = (try parse("\x1b[<64;12;8M")).?.key;
    try testing.expectEqual(Key.wheel_up, got);
}

test "parse: SGR mouse wheel down = button 65" {
    const got = (try parse("\x1b[<65;12;8M")).?.key;
    try testing.expectEqual(Key.wheel_down, got);
}

test "parse: SGR mouse press (button 0) returns null, not a wheel key" {
    // \x1b[<0;10;5M → left-button press; v1 ignores clicks.
    const got = try parse("\x1b[<0;10;5M");
    try testing.expect(got == null);
}

test "parse: SGR mouse release (button 0, lowercase m) returns null" {
    // \x1b[<0;10;5m → release; same as press — ignored in v1.
    const got = try parse("\x1b[<0;10;5m");
    try testing.expect(got == null);
}

test "parse: incomplete escape returns null" {
    try testing.expect((try parse("\x1b")) != null); // lone ESC is valid
    try testing.expect((try parse("\x1b[")) == null);
    try testing.expect((try parse("\x1b[A")) != null);
}

test "parse: utf8 two-byte rune" {
    // é = U+00E9 = 0xC3 0xA9
    const r = (try parse("\xc3\xa9")).?;
    try testing.expectEqual(Key{ .rune = 0xE9 }, r.key);
    try testing.expectEqual(@as(usize, 2), r.len);
}

test "parse: utf8 three-byte rune" {
    // ✓ = U+2713 = 0xE2 0x9C 0x93
    const r = (try parse("\xe2\x9c\x93")).?;
    try testing.expectEqual(Key{ .rune = 0x2713 }, r.key);
}

test "parse: empty buffer returns null" {
    try testing.expect(try parse("") == null);
}
