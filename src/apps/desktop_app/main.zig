// src/apps/desktop_app/main.zig
//
// Chunk 1 hello-world. The real entry point lands in Chunk 8 (lifecycle wiring:
// parse CLI → resolve nalar → spawn nalar → wait for health → open webview → kill
// on close). For now this is just a smoke test that the build wiring is correct.

const std = @import("std");

// Pull in the test files so they run under `zig build test:desktop-app`.
// `test { ... }` blocks are evaluated by the test runner only — the
// test_runner.zig module is imported only in test builds. See test_runner.zig
// for the cascade of @imports that wires up the actual test files.
test {
    _ = @import("test_runner.zig");
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("nalar-desktop: hello (not yet implemented)\n", .{});
}
