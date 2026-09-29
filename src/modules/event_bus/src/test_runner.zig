//! Aggregates the comprehensive edge-case test suite for `EventBus`.
//!
//! This file is the test registration point for the event_bus module.
//! It is imported from two places:
//!   - `event_bus/src/root.zig` — so the event_bus module's own
//!     `zig build test` (its `mod_tests` step) picks up the suite.
//!   - `src/root.zig` (the main project root) — so the main project's
//!     `zig build test` (which transitively imports event_bus) picks
//!     up the suite under one consistent test runner.
//!
//! Using a dedicated test_runner.zig avoids the cycle that would arise
//! if `event.zig` itself contained a `test { _ = @import(...) }` block
//! importing itself.
//! The test_runner.zig file only contains a `test {...}` block; it
//! has no other dependencies, so there's nothing to cycle.

test {
    // 2026-09-29 flatten: event_test.zig was merged inline into event.zig.
    // Importing the implementation file (not the test file) is what keeps
    // those tests discoverable, and this runner still holds no other
    // dependency, so the cycle the header describes stays avoided.
    _ = @import("event.zig");
}
