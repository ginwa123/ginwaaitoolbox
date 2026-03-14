//! Rich text rendering module for TUI
//! Provides ANSI color codes, text styles, and builder pattern for styled text output

const std = @import("std");

/// ANSI escape code sequences
pub const ansi = struct {
    /// Reset all attributes
    pub const reset: []const u8 = "\x1b[0m";

    /// Text styles
    pub const bold: []const u8 = "\x1b[1m";
    pub const dim: []const u8 = "\x1b[2m";
    pub const italic: []const u8 = "\x1b[3m";
    pub const underline: []const u8 = "\x1b[4m";
    pub const blink: []const u8 = "\x1b[5m";
    pub const reverse: []const u8 = "\x1b[7m";
    pub const hidden: []const u8 = "\x1b[8m";
    pub const strikethrough: []const u8 = "\x1b[9m";

    /// Foreground colors (30-37)
    pub const black: []const u8 = "\x1b[30m";
    pub const red: []const u8 = "\x1b[31m";
    pub const green: []const u8 = "\x1b[32m";
    pub const yellow: []const u8 = "\x1b[33m";
    pub const blue: []const u8 = "\x1b[34m";
    pub const magenta: []const u8 = "\x1b[35m";
    pub const cyan: []const u8 = "\x1b[36m";
    pub const white: []const u8 = "\x1b[37m";

    /// Bright foreground colors (90-97)
    pub const bright_black: []const u8 = "\x1b[90m";
    pub const bright_red: []const u8 = "\x1b[91m";
    pub const bright_green: []const u8 = "\x1b[92m";
    pub const bright_yellow: []const u8 = "\x1b[93m";
    pub const bright_blue: []const u8 = "\x1b[94m";
    pub const bright_magenta: []const u8 = "\x1b[95m";
    pub const bright_cyan: []const u8 = "\x1b[96m";
    pub const bright_white: []const u8 = "\x1b[97m";

    /// Background colors (40-47)
    pub const bg_black: []const u8 = "\x1b[40m";
    pub const bg_red: []const u8 = "\x1b[41m";
    pub const bg_green: []const u8 = "\x1b[42m";
    pub const bg_yellow: []const u8 = "\x1b[43m";
    pub const bg_blue: []const u8 = "\x1b[44m";
    pub const bg_magenta: []const u8 = "\x1b[45m";
    pub const bg_cyan: []const u8 = "\x1b[46m";
    pub const bg_white: []const u8 = "\x1b[47m";

    /// Bright background colors (100-107)
    pub const bg_bright_black: []const u8 = "\x1b[100m";
    pub const bg_bright_red: []const u8 = "\x1b[101m";
    pub const bg_bright_green: []const u8 = "\x1b[102m";
    pub const bg_bright_yellow: []const u8 = "\x1b[103m";
    pub const bg_bright_blue: []const u8 = "\x1b[104m";
    pub const bg_bright_magenta: []const u8 = "\x1b[105m";
    pub const bg_bright_cyan: []const u8 = "\x1b[106m";
    pub const bg_bright_white: []const u8 = "\x1b[107m";

    /// Cursor movements
    pub const cursor_home: []const u8 = "\x1b[H";
    pub const cursor_up: []const u8 = "\x1b[A";
    pub const cursor_down: []const u8 = "\x1b[B";
    pub const cursor_forward: []const u8 = "\x1b[C";
    pub const cursor_back: []const u8 = "\x1b[D";
    pub const clear_screen: []const u8 = "\x1b[2J";
    pub const clear_line: []const u8 = "\x1b[2K";

    /// Generate custom color code (256 colors)
    pub fn fg256(r: u8, g: u8, b: u8) [8]u8 {
        var buf: [8]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "\x1b[38;2;{};{};{}m", .{ r, g, b }) catch return "".*;
        return buf[0..len].*;
    }

    /// Generate custom background color code (256 colors)
    pub fn bg256(r: u8, g: u8, b: u8) [11]u8 {
        var buf: [11]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "\x1b[48;2;{};{};{}m", .{ r, g, b }) catch return "".*;
        return buf[0..len].*;
    }

    /// Generate 256-color palette code
    pub fn color256(index: u8) [9]u8 {
        var buf: [9]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "\x1b[38;5;{}m", .{index}) catch return "".*;
        return buf[0..len].*;
    }
};

/// Foreground color enum
pub const Color = enum(u8) {
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,
};

/// Background color enum
pub const BgColor = enum(u8) {
    black = 40,
    red = 41,
    green = 42,
    yellow = 43,
    blue = 44,
    magenta = 45,
    cyan = 46,
    white = 47,
    bright_black = 100,
    bright_red = 101,
    bright_green = 102,
    bright_yellow = 103,
    bright_blue = 104,
    bright_magenta = 105,
    bright_cyan = 106,
    bright_white = 107,
};

/// Text style flags
pub const Style = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,

    /// Convert style flags to ANSI escape sequence
    pub fn toAnsi(self: Style) []const u8 {
        var buf: [64]u8 = undefined;
        var list = std.ArrayList([]const u8).init(std.heap.page_allocator);
        defer list.deinit();

        if (self.bold) list.append(ansi.bold) catch {};
        if (self.dim) list.append(ansi.dim) catch {};
        if (self.italic) list.append(ansi.italic) catch {};
        if (self.underline) list.append(ansi.underline) catch {};
        if (self.blink) list.append(ansi.blink) catch {};
        if (self.reverse) list.append(ansi.reverse) catch {};
        if (self.hidden) list.append(ansi.hidden) catch {};
        if (self.strikethrough) list.append(ansi.strikethrough) catch {};

        if (list.items.len == 0) return "";

        var total_len: usize = 0;
        for (list.items) |s| total_len += s.len;

        var result = buf[0..total_len];
        var offset: usize = 0;
        for (list.items) |s| {
            @memcpy(result[offset..], s);
            offset += s.len;
        }
        return result;
    }
};

/// Rich text segment with styling
pub const TextSegment = struct {
    text: []const u8,
    fg: ?Color = null,
    bg: ?BgColor = null,
    style: Style = .{},

    /// Render this segment to a string
    pub fn render(self: TextSegment, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        // Apply foreground color
        if (self.fg) |c| {
            try result.appendSlice(switch (c) {
                .black => ansi.black,
                .red => ansi.red,
                .green => ansi.green,
                .yellow => ansi.yellow,
                .blue => ansi.blue,
                .magenta => ansi.magenta,
                .cyan => ansi.cyan,
                .white => ansi.white,
                .bright_black => ansi.bright_black,
                .bright_red => ansi.bright_red,
                .bright_green => ansi.bright_green,
                .bright_yellow => ansi.bright_yellow,
                .bright_blue => ansi.bright_blue,
                .bright_magenta => ansi.bright_magenta,
                .bright_cyan => ansi.bright_cyan,
                .bright_white => ansi.bright_white,
            });
        }

        // Apply background color
        if (self.bg) |c| {
            try result.appendSlice(switch (c) {
                .black => ansi.bg_black,
                .red => ansi.bg_red,
                .green => ansi.bg_green,
                .yellow => ansi.bg_yellow,
                .blue => ansi.bg_blue,
                .magenta => ansi.bg_magenta,
                .cyan => ansi.bg_cyan,
                .white => ansi.bg_white,
                .bright_black => ansi.bg_bright_black,
                .bright_red => ansi.bg_bright_red,
                .bright_green => ansi.bg_bright_green,
                .bright_yellow => ansi.bg_bright_yellow,
                .bright_blue => ansi.bg_bright_blue,
                .bright_magenta => ansi.bg_bright_magenta,
                .bright_cyan => ansi.bg_bright_cyan,
                .bright_white => ansi.bg_bright_white,
            });
        }

        // Apply styles
        if (self.style.bold) try result.appendSlice(ansi.bold);
        if (self.style.dim) try result.appendSlice(ansi.dim);
        if (self.style.italic) try result.appendSlice(ansi.italic);
        if (self.style.underline) try result.appendSlice(ansi.underline);
        if (self.style.blink) try result.appendSlice(ansi.blink);
        if (self.style.reverse) try result.appendSlice(ansi.reverse);
        if (self.style.hidden) try result.appendSlice(ansi.hidden);
        if (self.style.strikethrough) try result.appendSlice(ansi.strikethrough);

        // Add text
        try result.appendSlice(self.text);

        // Reset
        try result.appendSlice(ansi.reset);

        return result.toOwnedSlice();
    }
};

/// Rich text builder for fluent API
pub const RichText = struct {
    segments: std.ArrayList(TextSegment),
    allocator: std.mem.Allocator,

    /// Initialize a new RichText builder
    pub fn init(allocator: std.mem.Allocator) RichText {
        return .{
            .segments = std.ArrayList(TextSegment).init(allocator),
            .allocator = allocator,
        };
    }

    /// Add plain text (no styling)
    pub fn text(self: *RichText, txt: []const u8) !*RichText {
        try self.segments.append(.{ .text = txt });
        return self;
    }

    /// Add styled text segment
    pub fn add(self: *RichText, segment: TextSegment) !*RichText {
        try self.segments.append(segment);
        return self;
    }

    /// Add text with foreground color
    pub fn fg(self: *RichText, txt: []const u8, color: Color) !*RichText {
        try self.segments.append(.{ .text = txt, .fg = color });
        return self;
    }

    /// Add text with background color
    pub fn bg(self: *RichText, txt: []const u8, color: BgColor) !*RichText {
        try self.segments.append(.{ .text = txt, .bg = color });
        return self;
    }

    /// Add text with both foreground and background
    pub fn color(self: *RichText, txt: []const u8, foreground: Color, background: BgColor) !*RichText {
        try self.segments.append(.{ .text = txt, .fg = foreground, .bg = background });
        return self;
    }

    /// Add bold text
    pub fn bold(self: *RichText, txt: []const u8) !*RichText {
        try self.segments.append(.{ .text = txt, .style = .{ .bold = true } });
        return self;
    }

    /// Add italic text
    pub fn italic(self: *RichText, txt: []const u8) !*RichText {
        try self.segments.append(.{ .text = txt, .style = .{ .italic = true } });
        return self;
    }

    /// Add underlined text
    pub fn underline(self: *RichText, txt: []const u8) !*RichText {
        try self.segments.append(.{ .text = txt, .style = .{ .underline = true } });
        return self;
    }

    /// Add error styled text (red)
    pub fn error(self: *RichText, txt: []const u8) !*RichText {
        try self.segments.append(.{ .text = txt, .fg = .red, .style = .{ .bold = true } });
        return self;
    }

    /// Add success styled text (green)
    pub fn success(self: *RichText, txt: []const u8) !*RichText {
        try self.segments.append(.{ .text = txt, .fg = .green });
        return self;
    }

    /// Add warning styled text (yellow)
    pub fn warning(self: *RichText, txt: []const u8) !*RichText {
        try self.segments.append(.{ .text = txt, .fg = .yellow });
        return self;
    }

    /// Add info styled text (cyan)
    pub fn info(self: *RichText, txt: []const u8) !*RichText {
        try self.segments.append(.{ .text = txt, .fg = .cyan });
        return self;
    }

    /// Add highlighted text (magenta, bold)
    pub fn highlight(self: *RichText, txt: []const u8) !*RichText {
        try self.segments.append(.{ .text = txt, .fg = .magenta, .style = .{ .bold = true } });
        return self;
    }

    /// Add dimmed text
    pub fn dim(self: *RichText, txt: []const u8) !*RichText {
        try self.segments.append(.{ .text = txt, .style = .{ .dim = true } });
        return self;
    }

    /// Build and render the rich text
    pub fn render(self: *RichText) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        for (self.segments.items) |segment| {
            const rendered = try segment.render(self.allocator);
            defer self.allocator.free(rendered);
            try result.appendSlice(rendered);
        }

        return result.toOwnedSlice();
    }

    /// Print the rich text to stdout
    pub fn print(self: *RichText) !void {
        const rendered = try self.render();
        defer self.allocator.free(rendered);
        std.debug.print("{s}", .{rendered});
    }

    /// Print with newline
    pub fn println(self: *RichText) !void {
        try self.print();
        std.debug.print("\n", .{});
    }

    /// Free the rich text resources
    pub fn deinit(self: *RichText) void {
        self.segments.deinit();
    }
};

/// Printf-style formatting with colors
pub fn printf(comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(formatted);
    std.debug.print("{s}", .{formatted});
}

/// Printf with foreground color
pub fn printfc(color: Color, comptime fmt: []const u8, args: anytype) !void {
    const color_ansi = switch (color) {
        .black => ansi.black,
        .red => ansi.red,
        .green => ansi.green,
        .yellow => ansi.yellow,
        .blue => ansi.blue,
        .magenta => ansi.magenta,
        .cyan => ansi.cyan,
        .white => ansi.white,
        .bright_black => ansi.bright_black,
        .bright_red => ansi.bright_red,
        .bright_green => ansi.bright_green,
        .bright_yellow => ansi.bright_yellow,
        .bright_blue => ansi.bright_blue,
        .bright_magenta => ansi.bright_magenta,
        .bright_cyan => ansi.bright_cyan,
        .bright_white => ansi.bright_white,
    };
    const formatted = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(formatted);
    std.debug.print("{s}{s}{s}", .{ color_ansi, formatted, ansi.reset });
}

/// Printf with foreground and background color
pub fn printfbg(fg: Color, bg: BgColor, comptime fmt: []const u8, args: anytype) !void {
    const fg_ansi = switch (fg) {
        .black => ansi.black,
        .red => ansi.red,
        .green => ansi.green,
        .yellow => ansi.yellow,
        .blue => ansi.blue,
        .magenta => ansi.magenta,
        .cyan => ansi.cyan,
        .white => ansi.white,
        .bright_black => ansi.bright_black,
        .bright_red => ansi.bright_red,
        .bright_green => ansi.bright_green,
        .bright_yellow => ansi.bright_yellow,
        .bright_blue => ansi.bright_blue,
        .bright_magenta => ansi.bright_magenta,
        .bright_cyan => ansi.bright_cyan,
        .bright_white => ansi.bright_white,
    };
    const bg_ansi = switch (bg) {
        .black => ansi.bg_black,
        .red => ansi.bg_red,
        .green => ansi.bg_green,
        .yellow => ansi.bg_yellow,
        .blue => ansi.bg_blue,
        .magenta => ansi.bg_magenta,
        .cyan => ansi.bg_cyan,
        .white => ansi.bg_white,
        .bright_black => ansi.bg_bright_black,
        .bright_red => ansi.bg_bright_red,
        .bright_green => ansi.bg_bright_green,
        .bright_yellow => ansi.bg_bright_yellow,
        .bright_blue => ansi.bg_bright_blue,
        .bright_magenta => ansi.bg_bright_magenta,
        .bright_cyan => ansi.bg_bright_cyan,
        .bright_white => ansi.bg_bright_white,
    };
    const formatted = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(formatted);
    std.debug.print("{s}{s}{s}{s}", .{ fg_ansi, bg_ansi, formatted, ansi.reset });
}

/// Print error message (red, bold)
pub fn printError(comptime fmt: []const u8, args: anytype) !void {
    try printfc(.red, fmt, args);
    std.debug.print("\n", .{});
}

/// Print success message (green)
pub fn printSuccess(comptime fmt: []const u8, args: anytype) !void {
    try printfc(.green, fmt, args);
    std.debug.print("\n", .{});
}

/// Print warning message (yellow)
pub fn printWarning(comptime fmt: []const u8, args: anytype) !void {
    try printfc(.yellow, fmt, args);
    std.debug.print("\n", .{});
}

/// Print info message (cyan)
pub fn printInfo(comptime fmt: []const u8, args: anytype) !void {
    try printfc(.cyan, fmt, args);
    std.debug.print("\n", .{});
}

/// Quick print helpers for common colors
pub const p = struct {
    /// Print in given color
    pub fn c(color: Color, txt: []const u8) void {
        printfc(color, "{s}", .{txt}) catch {};
    }

    /// Print bold
    pub fn b(txt: []const u8) void {
        std.debug.print("{s}{s}{s}\n", .{ ansi.bold, txt, ansi.reset });
    }

    /// Print with underline
    pub fn u(txt: []const u8) void {
        std.debug.print("{s}{s}{s}\n", .{ ansi.underline, txt, ansi.reset });
    }

    /// Print error (red)
    pub fn e(txt: []const u8) void {
        p.c(.red, txt);
    }

    /// Print success (green)
    pub fn s(txt: []const u8) void {
        p.c(.green, txt);
    }

    /// Print warning (yellow)
    pub fn w(txt: []const u8) void {
        p.c(.yellow, txt);
    }

    /// Print info (cyan)
    pub fn i(txt: []const u8) void {
        p.c(.cyan, txt);
    }

    /// Print highlighted (magenta, bold)
    pub fn h(txt: []const u8) void {
        std.debug.print("{s}{s}{s}{s}\n", .{ ansi.bright_magenta, ansi.bold, txt, ansi.reset });
    }
};

test "rich text basic" {
    var rt = RichText.init(std.testing.allocator);
    defer rt.deinit();

    try rt.text("Hello ").fg("World", .red).text("!");
    const output = try rt.render();
    defer std.testing.allocator.free(output);
    try std.testing.expect(output.len > 0);
}

test "color enum" {
    try std.testing.expect(@intFromEnum(Color.red) == 31);
    try std.testing.expect(@intFromEnum(BgColor.blue) == 44);
}
