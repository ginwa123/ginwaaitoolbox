pub const xml = @import("xml.zig");
pub const db_path = @import("db_path.zig");
pub const process = @import("process.zig");
pub const process_status = @import("process_status.zig");
pub const random = @import("random.zig");
pub const dir = @import("dir.zig");
pub const sanitize = @import("sanitize.zig");
pub const image = @import("image.zig");
pub const json_value_to_xml = @import("json_value_to_xml.zig").jsonValueToXml;
pub const xml_escape = @import("xml_escape.zig").xmlEscape;

/// Cross-platform current working directory getter (no `io: std.Io` required).
///
/// `std.posix.getcwd` was removed in Zig 0.16 — the stdlib replacement
/// (`std.Io.Dir.cwd().realPath(io, &buf)`) requires an `Io` runtime,
/// which many tool/handler call sites don't have. This wrapper uses
/// `std.c.getcwd` (libc) which works on Linux, macOS, and Windows
/// (via MinGW/UCRT) without `Io`.
///
/// Returns a slice into `buf` (the caller owns `buf`). Returns null
/// on failure (e.g. cwd has been deleted, or path is too long for `buf`).
pub fn getcwd(buf: []u8) ?[]u8 {
    const result = std.c.getcwd(buf.ptr, buf.len);
    if (result == null) return null;
    // std.c.getcwd writes a NUL-terminated string. Slice up to (but not
    // including) the NUL. If the buffer is somehow full with no NUL,
    // fall back to the full buffer length.
    const p: [*:0]u8 = @ptrCast(result.?);
    const len = std.mem.indexOfScalar(u8, p[0..buf.len], 0) orelse buf.len;
    return p[0..len];
}

const std = @import("std");
