

// Test runner that runs only the SSE manager tests
const std = @import("std");

// SSE Manager tests - verifies memory corruption fix for client removal
test {
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
    // 60s soak test for the SSE-keepalive bug
    _ = @import("sse_keepalive_test.zig");
    // WebSocket support (RFC 6455) — frames, handshake, manager
    _ = @import("websocket_frames_test.zig");
    _ = @import("websocket_handshake_test.zig");
    _ = @import("websocket_manager_test.zig");
    // Jinja-style template engine — tokenizer, parser, renderer, inheritance
    _ = @import("template_test.zig");
    // Security primitives — CSRF, rate limit, security headers, origin, body size
    _ = @import("security_test.zig");
    // readHtml helper — read template file with embedded-source fallback
    _ = @import("read_html_test.zig");
    // Per-request Context value bag + HttpResponse.redirectWithContext
    _ = @import("context_test.zig");
}
