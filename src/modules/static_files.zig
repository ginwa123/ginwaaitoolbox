// src/modules/static_files.zig
const std = @import("std");

/// Configuration for the static-file handler. Constructed once at startup,
/// passed by pointer to every request handler invocation.
pub const StaticDirConfig = struct {
    /// Absolute, canonicalized path to the directory whose contents should be served.
    root_dir: []const u8,
    allocator: std.mem.Allocator,
};

/// Result of a static-file lookup. The handler converts this into an HTTP response.
pub const LookupResult = union(enum) {
    file: struct {
        abs_path: []const u8,
        mime: []const u8,
        size: u64,
    },
    not_found,
    forbidden,
    not_a_file,
};

/// Resolve a request path (e.g. "/assets/index-abc.js") against the static dir.
/// Returns the resolved file's absolute path, mime type, and size — or an error
/// describing why the request can't be served.
///
/// This is the pure function used by tests; the actual HTTP handler is a thin
/// wrapper that calls this and writes the response.
pub fn resolve(
    cfg: *const StaticDirConfig,
    request_path: []const u8,
) !LookupResult {
    _ = cfg;
    _ = request_path;
    return .not_found; // TODO: real impl
}

/// Send a static file as an HTTP response.
///
/// Doesn't mutate `cfg` — all writes go to the `writer` parameter. Task 3
/// will likely swap `writer` for the real httpz response type; this signature
/// is the placeholder shape we expect.
/// (Stub for now; fleshed out in Task 3.)
pub fn serve(
    cfg: *const StaticDirConfig,
    request_path: []const u8,
    range_header: ?[]const u8,
    writer: std.Io.Writer,
) !LookupResult {
    _ = cfg;
    _ = request_path;
    _ = range_header;
    _ = writer;
    return .not_found;
}
