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
const tools = root_mod.tools;
const web_search = root_mod.web_search;
const web_search_help = root_mod.web_search_help;

/// All tools for the main agent
/// This is the canonical list of tool definitions for the main agent
pub const all_agent_tools: []const tool_models.AgentTool = &.{
    set_agent_properties.set_agent_properties_tool,
    spawn_sub_agent_tool.spawn_sub_agent_tool,
    list_agents.list_agents_tool,
    change_agent.change_agent_tool,
    list_skills_tool.list_skills_tool,
    get_skill_tool.get_skill_tool,
    remove_skill_tool.remove_skill_tool,
    bash_tool.bash_tool,
    read_file_tool.read_file_tool,
    write_file_tool.write_file_tool,
    text_replace_tool.text_replace_tool,
    search_tool.search_tool,
    glob_tool.glob_tool,
    tree_dir.tree_dir_tool,
    tools.lsp_definition_tool,
    tools.lsp_references_tool,
    tools.lsp_workspace_symbol_tool,
    tools.lsp_document_symbol_tool,
    tools.lsp_hover_tool,
    web_search.web_search_tool,
    web_search_help.web_search_help_tool,
};
