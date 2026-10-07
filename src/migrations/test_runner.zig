//! Test runner for the migrations module.
//!
//! Each migration's implementation lives in its own `migration_<N>.zig`
//! file (N = the `version: u32` inside; shared types and helpers live in
//! `common.zig`), while `migration.zig` re-exports every migration and
//! holds the `allMigrations` registry plus the inline tests. Importing
//! `migration.zig` is what makes those top-level `test` blocks
//! discoverable by the project's top-level `zig build test` target
//! (which imports this file via `src/root.zig`).

test {
    _ = @import("migration.zig");
}
