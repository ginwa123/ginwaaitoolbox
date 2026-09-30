// src/apps/desktop_app/test_runner.zig
//
// Test discovery for the desktop-app test step. Each `test { ... }` block here
// forces the modules to be reachable from the module's root source file
// (main.zig), so Zig's test runner picks up their inline tests. Without this,
// a module would be on disk but not part of any compilation unit.
//
// Each implementation file carries its own tests inline (merged from the
// former `*_test.zig` files), so importing the implementation is what makes
// those tests discoverable. main.zig is the root source file here, so its own
// inline tests need no entry below.
//
// In regular (non-test) builds this file's `test { ... }` blocks are inert —
// the imports are evaluated as `_ = @import("...")` discards, so the modules
// are reachable through the import graph but their test blocks never run.

test {
    _ = @import("port.zig");
    _ = @import("cli.zig");
    _ = @import("browser.zig");
    _ = @import("path_resolve.zig");
    _ = @import("subprocess.zig");
    _ = @import("extraction.zig");
    _ = @import("webview_lib.zig");
    _ = @import("attach.zig");
}
