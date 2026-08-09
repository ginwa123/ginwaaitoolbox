//! `databases` package — public API root.
//!
//! Consumers import as `@import("databases")` (the module name declared
//! in build.zig) and access nested namespaces:
//!
//!   const sqlite = @import("databases").sqlite;
//!   const postgres = @import("databases").postgres;
//!
//! `databases` is a self-contained Zig package — its own build.zig
//! wires sqlite3 / openssl / libpq + vendored sqlite3 amalgamation
//! based on the target the consumer passes via `b.dependency()`.
//! Consumers should NOT re-link these themselves; importing this module
//! pulls in the right deps for the target.

pub const sqlite = @import("sqlite/Sqlite.zig");
pub const postgres = @import("postgres/Postgres.zig");

// Internal helpers — exposed so the package's own test_runner.zig can
// be discovered by `zig build test`. The root re-export also enables
// `zig fetch` to include the test runner in the package hash.
pub const test_runner = @import("test_runner.zig");

// Generic database abstraction (currently a thin alias for Sqlite.zig;
// kept as a stable seam so consumers can swap implementations later).
pub const database = @import("database.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
