// src/apps/desktop_app/cli_test.zig
//
// Tests for the CLI parser. Each test builds a small `args` array, calls
// `cli.parse`, and asserts on the returned Config. Memory: the test allocator
// is `std.testing.allocator` which is a GeneralPurposeAllocator with leak
// detection enabled in Debug mode — leaks will fail the test.
//
// The `&args` form is a Zig 0.16 idiom: a `*const [N][]const u8` is
// implicitly coerced to `[]const []const u8` when passed to a function with
// that parameter type. Both work the same way they did in Zig 0.15.

const std = @import("std");
const cli = @import("cli.zig");
const testing = std.testing;

test "parseArgs: defaults" {
    const allocator = testing.allocator;
    const args = [_][]const u8{"nalar-desktop"};
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expectEqual(@as(u16, 0), cfg.port); // 0 = auto-pick
    try testing.expect(cfg.nalar_path == null);
    try testing.expect(cfg.nalar_url == null);
    try testing.expectEqual(@as(u32, 1280), cfg.window_width);
    try testing.expectEqual(@as(u32, 800), cfg.window_height);
    try testing.expectEqualStrings("Nalar", cfg.title);
    try testing.expect(!cfg.smoke_test);
    try testing.expect(!cfg.enable_devtools);
}

test "parseArgs: --port" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--port", "9999" };
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expectEqual(@as(u16, 9999), cfg.port);
}

test "parseArgs: --nalar-path" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--nalar-path", "/tmp/nalar" };
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.nalar_path != null);
    try testing.expectEqualStrings("/tmp/nalar", cfg.nalar_path.?);
}

test "parseArgs: --nalar-url switches to connect mode" {
    const allocator = testing.allocator;
    const args = [_][]const u8{
        "nalar-desktop",
        "--nalar-url",
        "http://127.0.0.1:8081",
    };
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.nalar_url != null);
    try testing.expectEqualStrings("http://127.0.0.1:8081", cfg.nalar_url.?);
    // --port and --nalar-path are ignored in connect mode but still parseable.
    // We just verify they default to null/0 here (the caller is responsible
    // for honoring cfg.nalar_url and ignoring the other fields).
    try testing.expectEqual(@as(u16, 0), cfg.port);
    try testing.expect(cfg.nalar_path == null);
}

test "parseArgs: --window-size 1024x768" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--window-size", "1024x768" };
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expectEqual(@as(u32, 1024), cfg.window_width);
    try testing.expectEqual(@as(u32, 768), cfg.window_height);
}

test "parseArgs: --title" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--title", "My Nalar" };
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expectEqualStrings("My Nalar", cfg.title);
}

test "parseArgs: --smoke-test" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--smoke-test" };
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.smoke_test);
}

test "parseArgs: --devtools enables webview DevTools" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--devtools" };
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.enable_devtools);
}

test "parseArgs: --x11 forces X11 backend opt-in" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--x11" };
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.force_x11);
}

test "parseArgs: --x11 defaults to false" {
    const allocator = testing.allocator;
    const args = [_][]const u8{"nalar-desktop"};
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(!cfg.force_x11);
}

test "parseArgs: --help prints usage and signals help" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--help" };
    const result = cli.parse(allocator, &args);
    try testing.expectError(error.ShowHelp, result);
}

test "parseArgs: invalid port returns InvalidPort" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--port", "abc" };
    const result = cli.parse(allocator, &args);
    try testing.expectError(error.InvalidPort, result);
}

test "parseArgs: --window-size without x returns InvalidSize" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--window-size", "1024" };
    const result = cli.parse(allocator, &args);
    try testing.expectError(error.InvalidSize, result);
}

// ---------------------------------------------------------------------------
// --browser (browser-window mode): the flag the in-app browser tab spawns.
// ---------------------------------------------------------------------------

test "parseArgs: --browser takes an http(s) URL" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--browser", "https://example.com/a?b=1" };
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.browser_url != null);
    try testing.expectEqualStrings("https://example.com/a?b=1", cfg.browser_url.?);
    // Browser mode is independent of the attach flags.
    try testing.expect(cfg.nalar_url == null);
    try testing.expectEqual(@as(u16, 0), cfg.port);
}

test "parseArgs: --browser with no value returns MissingValue" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "nalar-desktop", "--browser" };
    const result = cli.parse(allocator, &args);
    try testing.expectError(error.MissingValue, result);
}

test "parseArgs: --browser rejects every non-http scheme" {
    const allocator = testing.allocator;
    const rejected = [_][]const u8{
        "javascript:alert(1)",
        "file:///etc/passwd",
        "data:text/html,<h1>x</h1>",
        "about:blank",
        "ftp://example.com",
        // Not absolute — a bare host is resolved in the address bar, never here.
        "example.com",
        "",
    };
    for (rejected) |url| {
        const args = [_][]const u8{ "nalar-desktop", "--browser", url };
        const result = cli.parse(allocator, &args);
        try testing.expectError(error.InvalidBrowserUrl, result);
    }
}

test "parseArgs: --browser defaults to null" {
    const allocator = testing.allocator;
    const args = [_][]const u8{"nalar-desktop"};
    const cfg = try cli.parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.browser_url == null);
}

test "isHttpUrl accepts only absolute http(s)" {
    try testing.expect(cli.isHttpUrl("http://127.0.0.1:5173/"));
    try testing.expect(cli.isHttpUrl("https://github.com/foo/bar"));
    try testing.expect(cli.isHttpUrl("HTTPS://EXAMPLE.COM"));
    try testing.expect(!cli.isHttpUrl("http://")); // no host
    try testing.expect(!cli.isHttpUrl("example.com"));
    try testing.expect(!cli.isHttpUrl("javascript:alert(1)"));
    try testing.expect(!cli.isHttpUrl(""));
}

test "hostOf strips the scheme and the path" {
    const allocator = testing.allocator;
    const host = try cli.hostOf(allocator, "https://github.com/foo/bar?x=1");
    defer allocator.free(host);
    try testing.expectEqualStrings("github.com", host);

    const with_port = try cli.hostOf(allocator, "http://localhost:5173/app");
    defer allocator.free(with_port);
    try testing.expectEqualStrings("localhost:5173", with_port);

    const bare = try cli.hostOf(allocator, "https://example.com");
    defer allocator.free(bare);
    try testing.expectEqualStrings("example.com", bare);
}
