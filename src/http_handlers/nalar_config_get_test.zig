const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const RESP_PATH = "src/http_handlers/http_response.zig";
const GET_PATH = "src/http_handlers/nalar_config_get.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

test "GET /api/config/nalar response includes retry_delay_ms" {
    const allocator = testing.allocator;

    // 1) NalarConfigResponse declares retry_delay_ms: u32 = 0
    const response_src = try readSource(allocator, RESP_PATH);
    defer allocator.free(response_src);
    if (std.mem.indexOf(u8, response_src, "retry_delay_ms: u32 = 0") == null) {
        std.debug.print("!! NalarConfigResponse missing retry_delay_ms !!\n", .{});
        return error.RetryDelayMissingFromResponse;
    }

    // 2) ConfigJson declares retry_delay_ms: u32 = 0 (so the parsed
    //    JSON gets the field).
    const get_src = try readSource(allocator, GET_PATH);
    defer allocator.free(get_src);
    if (std.mem.indexOf(u8, get_src, "retry_delay_ms: u32 = 0") == null) {
        std.debug.print("!! nalar_config_get.zig ConfigJson missing retry_delay_ms field !!\n", .{});
        return error.RetryDelayMissingFromConfigJson;
    }

    // 3) The GET handler pipes cfg.retry_delay_ms into the response
    //    (i.e. the makeNalarConfigResponse call references the new
    //    field sourced from cfg).
    if (std.mem.indexOf(u8, get_src, ".retry_delay_ms = cfg.retry_delay_ms") == null) {
        std.debug.print("!! nalar_config_get.zig does not pipe retry_delay_ms !!\n", .{});
        return error.RetryDelayNotWiredIntoGet;
    }
}

test "GET /api/config/nalar response includes notify_on_error (task_1787671269086_0)" {
    // Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the
    // error-notification toggle is a NEW field added to the wire
    // shape. Like `notify_on_complete`, it must appear in BOTH
    // `NalarConfigResponse` (response shape) AND `ConfigJson` (parse
    // shape) AND the GET handler must pipe `cfg.notify_on_error`
    // into the response. Lock all three sites so a future refactor
    // that drops one of them surfaces immediately at `zig build test`.
    const allocator = testing.allocator;

    // 1) NalarConfigResponse declares notify_on_error: bool = false.
    const response_src = try readSource(allocator, RESP_PATH);
    defer allocator.free(response_src);
    if (std.mem.indexOf(u8, response_src, "notify_on_error: bool = false") == null) {
        std.debug.print("!! NalarConfigResponse missing notify_on_error !!\n", .{});
        return error.NotifyOnErrorMissingFromResponse;
    }

    // 2) ConfigJson declares notify_on_error: bool = false (so the
    //    parsed JSON gets the field).
    const get_src = try readSource(allocator, GET_PATH);
    defer allocator.free(get_src);
    if (std.mem.indexOf(u8, get_src, "notify_on_error: bool = false") == null) {
        std.debug.print("!! nalar_config_get.zig ConfigJson missing notify_on_error field !!\n", .{});
        return error.NotifyOnErrorMissingFromConfigJson;
    }

    // 3) The GET handler pipes cfg.notify_on_error into the response
    //    (i.e. the makeNalarConfigResponse call references the new
    //    field sourced from cfg).
    if (std.mem.indexOf(u8, get_src, ".notify_on_error = cfg.notify_on_error") == null) {
        std.debug.print("!! nalar_config_get.zig does not pipe notify_on_error !!\n", .{});
        return error.NotifyOnErrorNotWiredIntoGet;
    }
}