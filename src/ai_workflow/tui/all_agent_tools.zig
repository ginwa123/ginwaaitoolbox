const std = @import("std");
const json = std.json;
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const prompt = root_mod.prompt;
const context = @import("models.zig").ContextIPCTui;
const sqlite = root_mod.sqlite;
const bash_tool = root_mod.bash_tool;
const read_file_tool = root_mod.read_file;
const tool_models = root_mod.tool_models;
const set_agent_properties = root_mod.set_agent_properties;
const list_skills_tool = root_mod.list_skills_tool;
const get_skill_tool = root_mod.get_skill_tool;
const remove_skill_tool = root_mod.remove_skill_tool;
const skills = root_mod.skills;
const list_agents_tool = root_mod.list_agents_tool;
const get_agent_tool = root_mod.get_agent_tool;
const loop_detector = root_mod.loop_detector;
const bash_helper = root_mod.helperTool;
const get_tree_dir = @import("get_tree_dir.zig");
const logger_mod = root_mod.logger;
const get_current_agent_by_session_id = @import("get_current_agent_by_session_id.zig");
const TUIHistory = @import("models.zig").TUIHistory;
const transform_llm_history_to_agent_message = @import("transform_llm_history_to_agent_messages.zig");
const ResponseType = @import("on_event_sent.zig").ResponseType;
const Response = @import("on_event_sent.zig").Response;
const GetMessages = @import("get_messages.zig").GetMessages;
const mark_messages_not_for_llm = @import("mark_message_not_for_llm.zig");
const handle_set_agent_properties = @import("handle_set_agent_properties.zig");
const handle_bash_tool = @import("handle_bash_tool.zig");
const BuildMemoryForAgent = @import("build_memory_for_agent_prompt.zig").BuildMemoryForAgent;
const write_file_tool = root_mod.write_file;
const search_tool = root_mod.search_tool;
const text_replace_tool = root_mod.text_replace_tool;
const handle_content_filter = @import("handle_content_filter.zig");
const BuildSkillContent = @import("build_skill_for_agent_prompt.zig").BuildSkillContent;
const save_skill_mod = @import("save_skill.zig");
const buildMcpTools = @import("build_messages_tools_mcp_for_agent_prompt.zig");
const config_mod = @import("../../modules/config/config.zig");
pub const cancellation_registry = root_mod.session.cancellation_registry;
const HandleTool = @import("handle_tool.zig").HandleTool;
const spawn_sub_agent_tool = @import("../../modules/agent/tools/spawn_sub_agent.zig");
const lspDefinitionTool = root_mod.tool_models.lspDefinitionTool;
const lspReferencesTool = root_mod.tool_models.lspReferencesTool;
const lspWorkspaceSymbolTool = root_mod.tool_models.lspWorkspaceSymbolTool;
const lspDocumentSymbolTool = root_mod.tool_models.lspDocumentSymbolTool;
const lspHoverTool = root_mod.tool_models.lspHoverTool;

pub const AllAgentTools: []const tool_models.AgentTool = &.{
    bash_tool.bashTool,
    read_file_tool.readFileTool,
    set_agent_properties.SetAgentPropertiesTool,
    list_skills_tool.listSkillsTool,
    get_skill_tool.getSkillTool,
    remove_skill_tool.removeSkillTool,
    write_file_tool.writeFileTool,
    text_replace_tool.textReplaceTool,
    search_tool.searchTool,
    spawn_sub_agent_tool.spawnSubAgentTool,
    list_agents_tool.listAgentsTool,
    get_agent_tool.GetAgentTool,
    lspDefinitionTool,
    lspReferencesTool,
    lspWorkspaceSymbolTool,
    lspDocumentSymbolTool,
    lspHoverTool,
};
