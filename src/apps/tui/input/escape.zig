const std = @import("std");
const raw_mode = @import("../terminal/raw_mode.zig");

/// Read escape sequence from stdin
pub fn readEscapeSequence(buf: *[16]u8) !usize {
    buf[0] = 0x1b;
    var i: usize = 1;
    while (i < buf.len) {
        var b: [1]u8 = undefined;
        const bytes_available = raw_mode.stdinBytesAvailable();
        if (bytes_available == 0) break;
        const n = std.posix.read(std.posix.STDIN_FILENO, &b) catch break;
        if (n == 0) break;
        buf[i] = b[0];
        i += 1;
        if (b[0] == '~') break;
    }
    return i;
}
