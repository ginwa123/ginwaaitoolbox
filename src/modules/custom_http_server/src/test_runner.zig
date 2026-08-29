

// Test runner for the custom_http_server module.
//
// Runs every test in this module EXCEPT two files that have hard
// dependencies on the parent project (Zig 0.16 forbids `@import` /
// `@embedFile` of files outside the module package path):
//
//   - `sse_chunked_test.zig` — `@embedFile("../../../../src/root.zig")`
//   - `read_html_test.zig`   — `@import("../../../root.zig")`
//
// These two are re-imported directly by `src/root.zig` in the parent
// project so they're still covered when running `zig build test` from
// the repo root.
//
// The 60 s SSE-keepalive soak tests in `sse_keepalive_test.zig` are
// INTENTIONALLY included here so the parent project's `zig build test`
// stays fast (the two soaks dominate runtime at ~120 s). To exercise
// them, run:
//
//   cd src/modules/custom_http_server && zig build test --summary all
//
// (the parent project's `zig build test` skips them — see src/root.zig).
const std = @import("std");
const builtin = @import("builtin");

test {
    // sse_manager_test.zig, http_server_test.zig (socket-pair paths),
    // and security_test.zig all call posix.system.socketpair /
    // linux.read / linux.close with i32 file descriptors. Zig 0.16
    // doesn't expose those on Windows (where sockets are HANDLE =
    // *anyopaque and posix.system.close is `void`), so the tests
    // fail to COMPILE on Windows even though the test bodies would
    // correctly skip via `if (is_windows) return;`. We exclude the
    // whole files here rather than individually guarding every test
    // — Windows CI coverage of these is intentionally nil until the
    // underlying SseManager / HttpServer APIs are ported to use
    // cross-platform fd_t (tracked in src/main.zig's "Out of scope"
    // pre-existing Windows bugs list).
    if (builtin.os.tag != .windows) {
        _ = @import("http_server_test.zig");
        _ = @import("sse_manager_test.zig");
    }
    _ = @import("router_test.zig");
    _ = @import("http_parser_test.zig");
    // sse_chunked_test.zig is excluded because its static-contract tests
    // use `@embedFile("../../../../src/root.zig")` which Zig 0.16 rejects
    // (embed of file outside package path). Those tests run as part of
    // the parent project's `zig build test` instead.
    // _ = @import("sse_chunked_test.zig");
    _ = @import("test_session_lifecycle.zig");
    // complex_cases_*.zig use POSIX-only syscalls (`posix.system.socketpair`,
    // `linux.read`/`linux.close`/`linux.write`) that Zig 0.16 doesn't
    // expose on Windows (where sockets are HANDLE = *anyopaque, and
    // `posix.system.close` is `void`). Tests that need them are
    // guarded with `if (is_windows) return;` inside each file. On
    // Windows we still skip the FILE-level compile by guarding the
    // @import — that keeps the build green without each test having
    // to rediscover the same Windows workarounds.
    if (builtin.os.tag != .windows) {
        _ = @import("complex_cases_test.zig");
        _ = @import("complex_cases_extra_test.zig");
        _ = @import("security_test.zig");
        _ = @import("sse_keepalive_test.zig");
    }
    _ = @import("main_static_html_test.zig");
    // WebSocket support (RFC 6455) — frames, handshake, manager.
    // websocket_manager_test.zig uses `std.posix.system.socket` /
    // `.pipe` / `.close`, which require linking ws2_32 on Windows (the
    // build.zig here only links `c`, not `ws2_32`, and `std.c.socket`
    // has the same 32-bit-handle truncation problem the parent build
    // works around in `build.zig`). Skip on Windows to keep the build
    // green; frame/handshake tests are pure parsers so they run
    // everywhere.
    _ = @import("websocket_frames_test.zig");
    _ = @import("websocket_handshake_test.zig");
    if (builtin.os.tag != .windows) {
        _ = @import("websocket_manager_test.zig");
    }
    // Jinja-style template engine — tokenizer, parser, renderer, inheritance
    _ = @import("template_test.zig");
    // readHtml helper — read template file with embedded-source fallback.
    // Excluded from the module's own build because it imports
    // ../../../root.zig (parent only). The parent project re-imports it
    // directly via src/root.zig.
    // _ = @import("read_html_test.zig");
    // Per-request Context value bag + HttpResponse.redirectWithContext
    _ = @import("context_test.zig");
    // Cronjob manager — pure-function parser + scheduler unit tests (no thread)
    _ = @import("cron_expression_test.zig");
    // Cronjob manager — registry + thread start/stop tests
    _ = @import("cronjob_manager_test.zig");
    // Group + middleware worked example — registers a sample API on a
    // Router (groups, nested groups, two middlewares) and runs a
    // series of tests that exercise prefix joining, middleware chain
    // ordering, header augmentation, and short-circuiting. Doubles
    // as living documentation for the Router.group / Group.use API.
    _ = @import("example_group.zig");
}
