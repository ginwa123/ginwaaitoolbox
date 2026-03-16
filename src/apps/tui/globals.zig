const std = @import("std");
const builtin = @import("builtin");
const tui_text = @import("tui-text");

// Re-export text module colors for backward compatibility
pub const reset = tui_text.ansi.reset;
pub const bold = tui_text.ansi.bold;
pub const dim = tui_text.ansi.dim;
pub const cyan = tui_text.ansi.cyan;
pub const yellow = tui_text.ansi.yellow;
pub const green = tui_text.ansi.green;

// Re-export terminal escape sequences
pub const crlf = tui_text.ansi.crlf;
pub const erase_line = tui_text.ansi.erase_line;
pub const paste_start = tui_text.ansi.paste_start;
pub const paste_end = tui_text.ansi.paste_end;
pub const paste_mode_on = tui_text.ansi.paste_mode_on;
pub const paste_mode_off = tui_text.ansi.paste_mode_off;
pub const cursor_down = tui_text.ansi.cursor_down;
pub const save_cursor = tui_text.ansi.save_cursor;
pub const cursorUp = tui_text.ansi.cursorUp;
pub const reverse_video = tui_text.ansi.reverse_video;
pub const cursor_next_line = tui_text.ansi.cursor_next_line;
pub const red = tui_text.ansi.red;
pub const green_fg = tui_text.ansi.green;

// Constants
pub const HTTP_HOST = "127.0.0.1";
pub const HTTP_PORT: u16 = 8080;
pub const VERSION = "0.1.0";
pub const DOUBLE_ESC_WINDOW_MS: i64 = 500;
