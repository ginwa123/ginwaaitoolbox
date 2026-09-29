test {
    // 2026-09-29 flatten: formatter_test / logger_test / memory_leak_test /
    // request_id_test / timing_test were merged inline into the modules they
    // cover. A `test` block is only discovered from a DIRECT import, so each
    // implementation file is registered here instead. Logger.zig covers both
    // logger_test.zig and memory_leak_test.zig, so it is listed once.
    _ = @import("Formatter.zig");
    _ = @import("Logger.zig");
    _ = @import("RequestId.zig");
    _ = @import("Timing.zig");
}
