

// Test runner that runs only the SSE manager tests
const std = @import("std");

// SSE Manager tests - verifies memory corruption fix for client removal
test {
    _ = @import("http_server_test.zig");
    _ = @import("sse_manager_test.zig");
    _ = @import("router_test.zig");
    _ = @import("http_parser_test.zig");
}
