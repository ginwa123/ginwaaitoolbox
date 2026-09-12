const std = @import("std");

/// `helpers` package — the project-wide portable sleep / time /
/// file-existence helpers (`PosixTimespec`, `sleepMillis`,
/// `unixTimestamp`, `nanosleep`, `clock_gettime`, etc.).
///
/// This package exists so multiple `modules/*/build.zig` files
/// (kabelweb, databases, …) can `@import("helpers")` and
/// share the SAME module instance — promoting helpers to its own
/// Zig package (with `build.zig` + `build.zig.zon`) gives it a
/// single owner and lets consumers declare the dependency through
/// `b.dependency("helpers", ...)` like every other in-tree
/// package.
///
/// Module shape mirrors the previous inline `pub const helpers = `
/// re-exports in `src/root.zig`:
///   - `sleepMillis`, `unixTimestamp`, `unixTimestampNanos`,
///     `monotonicTimestampNanos`, `readFile`, `fileExists`,
///     `PosixTimespec`, `nanosleep`, `clock_gettime`,
///     `CLOCK_REALTIME`, `CLOCK_MONOTONIC`.
/// Plus the per-file re-exports (`xml`, `db_path`, `process`,
/// `random`, `dir`, `sanitize`, `image`, `json_value_to_xml`,
/// `xml_escape`, `text_normalize`, `xmlUnescape`).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("helpers", .{
        .root_source_file = b.path("mod.zig"),
        .target = target,
        .optimize = optimize,
    });
}
