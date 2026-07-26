test {
    _ = @import("static_files_test.zig");
    _ = @import("system_folder/system_folder_test.zig");
    _ = @import("../service/state_file_test.zig");
    _ = @import("../service/daemon_test.zig");
    _ = @import("../service/signal_handlers_test.zig");
    _ = @import("../service/main_service_test.zig");
}
