

test {
    _ = @import("sqlite/sqlite_test.zig");
    _ = @import("sqlite/sqlite_test_rows_capture_error.zig");
    _ = @import("postgres/postgres_test.zig");
    _ = @import("postgres/test_helpers_test.zig");
}
