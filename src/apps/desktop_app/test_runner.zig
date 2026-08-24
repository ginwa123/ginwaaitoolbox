// src/apps/desktop_app/test_runner.zig
//
// Test discovery for the desktop-app test step. Each `test { ... }` block here
// forces the test files to be reachable from the module's root source file
// (main.zig), so Zig's test runner picks them up. Without this, the _test.zig
// files would be on disk but not part of any compilation unit.
//
// In regular (non-test) builds this file's `test { ... }` blocks are inert —
// the imports are evaluated as `_ = @import("...")` discards, so the test
// files are reachable through the import graph but their test blocks never run.

test {
    _ = @import("port_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("path_resolve_test.zig");
    _ = @import("subprocess_test.zig");
    _ = @import("extraction_test.zig");
    _ = @import("platform/linux_test.zig");
    _ = @import("platform/linux_gfx_test.zig");
    _ = @import("attach_test.zig");
}