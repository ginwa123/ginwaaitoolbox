

pub const migration = @import("migration.zig");
pub const models = @import("models.zig");
pub const http_handlers = @import("http_handlers/mod.zig");
pub const ai_workflow = @import("workflow.zig");
pub const llm_history = @import("llm_history.zig");
pub const on_event_sent = @import("on_event_sent.zig");
pub const active_loops = @import("ActiveLoops.zig").ActiveLoops;
pub const routines = @import("routines/mod.zig");

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
