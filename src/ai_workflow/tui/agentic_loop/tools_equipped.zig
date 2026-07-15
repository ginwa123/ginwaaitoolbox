const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const helpers = nalarcore.helpers;
const AgentTool = nalarcore.agent.AgentTool;

const bash_tool_mod = nalarcore.bash_tool;
const read_file_mod = nalarcore.read_file;
const text_replace_mod = nalarcore.text_replace_tool;
const write_file_mod = nalarcore.write_file;
const list_skills_mod = nalarcore.list_skills_tool;
const memories_mod = nalarcore.memories;
const list_memory_mod = nalarcore.list_memory_tool;
const search_history_mod = nalarcore.search_history_tool;
const get_skill_mod = nalarcore.get_skill_tool;
const view_skill_mod = nalarcore.view_skill_tool;
const remove_skill_mod = nalarcore.remove_skill_tool;
const list_agents_mod = nalarcore.list_agents;
const add_skill_mod = nalarcore.add_skill;
const edit_skill_mod = nalarcore.edit_skill;
const set_git_worktree_mod = nalarcore.set_git_worktree;
const kanban_list_mod = nalarcore.kanban_list;
const kanban_move_task_mod = nalarcore.kanban_move_task;
const show_preview_mod = nalarcore.ai_mod.show_preview;
const remove_agent_mod = nalarcore.remove_agent;
const remove_file_mod = nalarcore.remove_file;
const change_agent_mod = nalarcore.change_agent;
const lsp_definition_mod = nalarcore.tools.lsp_definition;
const lsp_references_mod = nalarcore.tools.lsp_references;
const lsp_workspace_symbol_mod = nalarcore.tools.lsp_workspace_symbol;
const lsp_document_symbol_mod = nalarcore.tools.lsp_document_symbol;
const lsp_hover_mod = nalarcore.tools.lsp_hover;
const set_agent_properties_mod = nalarcore.set_agent_properties;
const web_search_mod = nalarcore.web_search;
const nalar_browser_mod = nalarcore.nalar_browser;
const update_activity_mod = nalarcore.update_activity;
const glob_tool_mod = nalarcore.glob_tool;
const search_tool_mod = nalarcore.search_tool;
const semantic_search_mod = nalarcore.semantic_search;
const spawn_sub_agent_tool = nalarcore.spawn_sub_agent;
const xmlEscape = helpers.xml_escape;

pub fn equips(allocator: std.mem.Allocator) []const AgentTool {
    const tools_list = comptime &[_]AgentTool{
        // set_agent_properties_mod.set_agent_properties_tool,
        spawn_sub_agent_tool.spawn_sub_agent_tool,
        update_activity_mod.update_activity_tool,
        list_skills_mod.list_skills_tool,
        list_memory_mod.list_memory_tool,
        search_history_mod.search_history_tool,
        view_skill_mod.view_skill_tool,
        get_skill_mod.get_skill_tool,
        remove_skill_mod.remove_skill_tool,
        add_skill_mod.add_skill_tool,
        edit_skill_mod.edit_skill_tool,
        bash_tool_mod.bash_tool,
        read_file_mod.read_file_tool,
        write_file_mod.write_file_tool,
        text_replace_mod.text_replace_tool,
        remove_file_mod.remove_file_tool,
        glob_tool_mod.glob_tool,
        search_tool_mod.search_tool,
        nalar_browser_mod.nalar_browser_tool,
        set_git_worktree_mod.set_git_worktree_tool,
        kanban_list_mod.kanban_list_tool,
        kanban_move_task_mod.kanban_move_task_tool,
        show_preview_mod.show_preview_tool,
    };
    return allocator.dupe(AgentTool, tools_list) catch return &.{};
}
