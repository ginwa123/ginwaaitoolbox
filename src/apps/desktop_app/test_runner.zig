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
//
// New test files are added here as the corresponding modules are introduced
// (port_test.zig in Task 1.2, cli_test.zig in Task 1.3, etc.).
