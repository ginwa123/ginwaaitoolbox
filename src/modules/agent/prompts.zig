const std = @import("std");
const builtin = @import("builtin");
const prompts = @import("prompts/prompts.zig");
const memory_prompts = @import("prompts/memory.zig");
const tool_list_skills_mod = @import("tools/skill_tools.zig");
const tool_models = @import("Agent.zig");
const tool_memories_mod = @import("tools/memories.zig");

// =============================================================================
// Re-exports only.
//
// As of 2026-08-23 (plan: docs/superpowers/plans/2026-08-23-move-build-agent-prompt-body.md),
// the orchestrator-side prompt assembly file
// (`src/agentic_loop/prompts_build_messages_for_agent_prompt.zig`)
// owns `build_agent_prompt` and every helper it depends on. This file is
// now a thin shim that re-exports the static prompt-template constants
// below; rendering logic lives in the orchestrator file.
// =============================================================================

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
pub const SearchToolRule = prompts.SearchToolRule;
pub const ReadWorkspaceSessionToolRule = prompts.ReadWorkspaceSessionToolRule;
pub const MemoryToolRule = prompts.MemoryToolRule;
// The agent's special tool (search the catalog for the tool a task needs) and
// its special skills (load the skill a task needs). Both are appended
// unconditionally by `buildMessages` — never gated on the tool list, so the
// block stays byte-identical for every agent and the shared prompt-cache
// prefix keeps hitting.
pub const ProgressiveToolRule = prompts.ProgressiveToolRule;
pub const SkillsToolRule = prompts.SkillsToolRule;
// Skill Evals — evaluate the skills this session actually used. Appended
// unconditionally for the same cache reason as the two above; it gates itself
// on `run_skill_eval` being present in the tool list, and that tool is only
// injected when config.json's `skill_evals.enabled` is true. So the switch
// controls the tool, never the prompt bytes.
pub const SkillEvalToolRule = prompts.SkillEvalToolRule;

// ---------------------------------------------------------------------------
// Thin delegating re-exports for the two pure helpers that
// `prompts_test.zig` exercises directly. They now live next to
// `build_agent_prompt` in the orchestrator file (see plan §5.4);
// forwarding here keeps the test surface unchanged.
// ---------------------------------------------------------------------------
pub const loadGlobalKnowledge = @import("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig").loadGlobalKnowledge;
pub const loadLocalKnowledge = @import("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig").loadLocalKnowledge;
pub const SubAgentListingRow = @import("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig").SubAgentListingRow;
pub const appendSubAgentsListing = @import("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig").appendSubAgentsListing;

// ===== Tests merged from prompts_test.zig (2026-09-29 flatten) =====
const prompts_mod = @import("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig");
const AgentTool = tool_models.AgentTool;
const AgentToolFunction = tool_models.AgentToolFunction;
const ToolParameters = tool_models.ToolParameters;
// `tool_models` here is Agent.zig, whose `ToolProperty` alias is private.
// The test builds schemas.AgentTool literals, so reach the real type
// through the schemas module directly.
const ToolProperty = @import("tools/schemas.zig").ToolProperty;

// Helper: substring check
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// Build a minimal AgentTool for use in tests.
fn makeTool(name: []const u8, desc: []const u8) AgentTool {
    return AgentTool{
        .type = "function",
        .function = .{
            .name = name,
            .description = desc,
            .parameters = .{
                .type = "object",
                .properties = &[_]ToolProperty{},
                .required = &[_][]const u8{},
            },
        },
    };
}

// -------------------------------------------------------------------------
// build_agent_prompt — empty / no-memory cases
test "build_agent_prompt loads memory files into Global Knowledge section" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-main-prompt-test";
    const memories_dir = "/tmp/nalar-main-prompt-test/.config/nalar/memories";
    const file_path = "/tmp/nalar-main-prompt-test/.config/nalar/memories/regression-test-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Write a Regression Test First
            \\
            \\After fixing a tricky bug, write a regression test before
            \\touching anything else. Fixes without tests regress.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("list_memory", "List memory files"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        &env,
        "",
        "",
        "", "");
    defer alloc.free(prompt);

    // The Global Knowledge section is present
    try std.testing.expect(contains(prompt, "## Global Knowledge"));
    // The memory file is loaded with its content
    try std.testing.expect(contains(prompt, "regression-test-rule.md"));
    try std.testing.expect(contains(prompt, "Write a Regression Test First"));
    try std.testing.expect(contains(prompt, "Fixes without tests regress"));
}

// build_agent_prompt — Available Skills listing
// -------------------------------------------------------------------------

test "build_agent_prompt omits Available Skills section when list_skills tool is absent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Set up a HOME with a real skill, so the test confirms the GATING,
    // not just the "no skill found" path.
    const tmp_home = "/tmp/nalar-prompt-test-skills-gated";
    const global_skill_dir = "/tmp/nalar-prompt-test-skills-gated/.config/nalar/skills/test-gated-skill";
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, global_skill_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(
            io,
            "/tmp/nalar-prompt-test-skills-gated/.config/nalar/skills/test-gated-skill/SKILL.MD",
            .{},
        );
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: test-gated-skill
            \\description: "Should be hidden when list_skills is absent"
            \\---
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    // Tools list intentionally does NOT include list_skills
    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        &env,
        "",
        "",
        "", "");
    defer alloc.free(prompt);

    try std.testing.expect(!contains(prompt, "## Available Skills"));
    try std.testing.expect(!contains(prompt, "test-gated-skill"));
}

test "build_agent_prompt silently skips Available Skills when env is null" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // list_skills IS in the tools list, but env is null → graceful skip
    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("list_skills", "List available skills"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null, // ← env is null
        "",
        "",
        "", "");
    defer alloc.free(prompt);

    // No section emitted; no error thrown
    try std.testing.expect(!contains(prompt, "## Available Skills"));
}

// build_agent_prompt — Local Knowledge section (<cwd>/.nalar/memories/*.md)
// -------------------------------------------------------------------------

test "build_agent_prompt injects Local Knowledge section from <cwd>/.nalar/memories" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/nalar-prompt-test-local-knowledge";
    const local_dir = "/tmp/nalar-prompt-test-local-knowledge/.nalar/memories";
    const file_path = "/tmp/nalar-prompt-test-local-knowledge/.nalar/memories/project-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, local_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Project Build Rule
            \\
            \\Always run `zig build test:ai_workflow:tui` before declaring a
            \\task done in this repo. Fixes without tests regress.
            \\
        );
    }

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        tmp_cwd,
        "",
        "",
        "",
        "",
        &tools,
        "",
        null, // env is null — only local knowledge should be present
        "",
        "",
        "", "");
    defer alloc.free(prompt);

    // The section header is present
    try std.testing.expect(contains(prompt, "## Local Knowledge"));
    // Filename appears (in the ### <title> (`<filename>`) heading)
    try std.testing.expect(contains(prompt, "project-rule.md"));
    // H1-derived title appears
    try std.testing.expect(contains(prompt, "Project Build Rule"));
    // Full content appears (not truncated)
    try std.testing.expect(contains(prompt, "Always run `zig build test:ai_workflow:tui`"));
    try std.testing.expect(contains(prompt, "Fixes without tests regress"));
    // Preamble tells the model where the files came from
    try std.testing.expect(contains(prompt, "auto-loaded from `<cwd>/.nalar/memories/`"));
}

// build_agent_prompt — Memory paths are rendered alongside filenames
// -------------------------------------------------------------------------
//
// Every memory entry rendered in the `## Local Knowledge` /
// `## Global Knowledge` sections must include its full absolute path as a
// separate code-span line below the `### <title> (`<filename>`)` heading.
// The agent uses this path verbatim when calling `read_file` /
// `write_file` / `text_replace` / `remove_file` — reconstructing the path
// from the basename alone is brittle (would require the agent to know
// `~/.config/nalar/memories` / `<cwd>/.nalar/memories` exists).

test "build_agent_prompt Global Knowledge section emits each memory's absolute path" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-prompt-test-global-knowledge-path";
    const memories_dir = "/tmp/nalar-prompt-test-global-knowledge-path/.config/nalar/memories";
    const file_path = "/tmp/nalar-prompt-test-global-knowledge-path/.config/nalar/memories/path-test-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Path Emission Test
            \\
            \\Body content for the path-emission regression test.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const tools = [_]AgentTool{
        makeTool("list_memory", "List memory files"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "", "", "", "", &tools, "", &env, "", "", "", "");
    defer alloc.free(prompt);

    // The full absolute path appears in the prompt — copy-pasteable
    // straight into read_file / write_file / text_replace / remove_file.
    try std.testing.expect(contains(prompt, file_path));
    // The path appears inside backticks (Markdown code span), not as a
    // bare string — that's the convention for paths in this prompt.
    try std.testing.expect(contains(prompt, "`" ++ file_path ++ "`"));
    // The heading format is unchanged — the path is a separate line below
    // the `### <title> (`<filename>`)` heading, not part of it.
    try std.testing.expect(contains(prompt, "### Path Emission Test (`path-test-rule.md`)"));
}

test "build_agent_prompt Local Knowledge section emits each memory's absolute path" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/nalar-prompt-test-local-knowledge-path";
    const local_dir = "/tmp/nalar-prompt-test-local-knowledge-path/.nalar/memories";
    const file_path = "/tmp/nalar-prompt-test-local-knowledge-path/.nalar/memories/local-path-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, local_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Local Path Emission Test
            \\
            \\Body content for the local-memory path-emission regression test.
            \\
        );
    }

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        tmp_cwd,
        "", "", "", "", &tools, "", null, "", "", "", "");
    defer alloc.free(prompt);

    // Full absolute path of the local memory, copy-pasteable.
    try std.testing.expect(contains(prompt, file_path));
    // Wrapped in a Markdown code span.
    try std.testing.expect(contains(prompt, "`" ++ file_path ++ "`"));
    // Heading format is unchanged.
    try std.testing.expect(contains(prompt, "### Local Path Emission Test (`local-path-rule.md`)"));
}

test "build_agent_prompt renders Local and Global Knowledge together when both exist" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Set up a HOME with a global memory
    const tmp_home = "/tmp/nalar-prompt-test-local-and-global-home";
    const global_dir = "/tmp/nalar-prompt-test-local-and-global-home/.config/nalar/memories";
    const global_file = "/tmp/nalar-prompt-test-local-and-global-home/.config/nalar/memories/global-rule.md";

    // And a cwd with a local memory
    const tmp_cwd = "/tmp/nalar-prompt-test-local-and-global-cwd";
    const local_dir = "/tmp/nalar-prompt-test-local-and-global-cwd/.nalar/memories";
    const local_file = "/tmp/nalar-prompt-test-local-and-global-cwd/.nalar/memories/local-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
        std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    }

    try std.Io.Dir.cwd().createDirPath(io, global_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, global_file, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Global Cross-Project Rule
            \\
            \\This rule applies to every nalar project.
            \\
        );
    }

    try std.Io.Dir.cwd().createDirPath(io, local_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, local_file, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Local Project Rule
            \\
            \\This rule is specific to this project only.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("list_memory", "List memory files"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        tmp_cwd,
        "",
        "",
        "",
        "",
        &tools,
        "",
        &env,
        "",
        "",
        "", "");
    defer alloc.free(prompt);

    // Both sections are present
    try std.testing.expect(contains(prompt, "## Local Knowledge"));
    try std.testing.expect(contains(prompt, "## Global Knowledge"));
    // Both files appear
    try std.testing.expect(contains(prompt, "local-rule.md"));
    try std.testing.expect(contains(prompt, "Local Project Rule"));
    try std.testing.expect(contains(prompt, "global-rule.md"));
    try std.testing.expect(contains(prompt, "Global Cross-Project Rule"));

    // Local Knowledge appears BEFORE Global Knowledge in the rendered prompt
    // (most-specific-first ordering).
    const local_pos = std.mem.indexOf(u8, prompt, "## Local Knowledge").?;
    const global_pos = std.mem.indexOf(u8, prompt, "## Global Knowledge").?;
    try std.testing.expect(local_pos < global_pos);
}

test "build_agent_prompt omits Local Knowledge when <cwd>/.nalar/memories does not exist" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Use a cwd that has no .nalar/ subdir at all
    const tmp_cwd = "/tmp/nalar-prompt-test-no-local-dir";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    std.Io.Dir.cwd().createDirPath(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        tmp_cwd,
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        "", "");
    defer alloc.free(prompt);

    // No .nalar/memories → no Local Knowledge section
    try std.testing.expect(!contains(prompt, "## Local Knowledge"));
}

test "build_agent_prompt omits Local Knowledge when cwd is empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "", // ← cwd is empty
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        "", "");
    defer alloc.free(prompt);

    // No cwd → no Local Knowledge section
    try std.testing.expect(!contains(prompt, "## Local Knowledge"));
}

// build_agent_prompt — LocalMemorySystem static section (no gating)
// -------------------------------------------------------------------------
//
// The LocalMemorySystem section is static — it appears in every prompt
// regardless of tool list, because the local memory content is auto-injected
// (no `list_memory` invocation needed). Same invariant as GlobalMemorySystem.

test "build_agent_prompt omits Local Knowledge when <cwd>/.nalar/memories has no .md files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/nalar-prompt-test-local-dir-empty";
    const local_dir = "/tmp/nalar-prompt-test-local-dir-empty/.nalar/memories";
    const txt_path = "/tmp/nalar-prompt-test-local-dir-empty/.nalar/memories/notes.txt";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, local_dir);
    // Drop a non-md file
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "not a memory");
    }

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        tmp_cwd,
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        "", "");
    defer alloc.free(prompt);

    // Dir exists but has no .md files → no section
    try std.testing.expect(!contains(prompt, "## Local Knowledge"));
}

// ---------------------------------------------------------------------------
// appendSubAgentsListing — "Available Sub-Agents" section
// ---------------------------------------------------------------------------
//
// PR review: inject the list of sub-agents from LlmConfig into the
// system prompt so the LLM can discover what agent_names to pass
// to spawn_sub_agent. These tests exercise the rendering format
// (the integration with LlmConfig + selected_profile_model is
// covered by manual smoke testing because the LlmConfig singleton
// is hard to set up in a unit test).

test "appendSubAgentsListing: empty rows slice is a no-op" {
    const alloc = std.testing.allocator;

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try appendSubAgentsListing(alloc, &result, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.items.len);
}

test "appendSubAgentsListing: renders a single row with name + model + description" {
    const alloc = std.testing.allocator;

    const rows = [_]SubAgentListingRow{
        .{
            .name = "code-reviewer",
            .model = "gpt-4o",
            .description = "You are a strict code reviewer.",
            .source = "",
        },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try appendSubAgentsListing(alloc, &result, &rows);

    const out = result.items;
    // Header is present.
    try std.testing.expect(contains(out, "## Available Sub-Agents"));
    // Row is rendered with name, model, description.
    try std.testing.expect(contains(out, "**code-reviewer**"));
    try std.testing.expect(contains(out, "model: `gpt-4o`"));
    try std.testing.expect(contains(out, "You are a strict code reviewer."));
    // No source suffix when source is empty.
    try std.testing.expect(!contains(out, "from profile"));
    // Footer explains where the list came from.
    try std.testing.expect(contains(out, "sub_agents"));
    try std.testing.expect(contains(out, "profile"));
}

test "appendSubAgentsListing: per-profile source suffix is shown" {
    const alloc = std.testing.allocator;

    const rows = [_]SubAgentListingRow{
        .{
            .name = "reviewer",
            .model = "gpt-4o",
            .description = "Profile-specific reviewer.",
            .source = "profile1",
        },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try appendSubAgentsListing(alloc, &result, &rows);

    try std.testing.expect(contains(result.items, "from profile `profile1`"));
}

test "appendSubAgentsListing: rows with empty name are skipped (defensive)" {
    const alloc = std.testing.allocator;

    const rows = [_]SubAgentListingRow{
        .{ .name = "", .model = "m", .description = "should be skipped", .source = "" },
        .{ .name = "valid", .model = "m", .description = "should be rendered", .source = "" },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try appendSubAgentsListing(alloc, &result, &rows);

    try std.testing.expect(!contains(result.items, "should be skipped"));
    try std.testing.expect(contains(result.items, "should be rendered"));
    try std.testing.expect(contains(result.items, "**valid**"));
}

test "appendSubAgentsListing: empty model/description still renders the row" {
    const alloc = std.testing.allocator;

    const rows = [_]SubAgentListingRow{
        .{ .name = "minimal", .model = "", .description = "", .source = "" },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try appendSubAgentsListing(alloc, &result, &rows);

    // The name is present but neither the model nor the
    // description is rendered (no "model: \`\`", no em-dash).
    try std.testing.expect(contains(result.items, "**minimal**"));
    try std.testing.expect(!contains(result.items, "model: `"));
    try std.testing.expect(!contains(result.items, " — \""));
}

test "build_agent_prompt with sub_agents_listing: section is omitted when empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "", // empty sub_agents_listing
        "", // empty workspaceContext
        "", // empty kanbanStatusContent
        "", // empty designStatusContent
    );
    defer alloc.free(prompt);

    try std.testing.expect(!contains(prompt, "## Available Sub-Agents"));
}

// ---------------------------------------------------------------------------
// build_agent_prompt with kanbanStatusContent — tests for the
// `## Kanban Status Tracking` section (added by the 2026-06-27
// kanban-status-prompt plan, Chunk 3).
//
// The section is rendered verbatim from the `kanbanStatusContent`
// parameter; an empty string omits the section entirely. The
// renderer (`BuildKanbanStatusPrompt`) is tested separately in
// `build_messages_for_agent_prompt_test.zig` — these tests cover
// the build_agent_prompt integration only (param threading +
// conditional rendering).
// ---------------------------------------------------------------------------

test "build_agent_prompt renders Kanban Status Tracking when section is non-empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    const kanban_block =
        \\## Kanban Status Tracking
        \\
        \\This task is on a kanban board (parent item_type: `kanban`).
        \\**You MUST call the `kanban_move_task` tool at every meaningful
        \\workflow checkpoint** below.
        \\
        \\**Current column:** `todo` (`col_a`)
        \\
        \\**Columns on this board** (in flow order):
        \\- `todo` (`col_a`, position 0)
        \\- `in progress` (`col_b`, position 1)
        \\- `done` (`col_c`, position 2)
        \\
        \\**Status transitions** (call `kanban_move_task`):
        \\- **start** — move from `todo` → `in progress`
        \\- **complete** — move to `done` before your final reply
        \\- **blocked** — do NOT move
    ;
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        kanban_block, "");
    defer alloc.free(prompt);

    try std.testing.expect(contains(prompt, "## Kanban Status Tracking"));
    try std.testing.expect(contains(prompt, "MUST call the `kanban_move_task` tool"));
    try std.testing.expect(contains(prompt, "Current column:** `todo` (`col_a`)"));
    try std.testing.expect(contains(prompt, "- `todo` (`col_a`, position 0)"));
    try std.testing.expect(contains(prompt, "**start**"));
    try std.testing.expect(contains(prompt, "**complete**"));
    try std.testing.expect(contains(prompt, "**blocked**"));
}

test "build_agent_prompt omits Kanban Status Tracking when section is empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "", // empty workspaceContext
        "", // empty kanbanStatusContent
        "", // empty designStatusContent
    );
    defer alloc.free(prompt);

    try std.testing.expect(!contains(prompt, "## Kanban Status Tracking"));
    try std.testing.expect(!contains(prompt, "MUST call the `kanban_move_task`"));
}

// ---------------------------------------------------------------------------
// loadGlobalKnowledge — direct unit tests for the memory-file loader.
//
// The function is `pub` in `prompts.zig` solely for testability from this
// file. The tests below set up a real `Environ.Map` with `HOME` pointing
// at a temp directory under `/tmp/`, create real `.md` files in the
// expected `~/.config/nalar/memories/` subdir, then call
// `loadGlobalKnowledge` directly and assert the returned markdown blob
// matches the documented format:
//
//   ### <title> (`<filename>`)\n\n<full file content>\n\n
//
// Per-file errors (open / read / title extraction) skip the file and
// continue — covered by the "corrupt file is skipped" test.
// ---------------------------------------------------------------------------

test "loadGlobalKnowledge returns empty string when env is null" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const result = try loadGlobalKnowledge(alloc, io, null);
    defer alloc.free(result);

    // Graceful degradation: no error, no content.
    try std.testing.expectEqualStrings("", result);
}

test "loadGlobalKnowledge returns empty string when HOME has no memories subdir" {
    // First-run case: HOME exists but the user has not created
    // ~/.config/nalar/memories/ yet. Must not error, must return "".
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-load-global-knowledge-missing-dir";
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_home);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "loadGlobalKnowledge returns empty string when memories dir exists but is empty" {
    // The dir exists but contains no .md files. Mirrors the first-run
    // contract: no memories → no Global Knowledge content.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-load-global-knowledge-empty-dir";
    const memories_dir = "/tmp/nalar-load-global-knowledge-empty-dir/.config/nalar/memories";
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    // Drop a non-md file to confirm it's ignored, not picked up as a memory.
    const txt_path = "/tmp/nalar-load-global-knowledge-empty-dir/.config/nalar/memories/notes.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "should be ignored");
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "loadGlobalKnowledge loads a single memory file with H1 title" {
    // The happy path: one .md file with an H1 heading. The function
    // must emit `### <title> (`<filename>`)` followed by the full file
    // content. The H1 line itself appears in the file content (the
    // function does NOT strip the source H1 — it just renders a new
    // `### <title> ...` heading derived from the H1).
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-load-global-knowledge-single-h1";
    const memories_dir = "/tmp/nalar-load-global-knowledge-single-h1/.config/nalar/memories";
    const file_path = "/tmp/nalar-load-global-knowledge-single-h1/.config/nalar/memories/regression-test-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Write a Regression Test First
            \\
            \\After fixing a tricky bug, write a regression test before
            \\touching anything else. Fixes without tests regress.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    // Heading uses the H1 title in backticks, paired with the filename.
    try std.testing.expect(contains(result, "### Write a Regression Test First (`regression-test-rule.md`)"));
    // Full file content is included (not truncated).
    try std.testing.expect(contains(result, "After fixing a tricky bug, write a regression test before"));
    try std.testing.expect(contains(result, "touching anything else. Fixes without tests regress"));
    // Trailing blank line separator between entries.
    try std.testing.expect(contains(result, "regress.\n\n"));
}

test "loadGlobalKnowledge uses filename stem as title when no H1 is present" {
    // No H1 → `extractTitle` falls back to the filename stem (e.g.
    // "random-name.md" → "random-name"). The rendered heading must use
    // the stem in place of an H1 title.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-load-global-knowledge-no-h1";
    const memories_dir = "/tmp/nalar-load-global-knowledge-no-h1/.config/nalar/memories";
    const file_path = "/tmp/nalar-load-global-knowledge-no-h1/.config/nalar/memories/random-name.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "Just some prose, no header at all.\n");
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    // Title is the stem (without .md), not the full filename.
    try std.testing.expect(contains(result, "### random-name (`random-name.md`)"));
    // File body is present.
    try std.testing.expect(contains(result, "Just some prose, no header at all."));
}

test "loadGlobalKnowledge concatenates multiple memory files" {
    // Two .md files in the same dir → both rendered, separated by a
    // blank line. We don't assert on file order (dir iteration is
    // OS-dependent); we just verify both files appear with their
    // headings and content somewhere in the output.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-load-global-knowledge-multi";
    const memories_dir = "/tmp/nalar-load-global-knowledge-multi/.config/nalar/memories";
    const file1 = "/tmp/nalar-load-global-knowledge-multi/.config/nalar/memories/after-fix-test.md";
    const file2 = "/tmp/nalar-load-global-knowledge-multi/.config/nalar/memories/stderr-debug.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file1, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Write Regression Test First
            \\
            \\Always add a regression test after fixing a tricky bug.
            \\
        );
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file2, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Use stderr for Debug Output
            \\
            \\Stderr can be redirected without affecting stdout.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    // Both headings appear.
    try std.testing.expect(contains(result, "### Write Regression Test First (`after-fix-test.md`)"));
    try std.testing.expect(contains(result, "### Use stderr for Debug Output (`stderr-debug.md`)"));
    // Both bodies appear.
    try std.testing.expect(contains(result, "Always add a regression test after fixing a tricky bug."));
    try std.testing.expect(contains(result, "Stderr can be redirected without affecting stdout."));
}

test "loadGlobalKnowledge skips a corrupt file and loads the rest" {
    // Mirrors the "openFile/readFile errors skip-and-continue" contract
    // from `loadGlobalKnowledge`. A file that's been replaced by a
    // directory of the same name can't be opened as a regular file, so
    // it's silently skipped. The other file must still load.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-load-global-knowledge-corrupt-skip";
    const memories_dir = "/tmp/nalar-load-global-knowledge-corrupt-skip/.config/nalar/memories";
    const bad_path = "/tmp/nalar-load-global-knowledge-corrupt-skip/.config/nalar/memories/broken.md";
    const good_path = "/tmp/nalar-load-global-knowledge-corrupt-skip/.config/nalar/memories/working.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    // Create `broken.md` AS A DIRECTORY (so openFile fails — it's not
    // a regular file). This simulates a corrupt / permission-denied
    // file. The loader must skip it, not abort.
    try std.Io.Dir.cwd().createDirPath(io, bad_path);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, good_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Good Memory
            \\
            \\This file loads fine.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const result = try loadGlobalKnowledge(alloc, io, &env);
    defer alloc.free(result);

    // The good file is rendered; the bad one is silently absent.
    try std.testing.expect(contains(result, "### Good Memory (`working.md`)"));
    try std.testing.expect(contains(result, "This file loads fine."));
    try std.testing.expect(!contains(result, "broken.md"));
}

// ---------------------------------------------------------------------------
// loadLocalKnowledge — direct unit tests for the per-project memory loader.
//
// Sibling of `loadGlobalKnowledge`, but scoped to `<cwd>/.nalar/memories/`
// instead of `<HOME>/.config/nalar/memories/`. The function does NOT take
// an environment — local knowledge is project-scoped, not user-scoped.
//
// The tests mirror the `loadGlobalKnowledge` suite (empty cwd, missing
// subdir, empty dir, single H1, no-H1 fallback, multiple files, corrupt
// skip) so the two loaders are tested in parallel and their contract
// symmetry is enforced.
// ---------------------------------------------------------------------------

test "loadLocalKnowledge returns empty string when cwd is empty" {
    // No project context → no local knowledge. Mirrors the first-run
    // contract: an empty cwd must NOT error, must return "".
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const result = try loadLocalKnowledge(alloc, io, "");
    defer alloc.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "loadLocalKnowledge returns empty string when cwd has no .nalar/memories subdir" {
    // First-run case: cwd is a real path but the user has not created
    // `<cwd>/.nalar/memories/` yet. Must not error, must return "".
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/nalar-load-local-knowledge-missing-dir";
    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_cwd);

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "loadLocalKnowledge returns empty string when memories dir exists but is empty" {
    // The dir exists but contains no .md files. Mirrors the first-run
    // contract: no memories → no Local Knowledge content.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/nalar-load-local-knowledge-empty-dir";
    const memories_dir = "/tmp/nalar-load-local-knowledge-empty-dir/.nalar/memories";
    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    // Drop a non-md file to confirm it's ignored, not picked up as a memory.
    const txt_path = "/tmp/nalar-load-local-knowledge-empty-dir/.nalar/memories/notes.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "should be ignored");
    }

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "loadLocalKnowledge loads a single memory file with H1 title" {
    // Happy path: one .md file with an H1 heading. The function must
    // emit `### <title> (<filename>)` followed by the full file
    // content. The H1 line itself appears in the file content (the
    // function does NOT strip the source H1 — it just renders a new
    // `### <title> ...` heading derived from the H1).
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/nalar-load-local-knowledge-single-h1";
    const memories_dir = "/tmp/nalar-load-local-knowledge-single-h1/.nalar/memories";
    const file_path = "/tmp/nalar-load-local-knowledge-single-h1/.nalar/memories/project-build-rule.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Project Build Rule
            \\
            \\Always run `zig build test:ai_workflow:tui` before declaring
            \\a task done in this repo. Fixes without tests regress.
            \\
        );
    }

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    // Heading uses the H1 title in backticks, paired with the filename.
    try std.testing.expect(contains(result, "### Project Build Rule (`project-build-rule.md`)"));
    // Full file content is included (not truncated).
    try std.testing.expect(contains(result, "Always run `zig build test:ai_workflow:tui` before declaring"));
    try std.testing.expect(contains(result, "a task done in this repo. Fixes without tests regress"));
    // Trailing blank line separator between entries.
    try std.testing.expect(contains(result, "regress.\n\n"));
}

test "loadLocalKnowledge uses filename stem as title when no H1 is present" {
    // No H1 → `extractTitle` falls back to the filename stem (e.g.
    // "random-name.md" → "random-name"). The rendered heading must use
    // the stem in place of an H1 title.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/nalar-load-local-knowledge-no-h1";
    const memories_dir = "/tmp/nalar-load-local-knowledge-no-h1/.nalar/memories";
    const file_path = "/tmp/nalar-load-local-knowledge-no-h1/.nalar/memories/random-name.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "Just some prose, no header at all.\n");
    }

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    // Title is the stem (without .md), not the full filename.
    try std.testing.expect(contains(result, "### random-name (`random-name.md`)"));
    // File body is present.
    try std.testing.expect(contains(result, "Just some prose, no header at all."));
}

test "loadLocalKnowledge concatenates multiple memory files" {
    // Two .md files in the same dir → both rendered, separated by a
    // blank line. We don't assert on file order (dir iteration is
    // OS-dependent); we just verify both files appear with their
    // headings and content somewhere in the output.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/nalar-load-local-knowledge-multi";
    const memories_dir = "/tmp/nalar-load-local-knowledge-multi/.nalar/memories";
    const file1 = "/tmp/nalar-load-local-knowledge-multi/.nalar/memories/run-tests-first.md";
    const file2 = "/tmp/nalar-load-local-knowledge-multi/.nalar/memories/commit-style.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file1, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Run Tests First
            \\
            \\Always run the test suite before committing.
            \\
        );
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file2, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Commit Style
            \\
            \\Use conventional commits for this project.
            \\
        );
    }

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    // Both headings appear.
    try std.testing.expect(contains(result, "### Run Tests First (`run-tests-first.md`)"));
    try std.testing.expect(contains(result, "### Commit Style (`commit-style.md`)"));
    // Both bodies appear.
    try std.testing.expect(contains(result, "Always run the test suite before committing."));
    try std.testing.expect(contains(result, "Use conventional commits for this project."));
}

test "loadLocalKnowledge skips a corrupt file and loads the rest" {
    // Mirrors the "openFile/readFile errors skip-and-continue" contract
    // from `loadLocalKnowledge`. A file that's been replaced by a
    // directory of the same name can't be opened as a regular file, so
    // it's silently skipped. The other file must still load.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_cwd = "/tmp/nalar-load-local-knowledge-corrupt-skip";
    const memories_dir = "/tmp/nalar-load-local-knowledge-corrupt-skip/.nalar/memories";
    const bad_path = "/tmp/nalar-load-local-knowledge-corrupt-skip/.nalar/memories/broken.md";
    const good_path = "/tmp/nalar-load-local-knowledge-corrupt-skip/.nalar/memories/working.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    // Create `broken.md` AS A DIRECTORY (so openFile fails — it's not
    // a regular file). This simulates a corrupt / permission-denied
    // file. The loader must skip it, not abort.
    try std.Io.Dir.cwd().createDirPath(io, bad_path);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, good_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Good Memory
            \\
            \\This file loads fine.
            \\
        );
    }

    const result = try loadLocalKnowledge(alloc, io, tmp_cwd);
    defer alloc.free(result);

    // The good file is rendered; the bad one is silently absent.
    try std.testing.expect(contains(result, "### Good Memory (`working.md`)"));
    try std.testing.expect(contains(result, "This file loads fine."));
    try std.testing.expect(!contains(result, "broken.md"));
}

// ---------------------------------------------------------------------------
// build_agent_prompt — Workspace Context section
// ---------------------------------------------------------------------------
//
// The Workspace Context section is a pre-rendered markdown block built by
// `BuildWorkspaceContext` in `prompts_build_messages_for_agent_prompt.zig`. It is
// threaded through `buildMessages` → `build_agent_prompt` as the new last
// parameter. These tests verify the wiring: when the block is non-empty, it
// is appended to the prompt verbatim between the cwd line and the OS info.
// When empty, the section is silently omitted.

test "build_agent_prompt renders Workspace Context when section is non-empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    // Realistic Workspace Context block (the same shape produced by
    // `BuildWorkspaceContext` in `prompts_build_messages_for_agent_prompt.zig`).
    // The block starts with "\n\n## Workspace Context" and includes the
    // self marker, item names, paths, and per-item task lists.
    const workspaceContext =
        \\## Workspace Context
        \\
        \\This task is part of workspace `ws_smoke`. The other items in this
        \\workspace are listed below for discovery.
        \\
        \\- **Frontend** (item_type: `chat`, path: `/tmp/frontend`) *(this task)*
        \\  - task: `Setup` (type: standard, session: `sess_self`)
        \\  - task: `Build` (type: standard)
        \\- **Backend** (item_type: `chat`, path: `/tmp/backend`)
        \\  - task: `API` (type: standard, session: `sess_backend`)
        \\
    ;
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        workspaceContext,
        "", "");
    defer alloc.free(prompt);

    // Section header is present.
    try std.testing.expect(contains(prompt, "## Workspace Context"));
    // Self marker is present.
    try std.testing.expect(contains(prompt, "*(this task)*"));
    // Item names are present.
    try std.testing.expect(contains(prompt, "**Frontend**"));
    try std.testing.expect(contains(prompt, "**Backend**"));
    // Item paths are present.
    try std.testing.expect(contains(prompt, "`/tmp/frontend`"));
    try std.testing.expect(contains(prompt, "`/tmp/backend`"));
    // Task names are present.
    try std.testing.expect(contains(prompt, "`Setup`"));
    try std.testing.expect(contains(prompt, "`Build`"));
    try std.testing.expect(contains(prompt, "`API`"));
    // Session IDs are present.
    try std.testing.expect(contains(prompt, "session: `sess_self`"));
    try std.testing.expect(contains(prompt, "session: `sess_backend`"));

    // Workspace Context is rendered between cwd and OS info.
    const cwd_pos = std.mem.indexOf(u8, prompt, "**Current working directory:**") orelse
        return error.CwdLineMissing;
    const ws_pos = std.mem.indexOf(u8, prompt, "## Workspace Context") orelse
        return error.WorkspaceContextMissing;
    const os_pos = std.mem.indexOf(u8, prompt, "**Operating System:**") orelse
        return error.OsLineMissing;
    try std.testing.expect(cwd_pos < ws_pos);
    try std.testing.expect(ws_pos < os_pos);
}

test "build_agent_prompt omits Workspace Context when section is empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    // workspaceContext is "" — mirrors the production behavior when
    // the session is not bound to any workspace_item_task.
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "", // empty workspaceContext
        "", // empty kanbanStatusContent
        "", // empty designStatusContent
    );
    defer alloc.free(prompt);

    // No Workspace Context section is rendered.
    try std.testing.expect(!contains(prompt, "## Workspace Context"));
    // No self-marker text either.
    try std.testing.expect(!contains(prompt, "*(this task)*"));
}

// ---------------------------------------------------------------------------
// build_agent_prompt — Search Tool Preference (MANDATORY) section.
//
// Added to enforce `search` tool usage over `bash rg`/`grep`/`find` for
// code/text search. The section is unconditional (no `requires_tool` gate),
// so it appears in every agent's prompt regardless of tool list.
// ---------------------------------------------------------------------------

test "build_agent_prompt always renders Search Tool Preference (unconditional)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Empty tool list — proves the section has no `requires_tool` gate.
    const tools = [_]AgentTool{};
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        "",
        "",
    );
    defer alloc.free(prompt);

    // Header is rendered.
    try std.testing.expect(contains(prompt, "## Search Tool Preference (MANDATORY)"));
    // Hard-rule language is preserved.
    try std.testing.expect(contains(prompt, "always use the `search` tool"));
    try std.testing.expect(contains(prompt, "Do NOT use `bash`"));
    // Mapping examples survived into the rendered prompt.
    try std.testing.expect(contains(prompt, "search(pattern=\"pattern\""));
    try std.testing.expect(contains(prompt, "group_by_file: false"));
    try std.testing.expect(contains(prompt, "word_boundary: true"));
    try std.testing.expect(contains(prompt, "literal: true"));
    // The opt-in rg fallback list is also present so agents know when bash rg is OK.
    try std.testing.expect(contains(prompt, "When `bash rg` IS allowed"));
    try std.testing.expect(contains(prompt, "rg -C N"));
    try std.testing.expect(contains(prompt, "rg --json"));
    // Self-check is the closing reinforcement.
    try std.testing.expect(contains(prompt, "code/text search"));
}

test "build_agent_prompt Search Tool Preference appears even with non-empty tool list" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Realistic tool list — the search rule must still appear.
    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("bash", "Run a bash command"),
        makeTool("search", "Search tool"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        "",
        "",
    );
    defer alloc.free(prompt);

    try std.testing.expect(contains(prompt, "## Search Tool Preference (MANDATORY)"));
    try std.testing.expect(contains(prompt, "always use the `search` tool"));
}

// -------------------------------------------------------------------------
// Memory Tools Rule (save_memory + load_memory) — gated on `load_memory`
// -------------------------------------------------------------------------

test "build_agent_prompt renders Memory Tools section when load_memory is in tool list" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // load_memory IS in tools → section rendered.
    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("load_memory", "Search saved notes (FTS5)"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        "",
        "",
    );
    defer alloc.free(prompt);

    // Section header is rendered.
    try std.testing.expect(contains(prompt, "## Memory Tools"));
    // Both tool names are mentioned (the rule covers both tools).
    try std.testing.expect(contains(prompt, "save_memory"));
    try std.testing.expect(contains(prompt, "load_memory"));
    // FTS5 sanitization note is preserved (mirrors ReadWorkspaceSessionToolRule pattern).
    try std.testing.expect(contains(prompt, "FTS5") or contains(prompt, "FTS query syntax is auto-sanitized"));
    // When-to-call example survives.
    try std.testing.expect(contains(prompt, "do you remember"));
}

test "build_agent_prompt omits Memory Tools section when load_memory is absent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // load_memory NOT in tools → section omitted entirely.
    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("bash", "Run shell"),
    };
    const prompt = try prompts_mod.build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        "",
        "",
        "",
    );
    defer alloc.free(prompt);

    try std.testing.expect(!contains(prompt, "## Memory Tools"));
}

test "CompactionAgent constant teaches save_memory + load_memory (cross-session memory block)" {
    // CompactionAgent is a comptime string literal (`pub const X = \\…`),
    // so we read it directly without an allocator. The new block must
    // teach the compaction step to forward save/load cues to the next
    // agent rather than pasting the value verbatim.
    const prompt: []const u8 = CompactionAgent;

    // The new block is present.
    try std.testing.expect(contains(prompt, "CROSS-SESSION MEMORY"));
    // Both tools are referenced.
    try std.testing.expect(contains(prompt, "save_memory"));
    try std.testing.expect(contains(prompt, "load_memory"));
    // The block teaches the compaction step to forward save/load cues to
    // the next agent rather than pasting the value verbatim.
    try std.testing.expect(contains(prompt, "save_memory id=") or
        contains(prompt, "load_memory query=") or
        contains(prompt, "next agent"));
}

// -------------------------------------------------------------------------
// ResponseFormatting — <html> wrapper tag (2026-08-23 html-tag-support)
// -------------------------------------------------------------------------

test "ResponseFormatting teaches the <html> wrapper tag" {
    // The model must know it CAN wrap raw HTML in <html>...</html> so the
    // chat UI renders it as a live sandboxed-iframe block. Capability
    // phrasing ("you can use"), not mandate. See plan:
    // docs/superpowers/plans/2026-08-23-html-tag-support.md
    const prompt: []const u8 = ResponseFormatting;

    // The tag pair is present.
    try std.testing.expect(contains(prompt, "<html>"));
    try std.testing.expect(contains(prompt, "</html>"));
    // The capability phrasing the user asked for.
    try std.testing.expect(contains(prompt, "HTML Responses"));
    try std.testing.expect(contains(prompt, "you can use"));
    // Verbatim-emission note (wire-format requirement).
    try std.testing.expect(contains(prompt, "verbatim"));
    // Theme note (2026-09-13, task_1789312493325_7). The model authors the
    // HTML blind: real payloads (llm_history 1789313976387498377) shipped
    // GitHub's light `background:#f6f8fa` on every <pre>, which the dark
    // transcript then rendered at 1.57:1 contrast — unreadable. The prompt
    // has to state the theme, or the model keeps guessing "light page".
    try std.testing.expect(contains(prompt, "DARK"));
    try std.testing.expect(contains(prompt, "#1D1C19"));
}

// -------------------------------------------------------------------------
// Regression: build_agent_prompt was moved from
// src/modules/agent/prompts.zig into
// src/agentic_loop/prompts_build_messages_for_agent_prompt.zig
// on 2026-08-23 (plan:
// docs/superpowers/plans/2026-08-23-move-build-agent-prompt-body.md).
// This test pins the byte-level ordering of the rendered prompt so any
// future re-ordering fails closed. Substrings are chosen to be stable
// across rephrasings of section prose: we assert the HEADER for each
// block is present and that the relative ordering matches the
// `PROMPT_SECTIONS` declaration order + the post-loop block order.
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// ProgressiveToolRule + SkillsToolRule + MemoryToolRule +
// ReadWorkspaceSessionToolRule — the "tools the agent must actually use"
// mandates wired into buildMessages. Four properties are pinned:
//   1. Content: each rule names its tools and states the mandate.
//   2. No bloat: no rule pre-lists skills, and buildMessages never injects
//      skill bodies — discovery stays a `list_skills` call so the cacheable
//      system-prompt prefix does not grow with the user's skill library.
//   3. Cache-stability: all four are appended unconditionally (no hasTool
//      gate), so the block is byte-identical for every agent and the shared
//      prefix stays a cache hit instead of fragmenting per tool set.
//   4. Live-path coverage: each rule must be referenced by buildMessages, not
//      only by the test-only build_agent_prompt / PROMPT_SECTIONS path.
// -------------------------------------------------------------------------

test "ProgressiveToolRule names the special tool and the three-call loop" {
    const prompt: []const u8 = ProgressiveToolRule;

    // It is framed as the agent's special tool with a mandate to use it.
    try std.testing.expect(contains(prompt, "your special tool"));
    try std.testing.expect(contains(prompt, "search_tool"));
    // The loop: search -> view -> use, in that order.
    const i_search = std.mem.indexOf(u8, prompt, "- `search_tool`").?;
    const i_view = std.mem.indexOf(u8, prompt, "- `view_tool`").?;
    const i_use = std.mem.indexOf(u8, prompt, "- `use_tool`").?;
    try std.testing.expect(i_search < i_view);
    try std.testing.expect(i_view < i_use);
    // The "always search to finish the task" mandate, not just "when stuck".
    try std.testing.expect(contains(prompt, "every task"));
    try std.testing.expect(contains(prompt, "Before hand-rolling"));
}

test "SkillsToolRule names the special skills and the list->use loop" {
    const prompt: []const u8 = SkillsToolRule;

    try std.testing.expect(contains(prompt, "your special skills"));
    const i_list = std.mem.indexOf(u8, prompt, "- `list_skills`").?;
    const i_use = std.mem.indexOf(u8, prompt, "- `use_skill`").?;
    try std.testing.expect(i_list < i_use);
    // Mandate: load the skill the task needs, before improvising.
    try std.testing.expect(contains(prompt, "When to load"));
    try std.testing.expect(contains(prompt, "blocking, not advisory"));
    // Path handling — the one argument use_skill takes.
    try std.testing.expect(contains(prompt, "SKILL.MD"));
    try std.testing.expect(contains(prompt, "verbatim"));
}

test "SkillsToolRule does not pre-list skills (no Available Skills listing)" {
    // A per-user listing in the system prompt would grow with the skill
    // library and bust the cacheable prefix. Discovery must stay a tool call.
    const prompt: []const u8 = SkillsToolRule;
    try std.testing.expect(!contains(prompt, "## Available Skills"));
    try std.testing.expect(!contains(prompt, "## Loaded Skills"));
    // It must instead say so explicitly, so the model knows to call the tool.
    try std.testing.expect(contains(prompt, "Nothing is pre-injected"));
}

test "static contract: buildMessages appends all four rules unconditionally" {
    const src = @embedFile("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig");

    try std.testing.expect(contains(src, "prompts_const.ProgressiveToolRule"));
    try std.testing.expect(contains(src, "prompts_const.SkillsToolRule"));
    try std.testing.expect(contains(src, "prompts_const.MemoryToolRule"));
    try std.testing.expect(contains(src, "prompts_const.ReadWorkspaceSessionToolRule"));

    // No hasTool gate on any of the four: a per-agent condition in the
    // cacheable prefix fragments the prompt cache across every distinct tool
    // set. PROMPT_SECTIONS still gates memory on load_memory, but that
    // constant only feeds build_agent_prompt, which no production caller
    // reaches — so the gate there does not protect the live prompt.
    try std.testing.expect(!contains(src, "hasTool(filtered_tools, \"search_tool\")"));
    try std.testing.expect(!contains(src, "hasTool(filtered_tools, \"use_skill\")"));
    try std.testing.expect(!contains(src, "hasTool(filtered_tools, \"list_skills\")"));
    try std.testing.expect(!contains(src, "hasTool(filtered_tools, \"load_memory\")"));
    try std.testing.expect(!contains(src, "hasTool(filtered_tools, \"save_memory\")"));
    try std.testing.expect(!contains(src, "hasTool(filtered_tools, \"read_workspace_session\")"));

    // No skill bodies / no skills listing injected into the prompt.
    try std.testing.expect(!contains(src, "makeSkillsEquippedContext(allocator, db, session_id)"));
    try std.testing.expect(!contains(src, "appendSkillsListing(allocator, &final_system"));
}

test "static contract: the four rules sit in the static prefix, before dynamic blocks" {
    const src = @embedFile("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig");

    const i_progressive = std.mem.indexOf(u8, src, "prompts_const.ProgressiveToolRule").?;
    const i_skills = std.mem.indexOf(u8, src, "prompts_const.SkillsToolRule").?;
    const i_memory_rule = std.mem.indexOf(u8, src, "prompts_const.MemoryToolRule").?;
    const i_session_rule = std.mem.indexOf(u8, src, "prompts_const.ReadWorkspaceSessionToolRule").?;
    const i_plan = std.mem.indexOf(u8, src, "## Task Planning").?;
    const i_memory_md = std.mem.indexOf(u8, src, "makeWorkingDirectoryContext").?;
    const i_finalize = std.mem.indexOf(u8, src, "final_system.toOwnedSlice").?;

    // The four mandates sit together, in a stable order, after the other
    // static rules ...
    try std.testing.expect(i_progressive > i_plan);
    try std.testing.expect(i_progressive < i_skills);
    try std.testing.expect(i_skills < i_memory_rule);
    try std.testing.expect(i_memory_rule < i_session_rule);
    // ... and before the first dynamic block, so a per-session mutation
    // cannot invalidate the prefix the provider caches.
    try std.testing.expect(i_session_rule < i_memory_md);
    try std.testing.expect(i_session_rule < i_finalize);
}

test "MemoryToolRule reaches the live prompt, not just the test-only path" {
    // MemoryToolRule used to be referenced ONLY by PROMPT_SECTIONS, which
    // feeds build_agent_prompt — and build_agent_prompt has no production
    // caller (workflow.zig and session_compact.zig both call buildMessages).
    // So a prompt that opens with "failing to call load_memory ... is a task
    // failure" never reached a real agent. Pin the live-path reference so a
    // future refactor cannot drop it back to the test-only path.
    const src = @embedFile("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig");
    try std.testing.expect(contains(src, "prompts_const.MemoryToolRule"));

    // Sanity: buildMessages is the live path and build_agent_prompt is not.
    // workflow.zig:1348 and http_handlers/session_compact.zig:85 both call
    // buildMessages; build_agent_prompt is referenced only from tests.
    const workflow = @embedFile("../../agentic_loop/workflow.zig");
    try std.testing.expect(contains(workflow, "buildMessages("));
    try std.testing.expect(!contains(workflow, "build_agent_prompt("));
}

test "MemoryToolRule names both memory tools and the blocking gate" {
    const prompt: []const u8 = MemoryToolRule;

    try std.testing.expect(contains(prompt, "save_memory"));
    try std.testing.expect(contains(prompt, "load_memory"));
    // The mandate framing the user asked for — not optional, blocking.
    try std.testing.expect(contains(prompt, "NOT optional"));
    try std.testing.expect(contains(prompt, "blocking, not advisory"));
    // The two load triggers that make it actionable without re-reading the rule.
    try std.testing.expect(contains(prompt, "first user message of any session"));
    // Cross-reference stays accurate: buildMessages does inject this block.
    try std.testing.expect(contains(prompt, "## Global Knowledge"));
}

test "ReadWorkspaceSessionToolRule reaches the live prompt, not just PROMPT_SECTIONS" {
    // Same defect as MemoryToolRule: the rule was referenced only by
    // PROMPT_SECTIONS, which feeds build_agent_prompt — a function with no
    // production caller. So "don't ask the user to repeat themselves" was
    // advice no real agent ever received.
    const src = @embedFile("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig");
    try std.testing.expect(contains(src, "prompts_const.ReadWorkspaceSessionToolRule"));

    // The tool it mandates must actually be equipped, or the rule is a lie.
    const equipped = @embedFile("../../agentic_loop/tools_equipped.zig");
    try std.testing.expect(contains(equipped, "read_workspace_session"));
}

test "ReadWorkspaceSessionToolRule names the tool and the four behaviors" {
    const prompt: []const u8 = ReadWorkspaceSessionToolRule;

    try std.testing.expect(contains(prompt, "read_workspace_session"));
    // The anti-pattern it exists to stop.
    try std.testing.expect(contains(prompt, "ask the user to repeat themselves"));
    // FOUR BEHAVIORS, in the documented order: list / search / read / search-within.
    const i_behaviors = std.mem.indexOf(u8, prompt, "FOUR BEHAVIORS").?;
    const i_search = std.mem.indexOf(u8, prompt, "`query`").?;
    const i_read = std.mem.indexOf(u8, prompt, "`session_id`").?;
    const i_within = std.mem.indexOf(u8, prompt, "SEARCH-WITHIN").?;
    try std.testing.expect(i_behaviors < i_search);
    try std.testing.expect(i_search < i_read);
    try std.testing.expect(i_read < i_within);
    // The live filters must be named — the old "compacted_messages
    // envelopes" phrasing was stale jargon for a concept the tool now
    // exposes as live_only / compacted_only.
    try std.testing.expect(contains(prompt, "live_only"));
    try std.testing.expect(contains(prompt, "compacted_only"));
    try std.testing.expect(!contains(prompt, "compacted_messages"));
}


test "SkillEvalToolRule reaches the live prompt, not just PROMPT_SECTIONS" {
    const src = @embedFile("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig");
    try std.testing.expect(contains(src, "prompts_const.SkillEvalToolRule"));

    // The live append and the documented PROMPT_SECTIONS mirror must name the
    // same tool, or the rule points at something nobody declares.
    try std.testing.expect(contains(src, ".requires_tool = \"run_skill_eval\""));

    // And the tool it mandates must actually be equipped, or the rule is a
    // lie. This asserts MEMBERSHIP of the table `filterAndMergeTools` actually
    // iterates — a source grep for the string would pass on an entry in
    // UNIFIED_TOOL_REGISTRY, which is the dispatcher's table and is never
    // consulted when the tool list is built. That is exactly how the tool
    // shipped unreachable once already.
    const tools_equipped = @import("../../agentic_loop/tools_equipped.zig");
    const equipped = tools_equipped.equips(std.testing.allocator);
    defer std.testing.allocator.free(equipped);
    var found = false;
    for (equipped) |t| {
        if (std.mem.eql(u8, t.function.name, "run_skill_eval")) found = true;
    }
    try std.testing.expect(found);
}

test "SkillEvalToolRule is appended unconditionally, beside the other mandates" {
    const src = @embedFile("../../agentic_loop/prompts_build_messages_for_agent_prompt.zig");

    // Gating this rule on `hasTool` would make the cacheable prefix differ per
    // agent, which is the one thing that block must not do. This asserts the
    // append sits in the same run of unconditional appends as the four
    // mandates above it: between the previous rule and this one there is no
    // `hasTool` and no `if (`.
    const i_prev = std.mem.indexOf(u8, src, "prompts_const.ReadWorkspaceSessionToolRule);").?;
    const i_this = std.mem.indexOf(u8, src, "prompts_const.SkillEvalToolRule);").?;
    try std.testing.expect(i_prev < i_this);

    const between = src[i_prev..i_this];
    try std.testing.expect(std.mem.indexOf(u8, between, "hasTool") == null);
    try std.testing.expect(std.mem.indexOf(u8, between, "if (") == null);
}

test "SkillEvalToolRule names the tool and its non-negotiable behaviors" {
    const prompt: []const u8 = SkillEvalToolRule;

    try std.testing.expect(contains(prompt, "run_skill_eval"));
    // The common case: nothing was loaded, so a skip is correct.
    try std.testing.expect(contains(prompt, "Skip it"));
    // A second call must read as a cheap no-op, not a second eval.
    try std.testing.expect(contains(prompt, "Once per task"));
    // The agent chooses WHEN, not the verdict — that is the whole design.
    try std.testing.expect(contains(prompt, "You are not the judge"));
    // It must NOT be told to pass the skill list: the tool reads the ledger,
    // which is what stops an agent omitting the skill it worked around.
    try std.testing.expect(contains(prompt, "you cannot"));
    try std.testing.expect(contains(prompt, "Self-check"));
    // It must be honest about the needs_human outcome rather than hiding it.
    try std.testing.expect(contains(prompt, "needs_human"));
}
