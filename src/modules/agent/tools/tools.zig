// Re-export all public tool definitions for convenience
pub const agents = @import("agents.zig");
pub const list_agents = @import("list_agents.zig");
pub const change_agent = @import("change_agent.zig");
pub const lsp_definition = @import("lsp_definition.zig");
pub const lsp_references = @import("lsp_references.zig");
pub const lsp_workspace_symbol = @import("lsp_workspace_symbol.zig");
pub const lsp_document_symbol = @import("lsp_document_symbol.zig");
pub const lsp_hover = @import("lsp_hover.zig");

pub const listAgentsTool = list_agents.listAgentsTool;
pub const changeAgentTool = change_agent.ChangeAgentTool;
pub const lspDefinitionTool = lsp_definition.lspDefinitionTool;
pub const lspReferencesTool = lsp_references.lspReferencesTool;
pub const lspWorkspaceSymbolTool = lsp_workspace_symbol.lspWorkspaceSymbolTool;
pub const lspDocumentSymbolTool = lsp_document_symbol.lspDocumentSymbolTool;
pub const lspHoverTool = lsp_hover.lspHoverTool;
