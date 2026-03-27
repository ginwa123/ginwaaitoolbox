const std = @import("std");
const builtin = @import("builtin");

// ANSI escape code sequences — inlined from former text.zig
pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const italic = "\x1b[3m";
pub const underline = "\x1b[4m";
pub const blink = "\x1b[5m";
pub const reverse = "\x1b[7m";
pub const hidden = "\x1b[8m";
pub const strikethrough = "\x1b[9m";

pub const cyan = "\x1b[36m";
pub const yellow = "\x1b[33m";
pub const green = "\x1b[32m";
pub const red = "\x1b[31m";
pub const blue = "\x1b[34m";
pub const magenta = "\x1b[35m";
pub const white = "\x1b[37m";
pub const bright_green = "\x1b[92m";
pub const bright_red = "\x1b[91m";
pub const bright_yellow = "\x1b[93m";
pub const bright_cyan = "\x1b[96m";

// Terminal escape sequences
pub const crlf = "\r\n";
pub const erase_line = "\x1b[2K";
pub const paste_start = "\x1b[200~";
pub const paste_end = "\x1b[201~";
pub const paste_mode_on = "\x1b[?2004h";
pub const paste_mode_off = "\x1b[?2004l";
pub const cursor_down = "\x1b[B";
pub const save_cursor = "\x1b[s";
pub const restore_cursor = "\x1b[u";
pub const cursorUp = "\x1b[A";
pub const reverse_video = "\x1b[7m";
pub const cursor_next_line = "\x1b[1E";
pub const clear_screen = "\x1b[2J";
pub const cursor_home = "\x1b[H";

// Constants
pub const HTTP_HOST = "127.0.0.1";
pub const HTTP_PORT: u16 = 8080;
pub const VERSION = "0.1.0";
pub const DOUBLE_ESC_WINDOW_MS: i64 = 500;
