

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
    _ = @import("test_helpers.zig"); // Compile-only — ensures the cross-platform helpers stay in sync.
    _ = @import("http_server_test.zig");
    _ = @import("sse_manager_test.zig");
    _ = @import("router_test.zig");
    _ = @import("http_parser_test.zig");
    // sse_chunked_test.zig is excluded because its static-contract tests
    // use `@embedFile("../../../../src/root.zig")` which Zig 0.16 rejects
    // (embed of file outside package path). Those tests run as part of
    // the parent project's `zig build test` instead.
    // _ = @import("sse_chunked_test.zig");
    _ = @import("test_session_lifecycle.zig");
    _ = @import("complex_cases_test.zig");
    _ = @import("complex_cases_extra_test.zig");
    _ = @import("main_static_html_test.zig");
    // 60s soak test for the SSE-keepalive bug — intentionally ONLY
    // here, not in the parent's `zig build test` (see header comment).
    _ = @import("sse_keepalive_test.zig");
    // WebSocket support (RFC 6455) — frames, handshake, manager
    _ = @import("websocket_frames_test.zig");
    _ = @import("websocket_handshake_test.zig");
    _ = @import("websocket_manager_test.zig");
    // Jinja-style template engine — tokenizer, parser, renderer, inheritance
    _ = @import("template_test.zig");
    // Security primitives — CSRF, rate limit, security headers, origin, body size
    _ = @import("security_test.zig");
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

    // HTTP/2 (h2c) subsystem — frame/settings/HPACK/stream/flow-control unit
    // tests. The aggregator imports each implementation file, which in turn
    // pulls its own sibling `*_test.zig`. This MUST also be registered in
    // `src/root.zig`'s test block, otherwise the CI gate skips these tests.
    _ = @import("http2/test_runner.zig");
    // Peekable connection buffer — the piece that lets the server sniff the h2
    // preface BEFORE the HTTP/1.1 request reader consumes it.
    _ = @import("connection_reader.zig");
}
