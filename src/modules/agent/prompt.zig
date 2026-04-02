const std = @import("std");
const list_skills = @import("tools/list_skills.zig");
const agents = @import("tools/agents.zig");
const prompts = @import("prompts/prompts.zig");

// Re-export all prompts for easy access
pub const UniversalRules = prompts.UniversalRules;
pub const PromptAutoFix = prompts.PromptAutoFix;
pub const Agent = prompts.Agent;
pub const ParallelMandatoryIntro = prompts.ParallelMandatoryIntro;
pub const ParallelMandatory = prompts.ParallelMandatory;
pub const ParallelWorkflow = prompts.ParallelWorkflow;
pub const ParallelExamples = prompts.ParallelExamples;
pub const ParallelAntiPatterns = prompts.ParallelAntiPatterns;
pub const ParallelSubAgentGuidance = prompts.ParallelSubAgentGuidance;
pub const ParallelSkillReminder = prompts.ParallelSkillReminder;
pub const Research = prompts.Research;
pub const ResearchTriggers = prompts.ResearchTriggers;
pub const AvailableTools = prompts.AvailableTools;
pub const ChangeAgent = prompts.ChangeAgent;
pub const SpecializationTable = prompts.SpecializationTable;
pub const SubAgentPrompt = prompts.SubAgentPrompt;
pub const SubAgentBrief = prompts.SubAgentBrief;
pub const Classification = prompts.Classification;
pub const Execution = prompts.Execution;
pub const Escalation = prompts.Escalation;
pub const PlanBlock = prompts.PlanBlock;
pub const MemoryPrompt = prompts.MemoryPrompt;
pub const GitPrompt = prompts.GitPrompt;
pub const AgentMdAutoUpdate = prompts.AgentMdAutoUpdate;
pub const TaskManagementPrompt = prompts.TaskManagementPrompt;
pub const CompactionAgent = prompts.CompactionAgent;
pub const DestroyIdea = prompts.DestroyIdea;
pub const SkillsUsage = prompts.SkillsUsage;
pub const SkillsTriggers = prompts.SkillsTriggers;
pub const LoadedSkills = prompts.LoadedSkills;

// Legacy exports for backwards compatibility
pub const BasePrompt = UniversalRules;
pub const AgentsMdPrompt = prompts.MemoryPrompt;

// =============================================================================
// PROMPT BUILDERS
// =============================================================================

/// Build main agent prompt with all components combined
pub fn buildAgentPrompt(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    treeDir: []const u8,
    skillsContent: []const u8,
    memoryMd: []const u8,
    backgroundProcessContent: []const u8,
    agent: []const u8,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // Base rules
    try result.appendSlice(allocator, UniversalRules);
    try result.appendSlice(allocator, "\n\n");

    // ⚡⚡⚡ SKILLS FIRST — Most important section at the top!
    try result.appendSlice(allocator, SkillsUsage);
    try result.appendSlice(allocator, "\n\n");

    // ⚡⚡⚡ SKILL TRIGGERS — When to load skills
    try result.appendSlice(allocator, SkillsTriggers);
    try result.appendSlice(allocator, "\n\n");

    // Memory & tasks
    try result.appendSlice(allocator, MemoryPrompt);
    try result.appendSlice(allocator, "\n\n");

    // Skills list
    const skills_json = try list_skills.executeListSkills(allocator);
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

    // Custom skills content
    if (skillsContent.len > 0) {
        try result.appendSlice(allocator, "\n\n");
        try result.appendSlice(allocator, skillsContent);
    }

    // Memory markdown
    if (memoryMd.len > 0) {
        try result.appendSlice(allocator, "\n\n");
        try result.appendSlice(allocator, memoryMd);
    }

    // Prompt auto-fix
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, PromptAutoFix);

    // Main agent directive
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, Agent);

    // Research
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, Research);

    // Research triggers
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, ResearchTriggers);

    // Classification
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, Classification);

    // Plan block
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, PlanBlock);

    // Execution
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, Execution);

    // Escalation
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, Escalation);

    // Available tools
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, AvailableTools);

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

    return result.toOwnedSlice(allocator);
}

test {
    _ = @import("prompt_change_agent_test.zig");
}
