
pub const nalarcore = @import("nalarcore");
pub const models = @import("models.zig");
pub const http_handlers = @import("http_handlers/mod.zig");
pub const ai_workflow = @import("agentic_loop/workflow.zig");
pub const llm_history = @import("llm_history.zig");
pub const on_event_sent = @import("on_event_sent.zig");
pub const on_event_sent_kanban = @import("on_event_sent_kanban.zig");
pub const on_event_design = @import("on_event_design.zig");
pub const on_event_sent_design = @import("on_event_sent_design.zig");
pub const show_preview = @import("../../modules/agent/tools/show_preview.zig");
pub const get_design_context = @import("../../modules/agent/tools/get_design_context.zig");
pub const preview_design_page = @import("../../modules/agent/tools/preview_design_page.zig");
pub const active_loops = @import("ActiveLoops.zig").ActiveLoops;
pub const routines = @import("routines/mod.zig");
pub const startup = @import("startup.zig");
pub const kanban_model = @import("kanban_model.zig");
pub const design_io = @import("design_io.zig");
pub const design_model = @import("design_model.zig");

// Re-export workspace functions from llm_history for backward compatibility
pub const workspace_items = llm_history;
pub const workspace_item_tasks = llm_history;

// Re-export session->client mapping functions from root
pub const registerSessionClient = @import("nalarcore").registerSessionClient;
pub const unregisterSessionClient = @import("nalarcore").unregisterSessionClient;
pub const getClientIdForSession = @import("nalarcore").getClientIdForSession;
pub const getListClientsForSession = @import("nalarcore").getListClientsForSession;
pub const getSessionIdForClient = @import("nalarcore").getSessionIdForClient;
pub const handleClientDisconnect = @import("nalarcore").handleClientDisconnect;
