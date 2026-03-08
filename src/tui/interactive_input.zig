const std = @import("std");
const input_module = @import("input.zig");
const Input = input_module.Input;
const builtin = @import("builtin");

const reset = "\x1b[0m";
const bold = "\x1b[1m";
const cyan = "\x1b[36m";
const green = "\x1b[32m";
const yellow = "\x1b[33m";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original_termios = try enableRawMode();
    defer disableRawMode(original_termios);

    std.debug.print("\x1b[2J\x1b[H", .{});

    std.debug.print("{s}=== Interactive TUI Input Demo ==={s}\n\n", .{ cyan, reset });
    std.debug.print("{s}Instructions:{s}\n", .{ bold, reset });
    std.debug.print("  - Type to enter text\n", .{});
    std.debug.print("  - Arrow keys: move cursor\n", .{});
    std.debug.print("  - Home/End: jump to start/end\n", .{});
    std.debug.print("  - Backspace: remove characters\n", .{});
    std.debug.print("  - Enter: submit and exit\n", .{});
    std.debug.print("  - Esc: cancel and exit\n", .{});

    const text_input = try Input.init(allocator, .{
        .width = 60,
        .mode = .single_line,
        .style = .boxed,
        .title = "Enter your message",
        .placeholder = "Start typing...",
    });
    defer text_input.destroy();

    try renderInput(text_input, 8);
    try moveCursorToInput(text_input, 8);

    var running = true;
    while (running) {
        const char = try readByte();
        
        switch (char) {
            13, 10 => {
                running = false;
                try submitInput(text_input);
            },
            27 => {
                const next_char = readNextByte() catch 0;
                if (next_char == '[') {
                    const seq_char = readNextByte() catch 0;
                    switch (seq_char) {
                        'A' => {},
                        'B' => {},
                        'C' => {
                            text_input.moveRight();
                            try renderInput(text_input, 8);
                            try moveCursorToInput(text_input, 8);
                        },
                        'D' => {
                            text_input.moveLeft();
                            try renderInput(text_input, 8);
                            try moveCursorToInput(text_input, 8);
                        },
                        'H' => {
                            text_input.moveHome();
                            try renderInput(text_input, 8);
                            try moveCursorToInput(text_input, 8);
                        },
                        'F' => {
                            text_input.moveEnd();
                            try renderInput(text_input, 8);
                            try moveCursorToInput(text_input, 8);
                        },
                        '1' => {
                            const final_char = readNextByte() catch 0;
                            if (final_char == '~') {
                                text_input.moveHome();
                                try renderInput(text_input, 8);
                                try moveCursorToInput(text_input, 8);
                            }
                        },
                        '4' => {
                            const final_char = readNextByte() catch 0;
                            if (final_char == '~') {
                                text_input.moveEnd();
                                try renderInput(text_input, 8);
                                try moveCursorToInput(text_input, 8);
                            }
                        },
                        else => {
                            running = false;
                            try cancelInput();
                        },
                    }
                } else {
                    running = false;
                    try cancelInput();
                }
            },
            8, 127 => {
                try text_input.backspace();
                try renderInput(text_input, 8);
                try moveCursorToInput(text_input, 8);
            },
            9 => {},
            32...126 => {
                try text_input.insert(char);
                try renderInput(text_input, 8);
                try moveCursorToInput(text_input, 8);
            },
            else => {},
        }
    }

    std.debug.print("\x1b[2J\x1b[H", .{});
}

fn enableRawMode() !std.posix.termios {
    const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw = original;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
    return original;
}

fn disableRawMode(original: std.posix.termios) void {
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, original) catch {};
}

fn readByte() !u8 {
    var buf: [1]u8 = undefined;
    const n = try std.posix.read(std.posix.STDIN_FILENO, &buf);
    if (n == 0) return error.EOF;
    return buf[0];
}

fn readNextByte() !u8 {
    var fds = [1]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    
    const timeout = 100;
    const result = std.posix.poll(&fds, timeout) catch 0;
    
    if (result > 0 and fds[0].revents & std.posix.POLL.IN != 0) {
        return readByte();
    }
    
    return error.Timeout;
}

fn renderInput(inp: *Input, row: u16) !void {
    std.debug.print("\x1b[{d};1H", .{row});
    std.debug.print("\x1b[2K", .{});
    const output = try inp.render();
    defer inp.allocator.free(output);
    std.debug.print("{s}", .{output});
}

fn moveCursorToInput(inp: *Input, row: u16) !void {
    const cursor_visible = inp.cursor - inp.scroll_offset;
    const border_offset: u16 = 1;
    const cursor_col = border_offset + cursor_visible + 1;
    std.debug.print("\x1b[{d};{d}H", .{ row + 1, cursor_col });
}

fn submitInput(inp: *Input) !void {
    std.debug.print("\x1b[15;1H", .{});
    std.debug.print("\x1b[2K", .{});
    
    const text = inp.getText();
    if (text.len > 0) {
        std.debug.print("{s}✓ Input submitted:{s}\n", .{ green, reset });
        std.debug.print("  {s}{s}{s}\n", .{ bold, text, reset });
    } else {
        std.debug.print("{s}⚠ Empty input submitted{s}\n", .{ yellow, reset });
    }
    
    std.debug.print("\nPress any key to exit...\n", .{});
    _ = try readByte();
}

fn cancelInput() !void {
    std.debug.print("\x1b[15;1H", .{});
    std.debug.print("\x1b[2K", .{});
    std.debug.print("{s}✗ Input cancelled{s}\n", .{ yellow, reset });
    std.debug.print("\nPress any key to exit...\n", .{});
    _ = try readByte();
}
