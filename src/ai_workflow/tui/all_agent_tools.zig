const root_mod = @import("nalarcore");
const tool_models = root_mod.tool_models;
const bash_tool = root_mod.bash_tool;
const read_file_tool = root_mod.read_file;
const write_file_tool = root_mod.write_file;
const text_replace_tool = root_mod.text_replace_tool;
const search_tool = root_mod.search_tool;
const glob_tool = root_mod.glob_tool;
const list_skills_tool = root_mod.list_skills_tool;
const get_skill_tool = root_mod.get_skill_tool;
const remove_skill_tool = root_mod.remove_skill_tool;
const list_agents = root_mod.list_agents;
const change_agent = root_mod.change_agent;
const set_agent_properties = root_mod.set_agent_properties;
const spawn_sub_agent_tool = root_mod.spawn_sub_agent;
const tree_dir = root_mod.tree_dir;
const lsp_definition_tool = root_mod.tools.lspDefinitionTool;
const lsp_references_tool = root_mod.tools.lspReferencesTool;
const lsp_workspace_symbol_tool = root_mod.tools.lspWorkspaceSymbolTool;
const lsp_document_symbol_tool = root_mod.tools.lspDocumentSymbolTool;
const lsp_hover_tool = root_mod.tools.lspHoverTool;

/// All tools for the main agent
/// This is the canonical list of tool definitions for the main agent
pub const all_agent_tools: []const tool_models.AgentTool = &.{
    set_agent_properties.SetAgentPropertiesTool,
    spawn_sub_agent_tool.spawnSubAgentTool,
    list_agents.listAgentsTool,
    change_agent.ChangeAgentTool,
    list_skills_tool.listSkillsTool,
    get_skill_tool.getSkillTool,
    remove_skill_tool.removeSkillTool,
    bash_tool.bashTool,
    read_file_tool.readFileTool,
    write_file_tool.writeFileTool,
    text_replace_tool.textReplaceTool,
    search_tool.searchTool,
    glob_tool.globTool,
    tree_dir.tree_dir_tool,
    lsp_definition_tool,
    lsp_references_tool,
    lsp_workspace_symbol_tool,
    lsp_document_symbol_tool,
    lsp_hover_tool,
};
