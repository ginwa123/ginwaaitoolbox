// Re-export all public tool definitions for convenience
pub const agents = @import("agents.zig");
pub const list_agents = @import("list_agents.zig");
pub const change_agent = @import("change_agent.zig");
pub const lsp_definition = @import("lsp_definition.zig");
pub const lsp_references = @import("lsp_references.zig");
pub const lsp_workspace_symbol = @import("lsp_workspace_symbol.zig");
pub const lsp_document_symbol = @import("lsp_document_symbol.zig");
pub const lsp_hover = @import("lsp_hover.zig");
pub const tree_dir = @import("tree_dir.zig");

pub const list_agents_tool = list_agents.list_agents_tool;
pub const change_agent_tool = change_agent.change_agent_tool;
pub const lsp_definition_tool = lsp_definition.lsp_definition_tool;
pub const lsp_references_tool = lsp_references.lsp_references_tool;
pub const lsp_workspace_symbol_tool = lsp_workspace_symbol.lsp_workspace_symbol_tool;
pub const lsp_document_symbol_tool = lsp_document_symbol.lsp_document_symbol_tool;
pub const lsp_hover_tool = lsp_hover.lsp_hover_tool;
pub const tree_dir_tool = tree_dir.tree_dir_tool;
