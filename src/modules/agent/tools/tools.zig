// Re-export all public tool definitions for convenience
pub const agents = @import("agents.zig");
pub const list_agents = @import("list_agents.zig");
pub const change_agent = @import("change_agent.zig");
pub const lsp_definition = @import("lsp_definition.zig");
pub const lsp_references = @import("lsp_references.zig");
pub const lsp_workspace_symbol = @import("lsp_workspace_symbol.zig");
pub const lsp_document_symbol = @import("lsp_document_symbol.zig");
pub const lsp_hover = @import("lsp_hover.zig");
pub const web_search = @import("web_search.zig");
pub const add_skill = @import("add_skill.zig");
pub const edit_skill = @import("edit_skill.zig");
pub const add_agent = @import("add_agent.zig");

pub const list_agents_tool = list_agents.list_agents_tool;
pub const change_agent_tool = change_agent.change_agent_tool;
pub const lsp_definition_tool = lsp_definition.lsp_definition_tool;
pub const lsp_references_tool = lsp_references.lsp_references_tool;
pub const lsp_workspace_symbol_tool = lsp_workspace_symbol.lsp_workspace_symbol_tool;
pub const lsp_document_symbol_tool = lsp_document_symbol.lsp_document_symbol_tool;
pub const lsp_hover_tool = lsp_hover.lsp_hover_tool;
pub const web_search_tool = web_search.web_search_tool;
pub const add_skill_tool = add_skill.add_skill_tool;
pub const edit_skill_tool = edit_skill.edit_skill_tool;
pub const add_agent_tool = add_agent.add_agent_tool;
