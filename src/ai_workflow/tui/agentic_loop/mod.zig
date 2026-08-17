//! Re-exports for the `agentic_loop/` directory.
//!
//! Tests in this directory use inline `test "..." { ... }` blocks at the
//! bottom of each impl file (NOT separate `<file>_test.zig` files) — see
//! README.md and `agentic_loop/test_runner.zig` for the discovery
//! convention.

pub const ActiveLoops = @import("ActiveLoops.zig").ActiveLoops;
pub const models = @import("models.zig");
pub const background_process = @import("background_process.zig");
pub const save_agent = @import("save_agent.zig");
// save_skill.zig is not yet implemented (its companion test file was
// orphaned — see deleted src/ai_workflow/tui/save_skill_test.zig in
// the Phase 1 commit). Once the impl lands, expose it here.
// pub const save_skill = @import("save_skill.zig");
pub const startup = @import("startup.zig");