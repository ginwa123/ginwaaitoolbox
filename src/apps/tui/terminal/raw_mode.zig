const std = @import("std");
const builtin = @import("builtin");

/// Enable raw mode for terminal input
/// Returns the original termios settings to be restored later
pub fn enableRawMode() !std.posix.termios {
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

/// Disable raw mode and restore original terminal settings
pub fn disableRawMode(original: std.posix.termios) void {
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, original) catch {};
}

/// Check if bytes are available on stdin
pub fn stdinBytesAvailable() c_int {
    if (builtin.os.tag == .windows) {
        return 0;
    } else {
        var bytes_available: c_int = 0;
        const result = std.posix.system.ioctl(std.posix.STDIN_FILENO, std.posix.system.T.FIONREAD, @intFromPtr(&bytes_available));
        return if (result == 0) bytes_available else 0;
    }
}
