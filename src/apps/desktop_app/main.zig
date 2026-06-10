// src/apps/desktop_app/main.zig
//
// Chunk 1 entry point. The full lifecycle (CLI → resolve nalar → spawn →
// healthcheck → webview → kill on close) lands in Chunk 8. This Chunk 1
// version wires up CLI parsing just enough to make `--help` work — the
// hello-world is the placeholder output for when parsing succeeds.

const std = @import("std");
const cli = @import("cli.zig");

// Pull in the test files so they run under `zig build test:desktop-app`.
// `test { ... }` blocks are evaluated by the test runner only — the
// test_runner.zig module is imported only in test builds. See test_runner.zig
// for the cascade of @imports that wires up the actual test files.
test {
    _ = @import("test_runner.zig");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Zig 0.16: init.minimal.args is a `process.Args` (an iterator), not a
    // slice. Our cli.parse() takes a slice, so we materialize the iterator
    // into an ArrayList first. The first item from the iterator is argv[0]
    // (the binary name), which cli.parse() expects and skips.
    var args_buf: std.ArrayList([]const u8) = .empty;
    defer args_buf.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    defer args_iter.deinit();
    while (args_iter.next()) |arg| {
        try args_buf.append(allocator, arg);
    }

    var cfg = cli.parse(allocator, args_buf.items) catch |err| switch (err) {
        // cli.parse() has already printed the usage to stderr — exit cleanly.
        error.ShowHelp => return,
        // All other errors: cli.parse() has already printed a message to
        // stderr. Return the error so the process exits non-zero.
        else => {
            std.log.err("Failed to parse CLI args: {s}", .{@errorName(err)});
            return err;
        },
    };
    defer cfg.deinit(allocator);

    std.debug.print("nalar-desktop: hello (not yet implemented)\n", .{});
}
