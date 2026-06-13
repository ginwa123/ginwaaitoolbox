//! `routines` module re-exports. Used by `src/ai_workflow/tui/mod.zig`
//! and the sub-process binary under `bin/`.
//!
//! The `Scheduler` export is a placeholder for Task 2.1 — Task 3.1
//! (Chunk 3) creates the real `Scheduler.zig` and the import below
//! is updated to point at it.

pub const model = @import("model.zig");
pub const cron = @import("cron.zig");
pub const fire = @import("fire.zig");

/// Placeholder for Chunk 3's polling loop. Task 3.1 replaces this
/// with `@import("Scheduler.zig").Scheduler` once the Scheduler
/// module exists. The empty struct keeps the `mod` import surface
/// stable across chunks.
pub const Scheduler = struct {};
