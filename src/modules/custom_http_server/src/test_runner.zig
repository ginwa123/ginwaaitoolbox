

// Test runner that runs only the SSE manager tests
const std = @import("std");

// SSE Manager tests - verifies memory corruption fix for client removal
test {
    _ = @import("sse_manager_test.zig");
}
