// Test discovery for the `src/modules/` tree.
//
// Every implementation file in this directory carries its own test blocks
// inline (merged from the former `*_test.zig` siblings), so importing the
// IMPLEMENTATION is what makes those tests discoverable — a `pub const`
// re-export of the module elsewhere does not pull them into the test binary.

test {
    _ = @import("static_files.zig");
    _ = @import("system_folder/system_folder.zig");
    _ = @import("../service/state_file.zig");
    _ = @import("../service/daemon.zig");
    _ = @import("../service/signal_handlers.zig");
    _ = @import("../service/main_service.zig");
}
