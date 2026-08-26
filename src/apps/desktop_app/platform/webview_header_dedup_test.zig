// src/apps/desktop_app/platform/webview_header_dedup_test.zig
//
// Static-contract test: the legacy webview C ABI header must exist in
// exactly ONE place (shared/webview_c.h). The per-platform copies
// were a sync hazard — adding a field to nalar_webview_config
// required editing 3 files in lockstep, and nothing failed loudly if
// you missed one.
//
// After the webview-lib swap (PR #354) the macOS + Windows shims
// (platform/macos/nalar_webview.mm, platform/windows/nalar_webview.cpp)
// were deleted — they implemented the old nalar_webview_* C ABI that
// main.zig no longer calls. The dev-box fallback STUB shim remains
// (Windows-only, used when MSVC + WebView2 NuGet are unavailable) and
// still includes the shared header for parity.
//
// Contract:
//   1. Exactly one webview_c.h exists under src/apps/desktop_app.
//   2. The windows stub shim includes it via the relative shared path.

const std = @import("std");
const testing = std.testing;

const APP_DIR = "src/apps/desktop_app";

test "exactly one webview_c.h exists under desktop_app" {
    var count: usize = 0;
    var found_shared = false;

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, APP_DIR, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();

    while (try walker.next(testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.basename, "webview_c.h")) {
            count += 1;
            if (std.mem.indexOf(u8, entry.path, "shared") != null) found_shared = true;
        }
    }

    if (count != 1) {
        std.debug.print("!! expected exactly 1 webview_c.h, found {d} — per-platform copies are a sync hazard !!\n", .{count});
        return error.DuplicateHeaderCopies;
    }
    if (!found_shared) {
        std.debug.print("!! the single webview_c.h must live under shared/ !!\n", .{});
        return error.HeaderNotInShared;
    }
}

fn assertIncludesSharedPath(source: []const u8, label: []const u8) !void {
    // The include resolves via `-I src/apps/desktop_app` on the shim
    // compile (see build.zig) — quoted form, path relative to that root.
    if (std.mem.indexOf(u8, source, "#include \"shared/webview_c.h\"") == null and
        std.mem.indexOf(u8, source, "#import \"shared/webview_c.h\"") == null)
    {
        std.debug.print("!! {s} does not include shared/webview_c.h !!\n", .{label});
        return error.IncludePathMissing;
    }
    // And no local-quote include of the bare name or the old ../shared
    // form (both would break or shadow the single-copy contract).
    inline for (.{
        "#include \"webview_c.h\"",
        "#import \"webview_c.h\"",
        "#include \"../shared/webview_c.h\"",
        "#import \"../shared/webview_c.h\"",
    }) |bad| {
        if (std.mem.indexOf(u8, source, bad) != null) {
            std.debug.print("!! {s} still uses outdated include form: {s} !!\n", .{ label, bad });
            return error.BareIncludeRemains;
        }
    }
}

test "windows stub shim includes the shared header via relative path" {
    const allocator = testing.allocator;
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        APP_DIR ++ "/platform/windows/nalar_webview_stub.cpp",
        allocator,
        .limited(256 * 1024),
    );
    defer allocator.free(raw);
    try assertIncludesSharedPath(raw, "nalar_webview_stub.cpp");
}
