const std = @import("std");
const builtin = @import("builtin");
const list_skills = @import("tools/list_skills.zig");
const agents = @import("tools/agents.zig");
const prompts = @import("prompts/prompts.zig");
const tool_models = @import("nalarcore").tool_models;

/// Get the current operating system as a human-readable string
fn getCurrentOs() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "Linux",
        .macos => "macOS",
        .windows => "Windows",
        .freebsd => "FreeBSD",
        .netbsd => "NetBSD",
        .openbsd => "OpenBSD",
        .dragonfly => "DragonFly",
        .ios => "iOS",
        else => @tagName(builtin.os.tag),
    };
}

// Re-export all prompts for easy access
pub const UniversalRules = prompts.UniversalRules;
pub const PromptAutoFix = prompts.PromptAutoFix;
pub const DynamicProperties = prompts.DynamicProperties;
pub const Agent = prompts.Agent;
pub const ParallelWork = prompts.ParallelWork; // ✅ CONSOLIDATED parallel rules
pub const ParallelMandatoryIntro = prompts.ParallelMandatoryIntro;
pub const ParallelMandatory = prompts.ParallelMandatory;
pub const ParallelWorkflow = prompts.ParallelWorkflow;
pub const ParallelExamples = prompts.ParallelExamples;
pub const ParallelAntiPatterns = prompts.ParallelAntiPatterns;
pub const ParallelSubAgentGuidance = prompts.ParallelSubAgentGuidance;
pub const ParallelSkillReminder = prompts.ParallelSkillReminder;
pub const Research = prompts.Research;
pub const ResearchTriggers = prompts.ResearchTriggers;
pub const FileEditingRules = prompts.FileEditingRules;
pub const AvailableTools = prompts.AvailableTools;
pub const ChangeAgent = prompts.ChangeAgent;
pub const SpecializationTable = prompts.SpecializationTable;
pub const SubAgentPrompt = prompts.SubAgentPrompt;
pub const SubAgentBrief = prompts.SubAgentBrief;
pub const Classification = prompts.Classification;
pub const Execution = prompts.Execution;
pub const Escalation = prompts.Escalation;
pub const PlanBlock = prompts.PlanBlock;
pub const TDD = prompts.TDD;
pub const MemoryPrompt = prompts.MemoryPrompt;
pub const GitPrompt = prompts.GitPrompt;
pub const AgentMdAutoUpdate = prompts.AgentMdAutoUpdate;
pub const TaskManagementPrompt = prompts.TaskManagementPrompt;
pub const CompactionAgent = prompts.CompactionAgent;
pub const DestroyIdea = prompts.DestroyIdea;
pub const SkillsUsage = prompts.SkillsUsage;
pub const SkillsTriggers = prompts.SkillsTriggers;
pub const LoadedSkills = prompts.LoadedSkills;
pub const ProceduralMemory = prompts.ProceduralMemory;
pub const ResponseFormatting = prompts.ResponseFormatting;
pub const UpdateActivityRule = prompts.UpdateActivityRule;

// Legacy exports for backwards compatibility
pub const BasePrompt = UniversalRules;
pub const AgentsMdPrompt = prompts.MemoryPrompt;

// =============================================================================
// PROMPT BUILDERS
// =============================================================================

/// Build sub-agent prompt with a focused, minimal set of rules
/// Sub-agents get a simple, research-focused prompt (NOT the full main agent prompt)
pub fn build_sub_agent_prompt(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    treeDir: []const u8,
    task_brief: []const u8,
    tools: []const tool_models.AgentTool,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // 1. Universal rules (minimal safety + file editing basics)
    try result.appendSlice(allocator, UniversalRules);
    try result.appendSlice(allocator, "\n\n");

    // 2. Sub-agent prompt (research-focused instructions)
    try result.appendSlice(allocator, SubAgentPrompt);
    try result.appendSlice(allocator, "\n\n");

    // 3. Task brief from parent agent (the specific mission)
    if (task_brief.len > 0) {
        try result.appendSlice(allocator, "## Your Mission\n\n");
        try result.appendSlice(allocator, task_brief);
        try result.appendSlice(allocator, "\n\n");
    }

    // 4. Output format
    try result.appendSlice(allocator, SubAgentBrief);
    try result.appendSlice(allocator, "\n\n");

    // 5. Available tools
    if (tools.len > 0) {
        try result.appendSlice(allocator, "## Available Tools\n\nUse these exact tool names in your tool_calls:\n\n");
        for (tools) |tool| {
            try result.appendSlice(allocator, "- **");
            try result.appendSlice(allocator, tool.function.name);
            try result.appendSlice(allocator, "**: ");
            try result.appendSlice(allocator, tool.function.description);
            try result.appendSlice(allocator, "\n");
        }
        try result.appendSlice(allocator, "\n\n");
    }

    // 6. Working directory context
    if (cwd.len > 0) {
        try result.appendSlice(allocator, "**Current working directory:** ");
        try result.appendSlice(allocator, cwd);
        try result.appendSlice(allocator, "\n\n**Tree Directory:**\n");
        try result.appendSlice(allocator, treeDir);
    }

    // 7. OS info
    const os_name = getCurrentOs();
    try result.appendSlice(allocator, "\n\n**Operating System:** ");
    try result.appendSlice(allocator, os_name);
    try result.appendSlice(allocator, "\n\n**Important:** Always use OS-specific commands. Check the current OS before running system commands or shell scripts.");

    return result.toOwnedSlice(allocator);
}

/// Build main agent prompt with all components combined
pub fn build_agent_prompt(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    treeDir: []const u8,
    skillsContent: []const u8,
    memoryMd: []const u8,
    backgroundProcessContent: []const u8,
    agent: []const u8,
    tools: []const tool_models.AgentTool,
    activity_info: []const u8,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // 1. Base rules
    try result.appendSlice(allocator, UniversalRules);
    try result.appendSlice(allocator, "\n\n");

    // 2. ✅ MOVED UP: Prompt auto-fix (CRITICAL - must be early!)
    try result.appendSlice(allocator, PromptAutoFix);
    try result.appendSlice(allocator, "\n\n");

    // 3. Response formatting - markdown and thinking
    try result.appendSlice(allocator, ResponseFormatting);
    try result.appendSlice(allocator, "\n\n");

    // 4. ✅ MANDATORY: Update activity after every response
    try result.appendSlice(allocator, UpdateActivityRule);
    try result.appendSlice(allocator, "\n\n");

    // 4. Main agent directive (IMPORTANT - agent needs context before anything else)
    try result.appendSlice(allocator, Agent);
    try result.appendSlice(allocator, "\n\n");

    // 5. ✅ CONSOLIDATED: Parallel work rules (was duplicated 5x, now once)
    try result.appendSlice(allocator, ParallelWork);
    try result.appendSlice(allocator, "\n\n");

    // 6. Tool-First Approach + Research triggers
    try result.appendSlice(allocator, Research);
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, ResearchTriggers);
    try result.appendSlice(allocator, "\n\n");

    // 7. Dynamic Properties - encourage on-demand property changes
    // Only include if set_agent_properties tool is enabled
    const has_set_agent_properties = for (tools) |tool| {
        if (std.mem.eql(u8, tool.function.name, "set_agent_properties")) {
            break true;
        }
    } else false;
    if (has_set_agent_properties) {
        try result.appendSlice(allocator, DynamicProperties);
        try result.appendSlice(allocator, "\n\n");
    }

    // 8. Classification + Plan + TDD + Execution
    try result.appendSlice(allocator, Classification);
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, PlanBlock);
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, TDD);
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, Execution);
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, Escalation);
    try result.appendSlice(allocator, "\n\n");

    // 9. ✅ MOVED: Skills section (after agent knows context)
    try result.appendSlice(allocator, SkillsUsage);
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, SkillsTriggers);
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, GitPrompt);
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, ProceduralMemory);
    try result.appendSlice(allocator, "\n\n");

    // 10. Skills list (dynamic)
    const skills_json = try list_skills.execute_list_skills(allocator);
    defer allocator.free(skills_json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, skills_json, .{});
    defer parsed.deinit();

    const skills_array = parsed.value.object.get("skills");
    if (skills_array) |arr| {
        try result.appendSlice(allocator, "\n\n<available_skills>\n");
        if (arr.array.items.len == 0) {
            try result.appendSlice(allocator, "No skills available.\n");
        } else {
            for (arr.array.items) |skill| {
                const name = skill.object.get("name") orelse continue;
                const description = skill.object.get("description") orelse continue;
                if (name == .string and description == .string) {
                    try result.appendSlice(allocator, "- **");
                    try result.appendSlice(allocator, name.string);
                    try result.appendSlice(allocator, "**: ");
                    try result.appendSlice(allocator, description.string);
                    try result.appendSlice(allocator, "\n");
                }
            }
        }
        try result.appendSlice(allocator, "\nCall `get_skill(\"skill_name\")` to load full skill content.\n</available_skills>");
    }

    // 11. Custom skills content + Memory markdown
    if (skillsContent.len > 0) {
        try result.appendSlice(allocator, "\n\n");
        try result.appendSlice(allocator, skillsContent);
    }
    if (memoryMd.len > 0) {
        try result.appendSlice(allocator, "\n\n");
        try result.appendSlice(allocator, memoryMd);
    }

    // Dynamic tool listing - enumerate actual tools available
    if (tools.len > 0) {
        try result.appendSlice(allocator, "\n\n## Available Tools\n\nUse these exact tool names in your tool_calls:\n\n");
        for (tools) |tool| {
            try result.appendSlice(allocator, "- **");
            try result.appendSlice(allocator, tool.function.name);
            try result.appendSlice(allocator, "**: ");
            try result.appendSlice(allocator, tool.function.description);
            try result.appendSlice(allocator, "\n");
        }
    }

    // File editing rules - CRITICAL, follow the workflow!
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, FileEditingRules);

    // Change agent rules
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, ChangeAgent);

    // Specialization table
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, SpecializationTable);

    // Dynamic agents
    const agents_list = agents.listAgents(allocator);
    defer agents.freeAgentsList(allocator, agents_list);

    if (agents_list.len > 0) {
        try result.appendSlice(allocator, "\n\n## Available Dynamic Agents\n\n");
        for (agents_list) |info| {
            try result.appendSlice(allocator, "- **");
            try result.appendSlice(allocator, info.name);
            try result.appendSlice(allocator, "**: ");
            try result.appendSlice(allocator, info.description);
            try result.appendSlice(allocator, "\n");
        }
    }

    // Working directory context
    if (cwd.len > 0) {
        try result.appendSlice(allocator, "\n\n**Current working directory:** ");
        try result.appendSlice(allocator, cwd);
        try result.appendSlice(allocator, "\n\n**Tree Directory:**\n");
        try result.appendSlice(allocator, treeDir);
    }

    // OS info
    const os_name = getCurrentOs();
    try result.appendSlice(allocator, "\n\n**Operating System:** ");
    try result.appendSlice(allocator, os_name);
    try result.appendSlice(allocator, "\n\n**Important:** Always use OS-specific commands. Check the current OS before running system commands or shell scripts.");

    // Background process info
    if (backgroundProcessContent.len > 0) {
        try result.appendSlice(allocator, "\n\n");
        try result.appendSlice(allocator, backgroundProcessContent);
    }

    // Active specialized agent
    if (agent.len > 0) {
        try result.appendSlice(allocator, "\n\n## Active Specialized Agent\n\n");
        try result.appendSlice(allocator, agent);
    }

    // Active workers/threads info
    if (activity_info.len > 0) {
        try result.appendSlice(allocator, "\n\n## Active Workers\n\n");
        try result.appendSlice(allocator, activity_info);
        try result.appendSlice(allocator, "\n\n**Note:** These are other agent sessions running in different processes/directories. This information helps you avoid duplicate work or coordinate with other agents if needed. However, each worker operates independently — you have your own separate context and session.");
    }

    return result.toOwnedSlice(allocator);
}
