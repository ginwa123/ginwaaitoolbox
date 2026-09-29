//! Test runner for the migrations module.
//!
//! Every migration test lives INLINE at the bottom of `migration.zig`
//! (impl + tests in one file — the project convention established by the
//! 2026-09-11 flatten pass). Importing `migration.zig` is what makes those
//! top-level `test` blocks discoverable by the project's top-level
//! `zig build test` target (which imports this file via
//! `src/root.zig:446`).

test {
    _ = @import("migration.zig");
}
