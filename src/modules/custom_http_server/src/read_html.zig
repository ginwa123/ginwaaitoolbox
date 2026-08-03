// =============================================================================
//  readHtml — read an HTML template file with an embedded-source fallback
// =============================================================================
//
// This is the canonical pattern for self-contained HTML handlers in
// gserverz: ship the HTML file as a real on-disk asset (so users can edit
// and reload without rebuilding), but bundle a compile-time copy of the
// same source via `@embedFile` so the binary still works when the working
// directory differs from the build root (typical for deployed binaries or
// `zig build test` runs from a different cwd).
//
// Why is the embedded source passed in by the caller instead of being
// embedded inside `readHtml` itself?
//
//   1. Zig 0.16 forbids `@embedFile` of a runtime string — the path must
//      be a string literal at compile time, so the helper cannot decide
//      itself.
//   2. `@embedFile` resolves relative to the SOURCE FILE where it's called.
//      Since `readHtml` lives in `src/modules/custom_http_server/src/`,
//      embedding here would require a path relative to that directory
//      (e.g. `"../../../handlers/landing.html"`) — fragile and coupled to
//      the helper's location in the file tree.
//
// Letting each caller pass the already-embedded source keeps `readHtml`
// location-independent and lets the caller embed at its own site (where
// the relative path is naturally meaningful).
//
// The helper also parses the source into a Template AST so the caller
// gets a single `[]Node` value ready to render. Errors are propagated
// upward; the caller wraps them with `gserverz.response.internalError`
// (or similar) at the handler boundary.
// =============================================================================

const std = @import("std");
const Template = @import("template.zig");

/// Read an HTML template file at runtime, falling back to a compile-time
/// embedded copy on `error.FileNotFound`, then parse the source into a
/// `Template.Node` AST.
///
/// Parameters:
///   - `allocator`: arena-backed (typically the per-request arena). The
///     returned AST is allocated here; free it with `Template.freeNodes`
///     when the handler returns (the arena reaps it on completion).
///   - `io`: the Zig 0.16 `std.Io` runtime. Tests pass `std.testing.io`;
///     production code passes the runtime `io` from `std.process.Init.io`.
///   - `path`: filesystem path relative to the process cwd at runtime.
///     Used as the read target; on `FileNotFound`, the function falls
///     back to `embedded_fallback`.
///   - `embedded_fallback`: the compile-time embedded source — typically
///     the result of `@embedFile(...)` at the caller's site. The caller
///     must call `@embedFile` themselves because the path must be a
///     literal at compile time (see file header for rationale).
///
/// Returns:
///   - On success: `[]const Template.Node` — the parsed AST. Caller is
///     responsible for freeing via `Template.freeNodes`.
///   - On `error.FileNotFound`: read of `path` failed; falls back to
///     `embedded_fallback` and parses that instead.
///   - On other read errors (e.g. permission denied, mount missing): the
///     error propagates upward. The caller is responsible for wrapping
///     it in an HTTP response (e.g. `internalError`).
///   - On parse errors (e.g. malformed Jinja syntax): the `Template.Error`
///     union propagates upward. Same wrapping convention.
///
/// Example (handler):
/// ```zig
/// const LANDING_JINJA_PATH = "src/handlers/landing.html";
/// const LANDING_JINJA_SOURCE: []const u8 = @embedFile("landing.html");
///
/// const nodes = gserverz.readHtml(
///     ctx.allocator,
///     ctx.io,
///     LANDING_JINJA_PATH,
///     LANDING_JINJA_SOURCE,
/// ) catch |err| {
///     return gserverz.response.internalError(@errorName(err), ctx.allocator);
/// };
/// defer gserverz.Template.freeNodes(ctx.allocator, nodes);
/// ```
pub fn readHtml(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    embedded_fallback: []const u8,
) ![]Template.Node {
    // Try to read the on-disk file. On `FileNotFound` (typical when the
    // process cwd differs from the build root, e.g. deployed binaries or
    // `zig build test` runs from a different directory), use the embedded
    // source as the fallback. Other errors (permission denied, mount
    // missing, etc.) propagate up to the caller for HTTP error wrapping.
    //
    // Cap at 1 MiB — larger templates are extremely rare and a runaway
    // file shouldn't OOM the process. If you need more, pre-process the
    // template to split it, or bump the cap and audit the source files.
    const source = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1 << 20),
    ) catch |err| switch (err) {
        error.FileNotFound => embedded_fallback,
        else => return err,
    };

    return Template.parseSource(allocator, source);
}
