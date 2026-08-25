// src/apps/desktop_app/platform/macos/nalar_webview_static_test.zig
//
// Static-contract tests for the macOS WKWebView shim (desktop scroll-perf
// plan, Task 3). The .mm cannot be compiled on Linux — CI's macos-arm
// runner is the compile authority — so these tests lock the SOURCE-level
// contract that the perf fixes are present:
//
//   1. A real WKURLSchemeHandler subclass serves app:// (parallel asset
//      loads) instead of nav-delegate interception.
//   2. The handler resolves assets via NSDictionary, not a strcmp loop.
//   3. enable_developer_extras is consumed (developerExtrasEnabled KVC).
//   4. user_agent is consumed (applicationNameForUserAgent).
//   5. drawsBackground = NO kills the white first-paint flash.
//
// ObjC parsing gotcha (PR #300): strip @"..." string literals BEFORE
// stripping comments, or literals containing // break the parse.

const std = @import("std");
const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const MM_PATH = "src/apps/desktop_app/platform/macos/nalar_webview.mm";

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

/// Neutralize `@"..."` literal DELIMITERS so later comment-stripping
/// doesn't trip on slashes inside strings — but KEEP the literal's text
/// content, because the contract needles themselves (e.g.
/// forKey:@"drawsBackground") live inside ObjC literals. Only the quote
/// characters are blanked; escaped quotes (\") are handled.
fn stripObjcStrings(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, source);
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == '@' and i + 1 < out.len and out[i + 1] == '"') {
            out[i] = ' ';
            i += 2;
            // blank the opening quote of the literal body
            if (i > 0) out[i - 1] = ' ';
            while (i < out.len and out[i] != '"') : (i += 1) {
                if (out[i] == '\\' and i + 1 < out.len) {
                    i += 1; // skip escaped char (keep it — harmless)
                }
            }
            if (i < out.len) out[i] = ' '; // closing quote
        }
        i += 1;
    }
    return out;
}

/// Strip // line comments and /* */ block comments (after strings are gone).
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
    const raw = try readSource(allocator, MM_PATH);
    defer allocator.free(raw);
    const no_strings = try stripObjcStrings(allocator, raw);
    defer allocator.free(no_strings);
    return stripComments(allocator, no_strings);
}

test "WKURLSchemeHandler subclass exists with start/stop task methods" {
    const allocator = testing.allocator;
    const source = try loadClean(allocator);
    defer allocator.free(source);

    inline for (.{
        "WKURLSchemeHandler",
        "startURLSchemeTask",
        "stopURLSchemeTask",
    }) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print("!! nalar_webview.mm missing {s} !!\n", .{needle});
            return error.SchemeHandlerMissing;
        }
    }
}

test "app scheme registered via setURLSchemeHandler on the config" {
    const allocator = testing.allocator;
    const source = try loadClean(allocator);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "setURLSchemeHandler") == null) {
        std.debug.print("!! wkconfig never registers a URL scheme handler !!\n", .{});
        return error.SchemeRegistrationMissing;
    }
}

test "nav-delegate no longer intercepts app:// with a strcmp asset scan" {
    const allocator = testing.allocator;
    const source = try loadClean(allocator);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "strcmp(asset->path") != null) {
        std.debug.print("!! linear strcmp(asset->path...) scan still present !!\n", .{});
        return error.LinearScanRemains;
    }
}

test "asset lookup uses an NSDictionary index" {
    const allocator = testing.allocator;
    const source = try loadClean(allocator);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "NSDictionary") == null) {
        std.debug.print("!! no NSDictionary asset index in the shim !!\n", .{});
        return error.AssetIndexMissing;
    }
}

test "enable_developer_extras is consumed via developerExtrasEnabled" {
    const allocator = testing.allocator;
    const source = try loadClean(allocator);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "developerExtrasEnabled") == null) {
        std.debug.print("!! developerExtrasEnabled never wired from _config !!\n", .{});
        return error.DevtoolsWiringMissing;
    }
}

test "user_agent is consumed via applicationNameForUserAgent" {
    const allocator = testing.allocator;
    const source = try loadClean(allocator);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "applicationNameForUserAgent") == null) {
        std.debug.print("!! applicationNameForUserAgent never wired from _config !!\n", .{});
        return error.UserAgentWiringMissing;
    }
}

test "drawsBackground disabled to kill white first-paint flash" {
    const allocator = testing.allocator;
    const source = try loadClean(allocator);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "drawsBackground") == null) {
        std.debug.print("!! drawsBackground never configured !!\n", .{});
        return error.DrawsBackgroundMissing;
    }
}
