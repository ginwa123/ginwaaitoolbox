//! Build for the PRIBRIK functional test package (`tests/functional/`).
//!
//! WHY THIS IS A SEPARATE PACKAGE (and not a `b.addTest` on the root
//! `pabrikcore` module):
//!
//! The functional suite is a BLACK-BOX suite. Every test boots a real
//! `pabrik` binary and drives it over HTTP; nothing in it should be
//! able to `@import` a `src/` internal. If this package depended on
//! the app module, a test could accidentally bind to an internal type
//! and then "pass" without ever crossing the wire — which is exactly
//! the class of test the functional suite exists to rule out.
//!
//! So this package declares NO dependency on `pabrikcore`. Its only
//! import is `std`, which gives us:
//!   - `std.http.Client` for the HTTP calls the tests make
//!   - `std.process.spawn` for booting the `pabrik` binary
//!   - `std.json` for JSON bodies
//!   - `std.testing` for the test allocator + Io
//!
//! `pabrik` itself is NOT a link-time dependency either — the harness
//! spawns it as a child process, exactly like the Python harness did.
//!
//! Run with:
//!     zig build test --summary all     # from tests/functional/
//!
//! or from the repo root via the `functional-test` step, which builds
//! and installs the `pabrik` binary first.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_mod = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The suite boots the `pabrik` binary, which lives at the REPO
    // root's `zig-out/bin/`. This package's own dir is two levels below
    // it, so the harness probes upward — see `harness.zig`'s
    // `resolvePabrikBin` for the full candidate list.
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.setCwd(b.path("../.."));

    const test_step = b.step("test", "Run the PRIBRIK functional test suite");
    test_step.dependOn(&run_unit_tests.step);
}
