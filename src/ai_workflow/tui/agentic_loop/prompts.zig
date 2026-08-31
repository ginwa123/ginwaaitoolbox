

pub const makeWorkspaceContext = @import("prompts_make_workspace_context.zig").makeWorkspaceContext;
pub const makeWorkingDirectoryContext = @import("prompts_make_working_directory_context.zig").makeWorkingDirectoryContext;
pub const makeSkillsEquippedContext = @import("prompts_make_skills_equiped_context.zig").makeSkillsEquippedContext;
pub const makeKanbanContext = @import("prompts_make_kanban_context.zig").makeKanbanContext;
pub const makeActivityInfo = @import("prompts_make_activity_info_context.zig").makeActivityInfo;
pub const makeAgentKnowledge = @import("prompts_make_agent_knowledge.zig").makeAgentKnowledge;
pub const makeAgentSystemPrompt = @import("prompts_make_agent_system_prompt.zig").makeAgentSystemPrompt;
// Agent-Kanbans mirror (Migration 081)
pub const makeAgentKanbanKnowledge = @import("prompts_make_agent_kanban_knowledge.zig").makeAgentKanbanKnowledge;
pub const makeAgentKanbanSystemPrompt = @import("prompts_make_agent_kanban_system_prompt.zig").makeAgentKanbanSystemPrompt;
pub const makePlanContext = @import("prompts_make_plan_context.zig").makePlanContext;
