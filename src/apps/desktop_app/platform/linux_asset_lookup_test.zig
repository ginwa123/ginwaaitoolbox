// src/apps/desktop_app/platform/linux_asset_lookup_test.zig
//
// Static-contract tests for the app:// asset lookup (desktop scroll-perf
// plan, Task 2). The scheme callback runs on the GTK main thread for
// every asset request; the original linear scan over the embedded asset
// table is O(n) per request. This locks in the O(1) StringHashMap
// contract:
//
//   1. SchemeContext carries a hash map (path -> index).
//   2. The map is BUILT once during nalar_webview_create.
//   3. uriSchemeCallback resolves via map get — no linear for-loop over
//      ctx.assets remains on the request path.

const std = @import("std");
const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const LINUX_PATH = "src/apps/desktop_app/platform/linux.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "SchemeContext declares a StringHashMapUnmanaged asset index" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LINUX_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "StringHashMapUnmanaged") == null) {
        std.debug.print("!! SchemeContext missing StringHashMapUnmanaged asset index !!\n", .{});
        return error.AssetIndexMissing;
    }
}

test "asset index is built once in nalar_webview_create" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LINUX_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "buildAssetIndex") == null) {
        std.debug.print("!! nalar_webview_create never builds the asset index !!\n", .{});
        return error.AssetIndexBuildMissing;
    }
}

test "uriSchemeCallback no longer linear-scans the asset table" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LINUX_PATH);
    defer allocator.free(source);

    // Extract the uriSchemeCallback function body window and assert the
    // old `for (ctx.assets[0..ctx.count])` loop is gone from it.
    const fn_start = std.mem.indexOf(u8, source, "fn uriSchemeCallback") orelse {
        std.debug.print("!! uriSchemeCallback vanished !!\n", .{});
        return error.CallbackMissing;
    };
    const body = source[fn_start..];
    if (std.mem.indexOf(u8, body, "for (ctx.assets[0..ctx.count])") != null) {
        std.debug.print("!! uriSchemeCallback still linear-scans ctx.assets !!\n", .{});
        return error.LinearScanRemains;
    }
    // And resolves through the map instead.
    if (std.mem.indexOf(u8, body, ".get(path)") == null) {
        std.debug.print("!! uriSchemeCallback does not resolve via asset_index.get !!\n", .{});
        return error.MapLookupMissing;
    }
}
