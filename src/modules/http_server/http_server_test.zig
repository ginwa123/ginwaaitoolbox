const std = @import("std");

test "http_server module imports" {
    // Test that the http_server module can be imported
    // Note: Requires httpz dependency which is only available via nalarcore module
    const http_server = @import("http_server.zig");
    _ = http_server;
    try std.testing.expect(true);
}
