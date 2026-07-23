const std = @import("std");
const testing = std.testing;

const BUILD_ZIG_PATH = "build.zig";
const CURL_ZIG_PATH = "src/curl.zig";
const CLIENT_ZIG_PATH = "src/client.zig";
const RESPONSE_ZIG_PATH = "src/response.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    return raw;
}

test "build.zig links libcurl" {
    const source = try readSource(testing.allocator, BUILD_ZIG_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "linkSystemLibrary(\"curl\"") == null) {
        std.debug.print("!! build.zig does not link libcurl !!\n", .{});
        return error.LibcurlLinkMissing;
    }
}

test "curl.zig uses @cImport for libcurl" {
    const source = try readSource(testing.allocator, CURL_ZIG_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "@cImport") == null) {
        std.debug.print("!! curl.zig does not @cImport curl/curl.h !!\n", .{});
        return error.CImportMissing;
    }
    if (std.mem.indexOf(u8, source, "@cInclude(\"curl/curl.h\")") == null) {
        std.debug.print("!! curl.zig does not @cInclude curl/curl.h !!\n", .{});
        return error.CIncludeMissing;
    }
}

test "client.zig calls curl_global_init lazily" {
    const source = try readSource(testing.allocator, CLIENT_ZIG_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "curl_global_init") == null) {
        std.debug.print("!! client.zig does not call curl_global_init !!\n", .{});
        return error.GlobalInitMissing;
    }
}

test "client.zig: curl_easy_cleanup always paired with curl_easy_init (no FD leak class)" {
    const source = try readSource(testing.allocator, CLIENT_ZIG_PATH);
    defer testing.allocator.free(source);

    // Count actual CALL sites. The substring "curl_easy_init" appears in
    // doc comments too — we look for the call shape "easy_init(" to avoid
    // comment/doc-string false positives. Same for cleanup.
    var opens: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, source, idx, "easy_init(")) |pos| {
        opens += 1;
        idx = pos + 1;
    }
    idx = 0;
    var closes: usize = 0;
    while (std.mem.indexOfPos(u8, source, idx, "easy_cleanup(")) |pos| {
        closes += 1;
        idx = pos + 1;
    }
    if (opens != closes) {
        std.debug.print("!! client.zig: {d} easy_init calls but {d} easy_cleanup calls — FD-leak class !!\n", .{ opens, closes });
        return error.CleanupMissing;
    }
    if (opens == 0) {
        std.debug.print("!! client.zig: no easy_init call found !!\n", .{});
        return error.InitMissing;
    }
}

test "response.zig: deinit frees EVERY owned field listed in struct" {
    const source = try readSource(testing.allocator, RESPONSE_ZIG_PATH);
    defer testing.allocator.free(source);

    const checks = .{
        .{ "body", "allocator.free(self.body)" },
        .{ "url_effective", "allocator.free(self.url_effective)" },
        .{ "primary_ip", "allocator.free(self.primary_ip)" },
        .{ "headers loop", "for (self.headers)" },
    };
    inline for (checks) |c| {
        if (std.mem.indexOf(u8, source, c[1]) == null) {
            std.debug.print("!! response.zig: missing `{s}` deinit call !!\n", .{c[1]});
            return error.DeinitIncomplete;
        }
    }
}

test "response.zig: headers loop frees both name and value" {
    const source = try readSource(testing.allocator, RESPONSE_ZIG_PATH);
    defer testing.allocator.free(source);

    const loop_start = std.mem.indexOf(u8, source, "for (self.headers) |h|") orelse return error.HeadersLoopMissing;
    const loop_end = std.mem.indexOfPos(u8, source, loop_start + 1, "}") orelse source.len;
    const body_slice = source[loop_start..loop_end];

    if (std.mem.indexOf(u8, body_slice, "allocator.free(h.name)") == null) {
        std.debug.print("!! response.zig: headers loop does not free h.name !!\n", .{});
        return error.HeaderNameNotFreed;
    }
    if (std.mem.indexOf(u8, body_slice, "allocator.free(h.value)") == null) {
        std.debug.print("!! response.zig: headers loop does not free h.value !!\n", .{});
        return error.HeaderValueNotFreed;
    }
}
