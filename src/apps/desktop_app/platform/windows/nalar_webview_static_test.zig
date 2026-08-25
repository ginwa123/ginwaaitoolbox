// src/apps/desktop_app/platform/windows/nalar_webview_static_test.zig
//
// Static-contract tests for the Windows WebView2 shim (desktop scroll-perf
// plan, Task 4). The .cpp cannot be compiled on Linux — Windows CI is the
// compile authority — so these tests lock the SOURCE-level contract:
//
//   1. CreateCoreWebView2EnvironmentWithOptions receives a real options
//      object (not NULL) so browser args can be passed.
//   2. Additional browser arguments are set on that options object.
//   3. WM_SIZE drag-resize is COALESCED via SetTimer instead of re-setting
//      controller bounds on every message.
//   4. put_DefaultBackgroundColor is applied (dark first paint).

const std = @import("std");
const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const CPP_PATH = "src/apps/desktop_app/platform/windows/nalar_webview.cpp";

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

/// Strip // and /* */ comments (C++ has no @" literals; plain strip).
fn stripComments(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, source);
    var i: usize = 0;
    while (i < out.len) {
        if (i + 1 < out.len and out[i] == '/' and out[i + 1] == '/') {
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
        } else if (i + 1 < out.len and out[i] == '/' and out[i + 1] == '*') {
            while (i < out.len and !(out[i] == '*' and i + 1 < out.len and out[i + 1] == '/')) : (i += 1) out[i] = ' ';
            if (i < out.len) {
                out[i] = ' ';
                i += 1;
                if (i < out.len) out[i] = ' ';
            }
        }
        i += 1;
    }
    return out;
}

fn loadClean(allocator: std.mem.Allocator) ![]u8 {
    const raw = try readSource(allocator, CPP_PATH);
    defer allocator.free(raw);
    return stripComments(allocator, raw);
}

test "environment creation passes a real options object" {
    const allocator = testing.allocator;
    const source = try loadClean(allocator);
    defer allocator.free(source);

    // The old call passed NULL for environmentOptions. The new one must
    // pass an options pointer variable.
    if (std.mem.indexOf(u8, source, "NULL,    // environmentOptions") != null) {
        std.debug.print("!! environmentOptions still NULL in CreateCoreWebView2EnvironmentWithOptions !!\n", .{});
        return error.EnvOptionsStillNull;
    }
    if (std.mem.indexOf(u8, source, "ICoreWebView2EnvironmentOptions") == null) {
        std.debug.print("!! no ICoreWebView2EnvironmentOptions usage in the shim !!\n", .{});
        return error.EnvOptionsTypeMissing;
    }
}

test "additional browser arguments are configured" {
    const allocator = testing.allocator;
    const source = try loadClean(allocator);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "put_AdditionalBrowserArguments") == null) {
        std.debug.print("!! put_AdditionalBrowserArguments never called !!\n", .{});
        return error.BrowserArgsMissing;
    }
}

test "WM_SIZE resize is coalesced with SetTimer" {
    const allocator = testing.allocator;
    const source = try loadClean(allocator);
    defer allocator.free(source);

    inline for (.{
        "WM_TIMER",
        "SetTimer",
        "KillTimer",
    }) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print("!! WM_SIZE coalescing missing {s} !!\n", .{needle});
            return error.ResizeCoalescingMissing;
        }
    }
}

test "default background color is set on the controller" {
    const allocator = testing.allocator;
    const source = try loadClean(allocator);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "put_DefaultBackgroundColor") == null) {
        std.debug.print("!! put_DefaultBackgroundColor never called !!\n", .{});
        return error.DefaultBackgroundMissing;
    }
}
