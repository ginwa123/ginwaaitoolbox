const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

pub const Mode = union(enum) {
    none,
    last: u8, // 1..=50, clamped
    all,
    since_last_user,
};

/// Cap for the `last:N` selector and for the 50-message ceiling used by `all`
/// and `since_last_user`. Lifting to a constant so tests and formatter agree.
pub const MAX_MESSAGES: u8 = 50;
pub const DEFAULT_LAST: u8 = 10;
pub const MAX_SECTION_BYTES: usize = 20 * 1024; // 20 KB

pub const ParseError = error{InvalidInheritedContextMode};

pub fn parseMode(raw: []const u8) ParseError!Mode {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) return .all;
    if (std.ascii.eqlIgnoreCase(trimmed, "since_last_user")) return .since_last_user;

    if (std.ascii.startsWithIgnoreCase(trimmed, "last:")) {
        const n_str = trimmed["last:".len..];
        if (n_str.len == 0) return Mode{ .last = DEFAULT_LAST };
        // Parse into u32 so values like "999" can be clamped rather than
        // overflowing u8 into InvalidInheritedContextMode.
        const n = std.fmt.parseInt(u32, n_str, 10) catch return error.InvalidInheritedContextMode;
        if (n == 0) return Mode{ .last = 1 };
        if (n > MAX_MESSAGES) return Mode{ .last = MAX_MESSAGES };
        return Mode{ .last = @intCast(n) };
    }

    return error.InvalidInheritedContextMode;
}
