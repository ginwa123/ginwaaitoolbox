const std = @import("std");
const send_error = @import("send_error.zig");

test "send_error module exists" {
    // This module has logger dependencies, so we just verify it compiles
    _ = send_error;
}
