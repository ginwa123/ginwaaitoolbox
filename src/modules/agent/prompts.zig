const std = @import("std");
const builtin = @import("builtin");
const prompts = @import("prompts/prompts.zig");
const tool_models = @import("nalarcore").tool_models;
const memory_prompts = @import("prompts/memory.zig");
const browsing = @import("prompts/browsing.zig");
const memories_mod = @import("nalarcore").memories;

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
pub const GlobalMemorySystem = prompts.GlobalMemorySystem;
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
pub const CloakBrowserPrompt = browsing.CloakBrowserPrompt;

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

/// Append a section to the result with a leading "\n\n" separator.
/// Skips empty sections.
const appendSection = struct {
    fn func(a: std.mem.Allocator, r: *std.ArrayList(u8), section: []const u8) !void {
        if (section.len > 0) {
            try r.appendSlice(a, "\n\n");
            try r.appendSlice(a, section);
        }
    }
}.func;

/// A single prompt section in the main agent's system prompt.
///
/// `requires_tool` is an optional gate: if set, the section is only rendered
/// when a tool with that exact name is present in the runtime tool list.
/// This lets us ship section content (e.g. `set_agent_properties` guide)
/// without making it visible to agents that lack the tool.
const PromptSection = struct {
    name: []const u8,
    content: []const u8,
    requires_tool: ?[]const u8 = null,
};

/// Single source of truth for which prompt sections the main agent receives.
///
/// Order is meaningful: prompts earlier in the array are read first by the
/// model. The narrative is intentionally structured as:
///   1. LEAD — Orchestrator narrative (Philosophy B: spawn, delegate, orchestrate)
///   2. Skills system (so the agent knows about skills before being told workflows)
///   3. Tooling & research (how to use the tools)
///   4. Workflow (classify → plan → execute → escalate)
///   5. SECONDARY — "When you do work yourself" (Philosophy A: careful, surgical)
///   6. Memory & docs (project state)
///   7. Response formatting (applies to everything above)
///
/// To add/remove/reorder a section, edit this list — that's the only place
/// that needs to change. (For "I want the DynamicProperties section back
/// unconditionally" → just remove the `requires_tool` field.)
const PROMPT_SECTIONS: []const PromptSection = &.{
    // === LEAD: Orchestrator narrative (Philosophy B) ===
    .{ .name = "universal_rules", .content = UniversalRules },
    .{ .name = "prompt_auto_fix", .content = PromptAutoFix },
    .{ .name = "agent_directive", .content = Agent },
    .{ .name = "parallel_work", .content = ParallelWork },
    .{ .name = "autonomous_behavior", .content = AutonomousBehavior },
    .{ .name = "change_agent", .content = ChangeAgent },
    .{ .name = "specialization_table", .content = SpecializationTable },
    .{ .name = "aggressive_delegation", .content = AggressiveDelegation },
    .{ .name = "tool_chaining", .content = ToolChaining },

    // === Skills system ===
    .{ .name = "skills_system", .content = memory_prompts.skills_system_prompt },
    .{ .name = "skills_usage", .content = SkillsUsage },
    .{ .name = "skills_triggers", .content = SkillsTriggers },
    .{ .name = "procedural_memory", .content = ProceduralMemory },

    // === Tooling & research ===
    .{ .name = "research", .content = Research },
    .{ .name = "research_triggers", .content = ResearchTriggers },
    .{ .name = "deep_research", .content = DeepResearch },
    .{ .name = "file_editing", .content = FileEditingRules },
    .{ .name = "dynamic_properties", .content = DynamicProperties, .requires_tool = "set_agent_properties" },
    .{ .name = "cloakbrowser", .content = CloakBrowserPrompt, .requires_tool = "browse" },

    // === Workflow: classify → plan → execute → escalate ===
    .{ .name = "classification", .content = Classification },
    .{ .name = "plan_block", .content = PlanBlock },
    .{ .name = "tdd", .content = TDD },
    .{ .name = "execution", .content = Execution },
    .{ .name = "escalation", .content = Escalation },

    // === SECONDARY: When you do work yourself (Philosophy A) ===
    // Demoted behind the orchestrator narrative. These still apply when
    // the agent (or a sub-agent it spawns) actually writes code, but the
    // *default* posture is: "delegate this to a sub-agent who will follow
    // these rules", not "do it yourself and follow these rules."
    // .{ .name = "think_before_coding", .content = ThinkBeforeCoding },
    // .{ .name = "simplicity_first", .content = SimplicityFirst },
    // .{ .name = "surgical_changes", .content = SurgicalChanges },
    // .{ .name = "goal_driven", .content = GoalDrivenExecution },
    // .{ .name = "success_criteria", .content = SuccessCriteria },
    // .{ .name = "anti_patterns", .content = AntiPatterns },
    // .{ .name = "decision_framework", .content = DecisionFramework },
    // .{ .name = "quality_gates", .content = QualityGates },
    // .{ .name = "error_recovery", .content = ErrorRecovery },
    // .{ .name = "context_awareness", .content = ContextAwareness },
    // .{ .name = "proactive_learning", .content = ProactiveLearning },
    // .{ .name = "iteration_mindset", .content = IterationMindset },
    // .{ .name = "safety_first", .content = SafetyFirst },

    // === Memory & docs ===
    .{ .name = "memory_prompt", .content = MemoryPrompt },
    .{ .name = "nalar_md", .content = NalarMdAutoUpdate },
    .{ .name = "global_memory_system", .content = GlobalMemorySystem, .requires_tool = "list_memory" },
    .{ .name = "git_prompt", .content = GitPrompt },

    // === Response formatting (last — applies to everything above) ===
    .{ .name = "response_formatting", .content = ResponseFormatting },
    .{ .name = "update_activity", .content = UpdateActivityRule },
};

/// Check if a tool with the given name is present in the runtime tool list.
fn hasTool(tools: []const tool_models.AgentTool, name: []const u8) bool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.function.name, name)) return true;
    }
    return false;
}

/// Load the contents of all memory files in `~/.config/nalar/memories/` and
/// concatenate them as a single markdown blob. Each file is prefixed with a
/// `### <title>` heading derived from `MemoryInfo.title`.
///
/// Returns an empty string (allocated) when:
///   - environment is null
///   - the memories folder does not exist
///   - no `.md` files exist
///
/// **No cap — neither aggregate nor per-file.** Every memory that the
/// `listAllMemories` walk discovers is loaded in full. The de facto limit
/// is the LLM's context window (e.g. 200K tokens for the default model) —
/// if total memory content exceeds that, the LLM call will fail and the
/// user must trim. We trust users to keep their memories reasonable in
/// size.
fn loadGlobalKnowledge(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
) ![]u8 {
    const env = environment orelse return allocator.dupe(u8, "");

    const list = memories_mod.listAllMemories(allocator, io, env);
    defer memories_mod.freeMemoriesList(allocator, list);

    if (list.len == 0) return allocator.dupe(u8, "");

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (list) |mem| {
        // Read the full file — no per-file cap. Pattern matches read_file.zig
        // and get_skill.zig which also use maxInt(usize) to mean "read all".
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            mem.path,
            allocator,
            std.Io.Limit.limited(std.math.maxInt(usize)),
        ) catch continue;
        defer allocator.free(content);

        try result.appendSlice(allocator, "### ");
        try result.appendSlice(allocator, mem.title);
        try result.appendSlice(allocator, " (`");
        try result.appendSlice(allocator, mem.name);
        try result.appendSlice(allocator, "`)\n\n");
        try result.appendSlice(allocator, content);
        try result.appendSlice(allocator, "\n\n");
    }

    return result.toOwnedSlice(allocator);
}

/// Build sub-agent prompt with a focused, minimal set of rules
/// Sub-agents get a simple, research-focused prompt (NOT the full main agent prompt)
///
/// **New parameters (vs. previous version):**
///   - `io: std.Io` — required to read memory files for the auto-loaded
///     "Global Knowledge" section.
///   - `environment: ?*const std.process.Environ.Map` — required to resolve
///     the global memories path (XDG-aware: $XDG_CONFIG_HOME or $HOME).
///     When null, the Global Knowledge section is omitted.
pub fn build_sub_agent_prompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    treeDir: []const u8,
    task_brief: []const u8,
    tools: []const tool_models.AgentTool,
    environment: ?*const std.process.Environ.Map,
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

    // 6. Global Knowledge — auto-loaded from ~/.config/nalar/memories/*.md.
    //    Each memory becomes a `### <title>` subsection. Total content is
    //    capped at MAX_GLOBAL_KNOWLEDGE_BYTES to prevent prompt bloat; if
    //    truncated, a note tells the agent to use `list_memory` to see the rest.
    const knowledge = try loadGlobalKnowledge(allocator, io, environment);
    defer allocator.free(knowledge);
    if (knowledge.len > 0) {
        try result.appendSlice(allocator, "## Global Knowledge\n\n");
        try result.appendSlice(allocator,
            \\The following markdown files are your persistent global memory,
            \\auto-loaded from `~/.config/nalar/memories/`. Use `list_memory` to
            \\see metadata (and any files truncated below the budget). Use
            \\`read_file` to load a specific memory on demand. To update a
            \\memory, use `write_file` or `text_replace`; to delete, use
            \\`remove_file`.
            \\
        );
        try result.appendSlice(allocator, knowledge);
        try result.appendSlice(allocator, "\n\n");
    }

    // 7. Working directory context
    if (cwd.len > 0) {
        try result.appendSlice(allocator, "**Current working directory:** ");
        try result.appendSlice(allocator, cwd);
        try result.appendSlice(allocator, "\n\n**Tree Directory:**\n");
        try result.appendSlice(allocator, treeDir);
    }

    // 8. OS info
    const os_name = getCurrentOs();
    try result.appendSlice(allocator, "\n\n**Operating System:** ");
    try result.appendSlice(allocator, os_name);
    try result.appendSlice(allocator, "\n\n**Important:** Always use OS-specific commands. Check the current OS before running system commands or shell scripts.");

    return result.toOwnedSlice(allocator);
}

/// Build main agent prompt with all components combined.
///
/// Prompt construction is data-driven via `PROMPT_SECTIONS`. To change
/// what the agent sees, edit that list — don't touch this function.
///
/// Sections are rendered in declaration order. Each section may be
/// conditionally gated on a tool being present (`requires_tool`).
///
/// After the static sections, the function appends dynamic session state:
/// loaded skills, project memory, global knowledge (memories from
/// `~/.config/nalar/memories/`), tool listing, active agent configuration,
/// working directory, OS info, background processes, and active workers.
///
/// **Removed parameters (vs. previous version):**
///   - `io: std.Io` — never used; callers no longer need to thread an `io` instance.
///   - `treeDir: []const u8` — was a dead parameter (caller always passed `""`).
/// **Renamed parameters:**
///   - `agent` → `activeAgentContent` (avoids shadowing the `agents` namespace).
/// **New parameters:**
///   - `io: std.Io` — required to read memory files for the auto-loaded
///     "Global Knowledge" section.
///   - `environment: ?*const std.process.Environ.Map` — required to resolve
///     the global memories path (XDG-aware: $XDG_CONFIG_HOME or $HOME).
///     When null, the Global Knowledge section is omitted.
pub fn build_agent_prompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    skillsContent: []const u8,
    memoryMd: []const u8,
    backgroundProcessContent: []const u8,
    activeAgentContent: []const u8,
    tools: []const tool_models.AgentTool,
    activity_info: []const u8,
    environment: ?*const std.process.Environ.Map,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // === 1. Static sections (data-driven) ===
    for (PROMPT_SECTIONS) |section| {
        if (section.requires_tool) |tool_name| {
            if (!hasTool(tools, tool_name)) continue;
        }
        try appendSection(allocator, &result, section.content);
    }

    // === 2. Dynamic: session-specific content ===

    // Skills loaded for this session (from session_skills table).
    if (skillsContent.len > 0) {
        try appendSection(allocator, &result, skillsContent);
    }

    // Project memory (NALAR.md / CLAUDE.md from cwd).
    if (memoryMd.len > 0) {
        try appendSection(allocator, &result, memoryMd);
    }

    // Global Knowledge — auto-loaded from ~/.config/nalar/memories/*.md.
    // Same loader and 50KB budget as build_sub_agent_prompt. The
    // GlobalMemorySystem static section above already told the model this
    // content is coming; here is where the actual content gets injected.
    const knowledge = try loadGlobalKnowledge(allocator, io, environment);
    defer allocator.free(knowledge);
    if (knowledge.len > 0) {
        try result.appendSlice(allocator, "\n\n## Global Knowledge\n\n");
        try result.appendSlice(allocator,
            \\The following markdown files are your persistent global memory,
            \\auto-loaded from `~/.config/nalar/memories/`. Use `list_memory` to
            \\see metadata (and any files truncated below the budget).
        );
        try result.appendSlice(allocator, knowledge);
    }

    // Tool listing — gives the model semantic context for each tool
    // (names + descriptions), not just the JSON schema the API already sends.
    // Critical for tool selection: without this, the model picks tools based
    // on name-embedding similarity alone, which is unreliable.
    try appendToolListing(allocator, &result, tools);

    // Active specialized agent — frames the session's current agent config.
    if (activeAgentContent.len > 0) {
        try result.appendSlice(allocator, "\n\n## Your Active Agent Configuration\n\n");
        try result.appendSlice(allocator,
            \\You are currently configured as the following specialized agent.
            \\Its instructions, capabilities, and constraints apply to you for
            \\this session. When in doubt, defer to the agent configuration below.
            \\
        );
        try result.appendSlice(allocator, activeAgentContent);
    }

    // Working directory.
    if (cwd.len > 0) {
        try result.appendSlice(allocator, "\n\n**Current working directory:** ");
        try result.appendSlice(allocator, cwd);
    }

    // OS info.
    const os_name = getCurrentOs();
    try result.appendSlice(allocator, "\n\n**Operating System:** ");
    try result.appendSlice(allocator, os_name);
    try result.appendSlice(allocator,
        \\**Important:** Always use OS-specific commands. Check the current OS
        \\before running system commands or shell scripts.
    );

    // Background processes for this session.
    if (backgroundProcessContent.len > 0) {
        try appendSection(allocator, &result, backgroundProcessContent);
    }

    // Other active workers (sub-agents in other sessions/processes).
    if (activity_info.len > 0) {
        try result.appendSlice(allocator, "\n\n## Active Workers\n\n");
        try result.appendSlice(allocator, activity_info);
        try result.appendSlice(allocator,
            \\**Note:** These are other agent sessions running in different
            \\processes/directories. This information helps you avoid duplicate
            \\work or coordinate with other agents if needed. However, each
            \\worker operates independently — you have your own separate
            \\context and session.
        );
    }

    return result.toOwnedSlice(allocator);
}

/// Append a tool listing to the result ArrayList.
///
/// Renders each tool's name and description so the model has semantic
/// context for tool selection — not just the JSON schema that the API
/// already sends in the request body. This is the single highest-leverage
/// piece of prompt content for tool-use accuracy: without it, the model
/// picks tools based on name-embedding similarity alone, which is unreliable
/// when tool names are short or ambiguous (e.g. `read_file` vs `text_replace`).
fn appendToolListing(allocator: std.mem.Allocator, result: *std.ArrayList(u8), tools: []const tool_models.AgentTool) !void {
    if (tools.len == 0) return;

    const header = "\n\n## Available Tools\n\nUse these exact tool names in your tool_calls:\n\n";
    try result.appendSlice(allocator, header);

    for (tools) |tool| {
        const name = tool.function.name;
        const desc = tool.function.description;

        // Guard against corrupted/uninitialized slices.
        if (name.len == 0) continue;
        if (desc.len == 0) continue;

        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, name);
        try result.appendSlice(allocator, "**: ");
        try result.appendSlice(allocator, desc);
        try result.appendSlice(allocator, "\n");
    }
}
