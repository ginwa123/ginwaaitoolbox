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

pub const on_event_sent = @import("on_event_sent.zig");
pub const on_event_design = @import("on_event_design.zig");
pub const on_event_sent_design = @import("on_event_sent_design.zig");
pub const on_event_sent_kanban = @import("on_event_sent_kanban.zig");

pub const inherited_context = @import("inherited_context.zig");
pub const agent_memories = @import("agent_memories.zig");

pub const kanban_model = @import("kanban_model.zig");
pub const design_io = @import("design_io.zig");