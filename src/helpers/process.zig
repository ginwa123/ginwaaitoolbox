//! Process-related helper functions

const std = @import("std");

/// Hex digits for ID generation
pub const hex_digits = "0123456789abcdef";

/// Cross-platform process ID getter
/// Returns the current process ID in a cross-platform compatible way
pub fn getCurrentProcessId() std.c.pid_t {
    if (@hasDecl(std.c, "getpid")) {
        return std.c.getpid();
    } else if (@hasDecl(std.os.windows, "GetCurrentProcessId")) {
        return @intCast(std.os.windows.GetCurrentProcessId());
    }
    // Fallback: should never reach here
    @compileError("getpid not available on this platform");
}
