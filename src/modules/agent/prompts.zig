const std = @import("std");
const builtin = @import("builtin");
const prompts = @import("prompts/prompts.zig");
const memory_prompts = @import("prompts/memory.zig");
const tool_list_skills_mod = @import("tools/list_skills.zig");
const tool_models = @import("Agent.zig");
const tool_memories_mod = @import("tools/memories.zig");

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
pub const Agent = prompts.Agent;
pub const ParallelWork = prompts.ParallelWork;
pub const Classification = prompts.Classification;
pub const Execution = prompts.Execution;
pub const Escalation = prompts.Escalation;
pub const MemoryPrompt = prompts.MemoryPrompt;
pub const NalarMdAutoUpdate = prompts.NalarMdAutoUpdate;
pub const GitPrompt = prompts.GitPrompt;
pub const GlobalMemorySystem = prompts.GlobalMemorySystem;
pub const LocalMemorySystem = prompts.LocalMemorySystem;
pub const CompactionAgent = prompts.CompactionAgent;
pub const GenerateSessionNameAgent = prompts.GenerateSessionNameAgent;
pub const ResponseFormatting = prompts.ResponseFormatting;
pub const UpdateActivityRule = prompts.UpdateActivityRule;
pub const SearchToolRule = prompts.SearchToolRule;

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
    .{ .name = "search_tool_rule", .content = SearchToolRule },
    .{ .name = "agent_directive", .content = Agent },
    .{ .name = "parallel_work", .content = ParallelWork },

    // === Skills system ===
    .{ .name = "skills_system", .content = memory_prompts.skills_system_prompt },

    // === Workflow: classify → plan → execute → escalate ===
    .{ .name = "classification", .content = Classification },
    .{ .name = "execution", .content = Execution },
    .{ .name = "escalation", .content = Escalation },


    // === Memory & docs ===
    .{ .name = "memory_prompt", .content = MemoryPrompt },
    // .{ .name = "nalar_md", .content = NalarMdAutoUpdate },
    .{ .name = "global_memory_system", .content = GlobalMemorySystem },
    .{ .name = "local_memory_system", .content = LocalMemorySystem },
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
// `pub` so the unit test in `prompts_test.zig` can call it directly. The
// function is still internal to the agent module — no external caller in
// the codebase imports it. Visibility widening is the standard Zig
// testability pattern for private helpers.
pub fn loadGlobalKnowledge(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
) ![]u8 {
    const env = environment orelse return allocator.dupe(u8, "");

    const list = tool_memories_mod.listAllMemories(allocator, io, env);
    defer tool_memories_mod.freeMemoriesList(allocator, list);

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
        // Emit the absolute path as a separate code-span line right below
        // the heading so the agent can copy it verbatim into `read_file`,
        // `write_file`, `text_replace`, or `remove_file` without
        // reconstructing it from the basename. Mirrors how
        // `appendSkillsListing` emits `s.path` for each skill.
        try result.appendSlice(allocator, "`");
        try result.appendSlice(allocator, mem.path);
        try result.appendSlice(allocator, "`\n\n");
        try result.appendSlice(allocator, content);
        try result.appendSlice(allocator, "\n\n");
    }

    return result.toOwnedSlice(allocator);
}

/// Load the contents of all memory files in `<cwd>/.nalar/memories/` and
/// concatenate them as a single markdown blob. Mirrors `loadGlobalKnowledge`
/// in shape, error handling, and output format (`### <title> (\`<name>\`)`)
/// so the rendered prompt has visual consistency across both knowledge
/// tiers.
///
/// Returns an empty string (allocated) when:
///   - `cwd` is empty
///   - `<cwd>/.nalar/memories/` does not exist (first-run case)
///   - the directory exists but contains no `.md` files
///
/// Per-file errors (open, read, title extraction) skip the file and
/// continue — never break the prompt. **No cap** on aggregate or per-file
/// size; mirrors `loadGlobalKnowledge`'s trust-the-user policy.
// `pub` so the unit test in `prompts_test.zig` can call it directly.
// Mirrors the `pub` decision on `loadGlobalKnowledge` above.
pub fn loadLocalKnowledge(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) ![]u8 {
    if (cwd.len == 0) return allocator.dupe(u8, "");

    const dir_path = tool_memories_mod.get_local_memories_path_for_dir(allocator, cwd)
        orelse return allocator.dupe(u8, "");
    defer allocator.free(dir_path);

    const list = tool_memories_mod.listMemoriesInDir(allocator, io, dir_path);
    defer tool_memories_mod.freeMemoriesList(allocator, list);

    if (list.len == 0) return allocator.dupe(u8, "");

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (list) |mem| {
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
        // Emit the absolute path as a separate code-span line right below
        // the heading so the agent can copy it verbatim into `read_file`,
        // `write_file`, `text_replace`, or `remove_file` without
        // reconstructing it from the basename. Mirrors how
        // `appendSkillsListing` emits `s.path` for each skill and how
        // `loadGlobalKnowledge` does it above.
        try result.appendSlice(allocator, "`");
        try result.appendSlice(allocator, mem.path);
        try result.appendSlice(allocator, "`\n\n");
        try result.appendSlice(allocator, content);
        try result.appendSlice(allocator, "\n\n");
    }

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
/// working directory, workspace context, OS info, background processes,
/// and active workers.
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
///   - `workspaceContext: []const u8` — pre-rendered "Workspace Context"
///     block (built by `BuildWorkspaceContext` in `build_messages_for_agent_prompt.zig`).
///     Empty string means "session not bound to any workspace task" (section
///     is silently omitted). Rendered between the cwd line and the OS info.
pub fn build_agent_prompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    usedSkills: []const u8,
    memoryMd: []const u8,
    backgroundProcessContent: []const u8,
    activeAgentContent: []const u8,
    tools: []const tool_models.AgentTool,
    activity_info: []const u8,
    environment: ?*const std.process.Environ.Map,
    /// Pre-rendered "Available Sub-Agents" listing, built by
    /// `buildMessages` from the current session's
    /// `selected_profile_model` + the LlmConfig. Empty string
    /// means "no sub-agents configured" (the section is omitted).
    /// See `appendSubAgentsListing` for the rendering format.
    sub_agents_listing: []const u8,
    /// Pre-rendered "Workspace Context" markdown block, built by
    /// `BuildWorkspaceContext(allocator, db, session_id)`. Empty
    /// string means "no workspace context" (session not bound to
    /// any task; the section is silently omitted). The block
    /// already includes its `## Workspace Context` header.
    workspaceContext: []const u8,
    /// Pre-rendered "Kanban Status Tracking" markdown block, built by
    /// `BuildKanbanStatusPrompt(allocator, db, session_id)` in
    /// `build_messages_for_agent_prompt.zig`. Empty string means "the
    /// session is not on a kanban board" (the section is silently
    /// omitted). The block already includes its `## Kanban Status
    /// Tracking` header. Rendered right after the Workspace Context
    /// section so the agent sees "you are on a kanban" framing
    /// before the tool listing.
    kanbanStatusContent: []const u8,
    /// Pre-rendered "Design Canvas" markdown block, built by
    /// `BuildDesignCanvasPrompt(allocator, db, session_id)` in
    /// `build_messages_for_agent_prompt.zig`. Empty string means "the
    /// session is not on a design canvas" (the section is silently
    /// omitted). The block already includes its `## Design Canvas`
    /// header. Rendered right after the Kanban Status Tracking
    /// section so the agent sees the workflow expectations before
    /// the tool listing.
    designStatusContent: []const u8,
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

    // Available sub-agents (from LlmConfig.sub_agents or the
    // active profile's sub_agents). Computed by buildMessages
    // and passed in as a pre-rendered string so this function
    // doesn't need DB access or the LlmConfig singleton. The
    // section is rendered right after the tool listing so the
    // LLM sees what sub-agents it can spawn before deciding to
    // call spawn_sub_agent.
    if (sub_agents_listing.len > 0) {
        try result.appendSlice(allocator, sub_agents_listing);
    }

    // Skills loaded for this session (from session_skills table).
    if (usedSkills.len > 0) {
        try appendSection(allocator, &result, usedSkills);
    }

    // Project memory (NALAR.md / CLAUDE.md from cwd).
    if (memoryMd.len > 0) {
        try appendSection(allocator, &result, memoryMd);
    }

    // Local Knowledge — auto-loaded from <cwd>/.nalar/memories/*.md.
    // Project-specific memories that ship with the codebase. Renders
    // BEFORE Global Knowledge so project context precedes cross-project
    // context ("most specific first" ordering).
    const local_knowledge = try loadLocalKnowledge(allocator, io, cwd);
    defer allocator.free(local_knowledge);
    if (local_knowledge.len > 0) {
        try result.appendSlice(allocator, "\n\n## Local Knowledge\n\n");
        try result.appendSlice(allocator,
            \\The following markdown files are this project's local memory,
            \\auto-loaded from `<cwd>/.nalar/memories/`. Use `read_file` to
            \\load a specific memory on demand. To update, use `write_file`
            \\or `text_replace`; to delete, use `remove_file`.
            \\
        );
        try result.appendSlice(allocator, local_knowledge);
    }

    // need to listing list skills globals and locals
    //
    // Lists every installed skill (global + local) by name and description so
    // the model knows what capabilities are available without having to call
    // `list_skills` first. Gated on the `list_skills` tool being present (if
    // it's gone, the model has no way to refresh the list anyway). Best-effort:
    // any failure inside `listAllSkills` silently omits the section — never
    // breaks the prompt.
    try appendSkillsListing(allocator, &result, tools, cwd, io, environment);

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

    // Workspace context (siblings in the same workspace). Rendered
    // between the cwd line and the OS info so the "you are here"
    // framing flows: cwd → workspace siblings → OS info. The block
    // already includes its `## Workspace Context` header (built by
    // `BuildWorkspaceContext`); we just append it verbatim.
    if (workspaceContext.len > 0) {
        try result.appendSlice(allocator, workspaceContext);
    }

    // Kanban status tracking — instructs the agent to call
    // `kanban_move_task` at status transitions. Rendered right after
    // the Workspace Context section so the agent sees the workflow
    // expectations before the tool listing (where kanban_move_task's
    // argument shape is documented). Block already includes its
    // `## Kanban Status Tracking` header (built by
    // `BuildKanbanStatusPrompt`); we just append it verbatim.
    if (kanbanStatusContent.len > 0) {
        try result.appendSlice(allocator, kanbanStatusContent);
    }

    // Design canvas status block (v6 — 3 LLM tools:
    // set_design_page, add_element, update_element). Built by
    // BuildDesignCanvasPrompt. Empty = "session is not on a design
    // canvas" (silently omitted). Rendered right after the Kanban
    // Status Tracking block; both share the same "before the tool
    // listing" ordering so the LLM sees the workflow expectations
    // before reading the tool schemas.
    if (designStatusContent.len > 0) {
        try result.appendSlice(allocator, designStatusContent);
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

/// Append a "## Available Skills" section listing every installed skill
/// (global + local) by name and description. Mirrors `appendToolListing`'s
/// bullet-list style for visual consistency.
///
/// Behavior:
///   - **Gated on `list_skills` tool** — if the tool isn't in the runtime
///     tool list, the model has no way to refresh the list anyway, so we
///     skip the section. Matches the `requires_tool` pattern used by the
///     static `SkillsUsage` / `SkillsTriggers` sections.
///   - **Best-effort** — any failure inside `listAllSkills` (missing env,
///     IO error, alloc failure) silently omits the section, matching the
///     graceful-degradation spirit of `loadGlobalKnowledge` above.
///   - **Empty case omitted** — if both lists are empty, the section header
///     is not emitted at all (avoids an empty `## Available Skills` block).
///   - **Empty `cwd`** is mapped to `null` so the local lookup falls back to
///     `io`'s cwd instead of resolving a path for the filesystem root.
fn appendSkillsListing(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    tools: []const tool_models.AgentTool,
    cwd: []const u8,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
) !void {
    if (!hasTool(tools, "list_skills")) return;

    const cwd_param: ?[]const u8 = if (cwd.len > 0) cwd else null;

    const data = tool_list_skills_mod.listAllSkills(allocator, io, cwd_param, environment) catch return;
    defer tool_list_skills_mod.freeSkillsListData(allocator, data);

    if (data.global_skills.len == 0 and data.local_skills.len == 0) return;

    try result.appendSlice(allocator, "\n\n## Available Skills\n\n");
    try result.appendSlice(allocator,
        \\The following skills are installed and available for this session.
        \\Use `list_skills` to refresh this view, or `get_skill` / `view_skill`
        \\to load a skill's full instructions. Each entry includes the
        \\**exact file path** — pass it to `get_skill` verbatim as the `path`
        \\argument. Do NOT construct the path from the skill name: Linux is
        \\case-sensitive and the file lives at `<name>/SKILL.MD`, not
        \\`<name>.md`, and `~` is not expanded by the tool.
        \\
    );

    if (data.global_skills.len > 0) {
        try result.appendSlice(allocator, "\n### Global skills (~/.config/nalar/skills/)\n\n");
        for (data.global_skills) |s| {
            try result.appendSlice(allocator, "- **");
            try result.appendSlice(allocator, s.name);
            try result.appendSlice(allocator, "**: ");
            try result.appendSlice(allocator, s.description);
            try result.appendSlice(allocator, " — `");
            try result.appendSlice(allocator, s.path);
            try result.appendSlice(allocator, "`\n");
        }
    }

    if (data.local_skills.len > 0) {
        try result.appendSlice(allocator, "\n### Local skills (.nalar/skills/)\n\n");
        for (data.local_skills) |s| {
            try result.appendSlice(allocator, "- **");
            try result.appendSlice(allocator, s.name);
            try result.appendSlice(allocator, "**: ");
            try result.appendSlice(allocator, s.description);
            try result.appendSlice(allocator, " — `");
            try result.appendSlice(allocator, s.path);
            try result.appendSlice(allocator, "`\n");
        }
    }
}

// ---------------------------------------------------------------------------
// Available Sub-Agents listing
// ---------------------------------------------------------------------------

/// One row of the sub-agents listing. Borrowed slices from the
/// `SubAgentConfig` entry — they live as long as the parent
/// `LlmConfig`. Computed by the caller (typically
/// `buildMessages`); `appendSubAgentsListing` just renders the
/// rows passed to it.
pub const SubAgentListingRow = struct {
    name: []const u8,
    model: []const u8,
    /// First N chars of the sub-agent's `system_prompt`, used as
    /// a one-line description in the listing. Empty when the
    /// sub-agent has no system_prompt. Caller should pre-truncate
    /// (e.g. to 80 chars) to keep the prompt lean.
    description: []const u8,
    /// `""` for top-level, or the profile name when the row
    /// came from a profile's `sub_agents`. Used for the source
    /// suffix in the listing.
    source: []const u8,
};

/// Append a "## Available Sub-Agents" section to the result
/// ArrayList. Mirrors `appendToolListing` / `appendSkillsListing`
/// in shape (markdown bullet list with a header that gates on
/// `spawn_sub_agent` being present in the tool list — the section
/// is only useful when the LLM can actually call it).
///
/// Format:
/// ```
/// ## Available Sub-Agents
///
/// You can use `spawn_sub_agent` with one of these `agent_name` values:
///
/// - **code-reviewer** — model: `gpt-4o` — "You are a strict code reviewer..."
/// - **frontend-helper** — model: `claude-3.5-sonnet` — "You are a frontend..."
///
/// (Loaded from the `sub_agents` array in `~/.config/nalar/config.json`.
/// With a profile selected, the profile's sub_agents list is used;
/// otherwise the top-level list is used.)
/// ```
///
/// No-op when `rows.len == 0` so callers can pass an empty slice
/// to mean "no sub-agents configured" (matches the convention used
/// by `appendToolListing` for empty tool lists).
pub fn appendSubAgentsListing(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    rows: []const SubAgentListingRow,
) !void {
    if (rows.len == 0) return;

    try result.appendSlice(allocator,
        \\## Available Sub-Agents
        \\
        \\You can use the `spawn_sub_agent` tool with one of these
        \\`agent_name` values to delegate the task to a pre-configured
        \\specialized sub-agent:
        \\
    );

    for (rows) |row| {
        // Skip rows with empty name (defensive — should never
        // happen since the LlmConfig rejects empty names at
        // load time, but be tolerant).
        if (row.name.len == 0) continue;
        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, row.name);
        try result.appendSlice(allocator, "**");
        if (row.model.len > 0) {
            try result.appendSlice(allocator, " (model: `");
            try result.appendSlice(allocator, row.model);
            try result.appendSlice(allocator, "`)");
        }
        if (row.description.len > 0) {
            try result.appendSlice(allocator, " — \"");
            try result.appendSlice(allocator, row.description);
            try result.appendSlice(allocator, "\"");
        }
        if (row.source.len > 0) {
            try result.appendSlice(allocator, " _(from profile `");
            try result.appendSlice(allocator, row.source);
            try result.appendSlice(allocator, "`)_");
        }
        try result.appendSlice(allocator, "\n");
    }

    try result.appendSlice(allocator,
        \\
        \\Loaded from the `sub_agents` array in `~/.config/nalar/config.json`.
        \\With a profile selected, the profile's `sub_agents` list is
        \\used; otherwise the top-level list is used.
        \\
    );
}
