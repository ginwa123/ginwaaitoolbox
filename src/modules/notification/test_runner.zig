

test {
    // 2026-09-29 flatten: notifications_test.zig was merged inline into
    // notifications.zig. A `test` block is only discovered from a DIRECT
    // import, so the implementation file is registered here.
    _ = @import("notifications.zig");
}
