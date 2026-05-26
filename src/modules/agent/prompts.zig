const std = @import("std");
const builtin = @import("builtin");
const list_skills = @import("tools/list_skills.zig");
const agents = @import("tools/agents.zig");
const prompts = @import("prompts/prompts.zig");
const tool_models = @import("nalarcore").tool_models;
const memory_prompts = @import("prompts/memory.zig");

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
pub const ParallelWork = prompts.ParallelWork;
pub const Research = prompts.Research;
pub const DynamicAdaptation = prompts.DynamicAdaptation;
pub const ResearchTriggers = prompts.ResearchTriggers;
pub const FileEditingRules = prompts.FileEditingRules;
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
pub const NalarMdAutoUpdate = prompts.NalarMdAutoUpdate;
pub const GitPrompt = prompts.GitPrompt;
pub const CompactionAgent = prompts.CompactionAgent;
pub const GenerateSessionNameAgent = prompts.GenerateSessionNameAgent;
pub const SkillsUsage = prompts.SkillsUsage;
pub const SkillsTriggers = prompts.SkillsTriggers;
pub const ProceduralMemory = prompts.ProceduralMemory;
pub const ResponseFormatting = prompts.ResponseFormatting;
pub const UpdateActivityRule = prompts.UpdateActivityRule;

pub const ThinkBeforeCoding = prompts.ThinkBeforeCoding;
pub const SimplicityFirst = prompts.SimplicityFirst;
pub const SurgicalChanges = prompts.SurgicalChanges;
pub const GoalDrivenExecution = prompts.GoalDrivenExecution;
pub const SuccessCriteria = prompts.SuccessCriteria;
pub const AntiPatterns = prompts.AntiPatterns;
pub const GuidelinesSummary = prompts.GuidelinesSummary;

// Agentic Coding enhancements
pub const AutonomousBehavior = prompts.AutonomousBehavior;
pub const DeepResearch = prompts.DeepResearch;
pub const QualityGates = prompts.QualityGates;
pub const ErrorRecovery = prompts.ErrorRecovery;
pub const ToolChaining = prompts.ToolChaining;
pub const ContextAwareness = prompts.ContextAwareness;
pub const ProactiveLearning = prompts.ProactiveLearning;
pub const DecisionFramework = prompts.DecisionFramework;
pub const AggressiveDelegation = prompts.AggressiveDelegation;
pub const IterationMindset = prompts.IterationMindset;
pub const SafetyFirst = prompts.SafetyFirst;

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
    io: std.Io,
    cwd: []const u8,
    treeDir: []const u8,
    skillsContent: []const u8,
    memoryMd: []const u8,
    backgroundProcessContent: []const u8,
    agent: []const u8,
    tools: []const tool_models.AgentTool,
    activity_info: []const u8,
) ![]const u8 {
    _ = io;
    _ = tools;
    _ = treeDir;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // Helper to append section with newline separator
    const appendSection = struct {
        fn func(a: std.mem.Allocator, r: *std.ArrayList(u8), section: []const u8) !void {
            if (section.len > 0) {
                try r.appendSlice(a, "\n\n");
                try r.appendSlice(a, section);
            }
        }
    }.func;

    // 1. Base rules - safety and universal guidelines
    try result.appendSlice(allocator, UniversalRules);
    try appendSection(allocator, &result, PromptAutoFix);

    // 2. ✅ Agent directive EARLY - agent needs context before anything else
    try appendSection(allocator, &result, Agent);

    // 3. Skills system prompt -> self learning skills
    try appendSection(allocator, &result, memory_prompts.skills_system_prompt);

    // 3. Core execution guidelines
    try appendSection(allocator, &result, ThinkBeforeCoding);
    try appendSection(allocator, &result, SimplicityFirst);
    try appendSection(allocator, &result, SurgicalChanges);
    try appendSection(allocator, &result, GoalDrivenExecution);
    try appendSection(allocator, &result, SuccessCriteria);
    try appendSection(allocator, &result, AntiPatterns);
    try appendSection(allocator, &result, GuidelinesSummary);

    // 4. Agentic Coding enhancements (autonomous, proactive, quality-focused)
    try appendSection(allocator, &result, AutonomousBehavior);
    try appendSection(allocator, &result, DeepResearch);
    try appendSection(allocator, &result, QualityGates);
    try appendSection(allocator, &result, ErrorRecovery);
    // try appendSection(allocator, &result, ToolChaining);
    try appendSection(allocator, &result, ContextAwareness);
    try appendSection(allocator, &result, ProactiveLearning);
    try appendSection(allocator, &result, DecisionFramework);
    // try appendSection(allocator, &result, AggressiveDelegation);
    try appendSection(allocator, &result, IterationMindset);
    try appendSection(allocator, &result, SafetyFirst);

    // 5. Response formatting - markdown and thinking
    try appendSection(allocator, &result, ResponseFormatting);

    // 6. MANDATORY: Update activity after every response
    try appendSection(allocator, &result, UpdateActivityRule);

    // 7. CONSOLIDATED: Parallel work rules (single source of truth)
    // try appendSection(allocator, &result, ParallelWork);

    // 8. Tool-First Approach + Research triggers
    // try appendSection(allocator, &result, Research);
    // try appendSection(allocator, &result, ResearchTriggers);
    // try appendSection(allocator, &result, DynamicAdaptation);

    // 9. Dynamic Properties - only if set_agent_properties tool is available
    // const has_set_agent_properties = for (tools) |tool| {
    //     if (std.mem.eql(u8, tool.function.name, "set_agent_properties")) {
    //         break true;
    //     }
    // } else false;
    // if (has_set_agent_properties) {
    //     try appendSection(allocator, &result, DynamicProperties);
    // }

    // 10. Classification + Plan + TDD + Execution
    // try appendSection(allocator, &result, Classification);
    // try appendSection(allocator, &result, PlanBlock);
    // try appendSection(allocator, &result, TDD);
    // try appendSection(allocator, &result, Execution);
    // try appendSection(allocator, &result, Escalation);

    // 11. Skills + Memory section (agent knows context by now)
    // try appendSection(allocator, &result, SkillsUsage);
    // try appendSection(allocator, &result, SkillsTriggers);
    // try appendSection(allocator, &result, MemoryPrompt);
    try appendSection(allocator, &result, NalarMdAutoUpdate);
    try appendSection(allocator, &result, GitPrompt);
    // try appendSection(allocator, &result, ProceduralMemory);

    // 13. Custom skills content + Memory markdown
    if (skillsContent.len > 0) {
        try result.appendSlice(allocator, "\n\n");
        try result.appendSlice(allocator, skillsContent);
    }
    if (memoryMd.len > 0) {
        try result.appendSlice(allocator, "\n\n");
        try result.appendSlice(allocator, memoryMd);
    }

    // 14. Dynamic tool listing
    // try appendToolListing(allocator, &result, tools);

    // 15. File editing rules - CRITICAL, follow the workflow!
    try appendSection(allocator, &result, FileEditingRules);

    // 16. Change agent rules
    try appendSection(allocator, &result, ChangeAgent);

    // 17. Specialization table
    try appendSection(allocator, &result, SpecializationTable);

    // 18. Dynamic agents list
    // {
    //     const agents_list = agents.listAgents(allocator, io);
    //     defer agents.freeAgentsList(allocator, agents_list);
    //
    //     if (agents_list.len > 0) {
    //         try result.appendSlice(allocator, "\n\n## Available Dynamic Agents\n\n");
    //         for (agents_list) |info| {
    //             try result.appendSlice(allocator, "- **");
    //             try result.appendSlice(allocator, info.name);
    //             try result.appendSlice(allocator, "**: ");
    //             try result.appendSlice(allocator, info.description);
    //             try result.appendSlice(allocator, "\n");
    //         }
    //     }
    // }

    // 19. Working directory context
    if (cwd.len > 0) {
        try result.appendSlice(allocator, "\n\n**Current working directory:** ");
        try result.appendSlice(allocator, cwd);
        // try result.appendSlice(allocator, "\n\n**Tree Directory:**\n");
        // try result.appendSlice(allocator, treeDir);
    }

    // 20. OS info
    const os_name = getCurrentOs();
    try result.appendSlice(allocator, "\n\n**Operating System:** ");
    try result.appendSlice(allocator, os_name);
    try result.appendSlice(allocator, "\n\n**Important:** Always use OS-specific commands. Check the current OS before running system commands or shell scripts.");

    // 21. Background process info
    if (backgroundProcessContent.len > 0) {
        try result.appendSlice(allocator, "\n\n");
        try result.appendSlice(allocator, backgroundProcessContent);
    }

    // 22. Active specialized agent
    if (agent.len > 0) {
        try result.appendSlice(allocator, "\n\n## Active Specialized Agent\n\n");
        try result.appendSlice(allocator, agent);
    }

    // 23. Active workers/threads info
    if (activity_info.len > 0) {
        try result.appendSlice(allocator, "\n\n## Active Workers\n\n");
        try result.appendSlice(allocator, activity_info);
        try result.appendSlice(allocator, "\n\n**Note:** These are other agent sessions running in different processes/directories. This information helps you avoid duplicate work or coordinate with other agents if needed. However, each worker operates independently — you have your own separate context and session.");
    }

    return result.toOwnedSlice(allocator);
}

/// Append tool listing to the result ArrayList
fn appendToolListing(allocator: std.mem.Allocator, result: *std.ArrayList(u8), tools: []const tool_models.AgentTool) !void {
    if (tools.len == 0) return;

    const header = "\n\n## Available Tools\n\nUse these exact tool names in your tool_calls:\n\n";
    try result.appendSlice(allocator, header);

    // Limit total tools to prevent allocation overflow
    // const max_tools = 20;
    // const tools_to_process = if (tools.len > max_tools) tools[0..max_tools] else tools;

    for (tools) |tool| {
        std.debug.print("Processing tool: {s}", .{tool.function.name});
        std.debug.print("Tool description: {s}", .{tool.function.description});
        const name = tool.function.name;
        const desc = tool.function.description;

        // Guard against corrupted/uninitialized slices
        if (name.len == 0) {
            std.debug.print("Skipping tool with empty name: {s}", .{name});
            continue;
        }
        if (desc.len == 0) {
            std.debug.print("Skipping tool with empty description: {s}", .{name});
            continue;
        }

        // Skip tools with excessively long names or descriptions to avoid allocation issues
        // if (tool.function.name.len > 64 or tool.function.description.len > 1024) continue;

        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, tool.function.name);
        try result.appendSlice(allocator, "**: ");
        try result.appendSlice(allocator, tool.function.description);
        try result.appendSlice(allocator, "\n");
    }
}
