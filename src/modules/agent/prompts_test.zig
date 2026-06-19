const std = @import("std");
const prompts = @import("prompts.zig");
const tool_models = @import("nalarcore").tool_models;
const AgentTool = tool_models.AgentTool;
const AgentToolFunction = tool_models.AgentToolFunction;
const ToolParameters = tool_models.ToolParameters;
const ToolProperty = tool_models.ToolProperty;

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
test "build_agent_prompt with no environment: no Global Knowledge section" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("list_memory", "List memory files"),
    };
    const prompt = try prompts.build_agent_prompt(
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
    );
    defer alloc.free(prompt);

    // Static GlobalMemorySystem section is present (gated on list_memory tool)
    try std.testing.expect(contains(prompt, "## Global Memory System"));
    // But the dynamic "## Global Knowledge" section is NOT — env is null
    try std.testing.expect(!contains(prompt, "## Global Knowledge\n"));
}

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
    const prompt = try prompts.build_agent_prompt(
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
    );
    defer alloc.free(prompt);

    // The Global Knowledge section is present
    try std.testing.expect(contains(prompt, "## Global Knowledge"));
    // The memory file is loaded with its content
    try std.testing.expect(contains(prompt, "regression-test-rule.md"));
    try std.testing.expect(contains(prompt, "Write a Regression Test First"));
    try std.testing.expect(contains(prompt, "Fixes without tests regress"));
}

test "build_agent_prompt: empty memories dir, no Global Knowledge section" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-main-prompt-empty";
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const tools = [_]AgentTool{
        makeTool("list_memory", "List memory files"),
    };
    const prompt = try prompts.build_agent_prompt(
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
    );
    defer alloc.free(prompt);

    // No memories folder → no dynamic Global Knowledge section
    try std.testing.expect(!contains(prompt, "## Global Knowledge\n"));
    // But the static GlobalMemorySystem section is still there
    try std.testing.expect(contains(prompt, "## Global Memory System"));
}

// build_agent_prompt — Available Skills listing
// -------------------------------------------------------------------------

test "build_agent_prompt lists global and local skills in Available Skills section" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-prompt-test-skills-listing";
    const tmp_cwd = "/tmp/nalar-prompt-test-skills-listing-cwd";
    const global_skill_dir = "/tmp/nalar-prompt-test-skills-listing/.config/nalar/skills/test-global-skill";
    const local_skill_dir = "/tmp/nalar-prompt-test-skills-listing-cwd/.nalar/skills/test-local-skill";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
        std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    }

    try std.Io.Dir.cwd().createDirPath(io, global_skill_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(
            io,
            "/tmp/nalar-prompt-test-skills-listing/.config/nalar/skills/test-global-skill/SKILL.MD",
            .{},
        );
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: test-global-skill
            \\description: "A global skill for prompt listing test"
            \\---
            \\
            \\# Global skill body
            \\
        );
    }

    try std.Io.Dir.cwd().createDirPath(io, local_skill_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(
            io,
            "/tmp/nalar-prompt-test-skills-listing-cwd/.nalar/skills/test-local-skill/SKILL.MD",
            .{},
        );
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: test-local-skill
            \\description: "A local skill for prompt listing test"
            \\---
            \\
            \\# Local skill body
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("list_skills", "List available skills"),
    };
    const prompt = try prompts.build_agent_prompt(
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
    );
    defer alloc.free(prompt);

    // Section header is present
    try std.testing.expect(contains(prompt, "## Available Skills"));
    // Both subsections are present
    try std.testing.expect(contains(prompt, "### Global skills"));
    try std.testing.expect(contains(prompt, "### Local skills"));
    // Skill names appear
    try std.testing.expect(contains(prompt, "test-global-skill"));
    try std.testing.expect(contains(prompt, "test-local-skill"));
    // Skill descriptions appear
    try std.testing.expect(contains(prompt, "A global skill for prompt listing test"));
    try std.testing.expect(contains(prompt, "A local skill for prompt listing test"));
}

test "build_agent_prompt Available Skills section includes absolute file path and case-sensitivity warning" {
    // Regression test for the bug where the agent's get_skill call failed
    // because the Available Skills section listed skills by name+description
    // only — the model had to guess the path and produced wrong paths like
    // `~/.config/nalar/skills/brainstorming.md` (tilde not expanded, .md vs
    // .MD, `<name>.md` vs `<name>/SKILL.MD`). The fix emits the absolute
    // `path` from listAllSkills in each bullet and adds an explicit warning.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-prompt-test-skills-shows-path";
    const tmp_cwd = "/tmp/nalar-prompt-test-skills-shows-path-cwd";
    const global_skill_dir = "/tmp/nalar-prompt-test-skills-shows-path/.config/nalar/skills/path-global-skill";
    const local_skill_dir = "/tmp/nalar-prompt-test-skills-shows-path-cwd/.nalar/skills/path-local-skill";
    const global_skill_path = "/tmp/nalar-prompt-test-skills-shows-path/.config/nalar/skills/path-global-skill/SKILL.MD";
    const local_skill_path = "/tmp/nalar-prompt-test-skills-shows-path-cwd/.nalar/skills/path-local-skill/SKILL.MD";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
        std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    }

    try std.Io.Dir.cwd().createDirPath(io, global_skill_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, global_skill_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: path-global-skill
            \\description: "Global skill for the show-path regression test"
            \\---
            \\
        );
    }
    try std.Io.Dir.cwd().createDirPath(io, local_skill_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, local_skill_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: path-local-skill
            \\description: "Local skill for the show-path regression test"
            \\---
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
        makeTool("list_skills", "List available skills"),
    };
    const prompt = try prompts.build_agent_prompt(
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
    );
    defer alloc.free(prompt);

    // === Bullet list must include the absolute path of each skill ===
    // The exact string that goes into the path-construction bug.
    try std.testing.expect(contains(prompt, global_skill_path));
    try std.testing.expect(contains(prompt, local_skill_path));
    // The path appears inside a backtick code span, paired with the name.
    try std.testing.expect(contains(prompt, "**path-global-skill**"));
    try std.testing.expect(contains(prompt, "**path-local-skill**"));

    // === Warning prose must tell the model not to construct paths ===
    // Mentions the actual filename the model would need to guess.
    try std.testing.expect(contains(prompt, "**exact file path**"));
    try std.testing.expect(contains(prompt, "pass it to `get_skill` verbatim"));
    // The three failure modes from the bug:
    //   1) case-sensitivity (`.md` vs `.MD`)
    //   2) subdirectory layout (`<name>/SKILL.MD` vs `<name>.md`)
    //   3) unexpanded tilde
    try std.testing.expect(contains(prompt, "case-sensitive"));
    try std.testing.expect(contains(prompt, "`<name>/SKILL.MD`"));
    try std.testing.expect(contains(prompt, "`<name>.md`"));
    try std.testing.expect(contains(prompt, "`~` is not expanded"));
}

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
    const prompt = try prompts.build_agent_prompt(
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
    );
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
    const prompt = try prompts.build_agent_prompt(
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
    );
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
    const prompt = try prompts.build_agent_prompt(
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
    );
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
    const prompt = try prompts.build_agent_prompt(
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
    );
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
    const prompt = try prompts.build_agent_prompt(
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
    );
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
    const prompt = try prompts.build_agent_prompt(
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
    );
    defer alloc.free(prompt);

    // No cwd → no Local Knowledge section
    try std.testing.expect(!contains(prompt, "## Local Knowledge"));
}

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
    const prompt = try prompts.build_agent_prompt(
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
    );
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
    try prompts.appendSubAgentsListing(alloc, &result, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.items.len);
}

test "appendSubAgentsListing: renders a single row with name + model + description" {
    const alloc = std.testing.allocator;

    const rows = [_]prompts.SubAgentListingRow{
        .{
            .name = "code-reviewer",
            .model = "gpt-4o",
            .description = "You are a strict code reviewer.",
            .source = "",
        },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try prompts.appendSubAgentsListing(alloc, &result, &rows);

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

    const rows = [_]prompts.SubAgentListingRow{
        .{
            .name = "reviewer",
            .model = "gpt-4o",
            .description = "Profile-specific reviewer.",
            .source = "profile1",
        },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try prompts.appendSubAgentsListing(alloc, &result, &rows);

    try std.testing.expect(contains(result.items, "from profile `profile1`"));
}

test "appendSubAgentsListing: rows with empty name are skipped (defensive)" {
    const alloc = std.testing.allocator;

    const rows = [_]prompts.SubAgentListingRow{
        .{ .name = "", .model = "m", .description = "should be skipped", .source = "" },
        .{ .name = "valid", .model = "m", .description = "should be rendered", .source = "" },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try prompts.appendSubAgentsListing(alloc, &result, &rows);

    try std.testing.expect(!contains(result.items, "should be skipped"));
    try std.testing.expect(contains(result.items, "should be rendered"));
    try std.testing.expect(contains(result.items, "**valid**"));
}

test "appendSubAgentsListing: empty model/description still renders the row" {
    const alloc = std.testing.allocator;

    const rows = [_]prompts.SubAgentListingRow{
        .{ .name = "minimal", .model = "", .description = "", .source = "" },
    };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try prompts.appendSubAgentsListing(alloc, &result, &rows);

    // The name is present but neither the model nor the
    // description is rendered (no "model: \`\`", no em-dash).
    try std.testing.expect(contains(result.items, "**minimal**"));
    try std.testing.expect(!contains(result.items, "model: `"));
    try std.testing.expect(!contains(result.items, " — \""));
}

test "build_agent_prompt with sub_agents_listing: section is rendered when non-empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    const sub_agents_listing =
        \\## Available Sub-Agents
        \\
        \\- **code-reviewer** (model: `gpt-4o`)
        \\
    ;
    const prompt = try prompts.build_agent_prompt(
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
        sub_agents_listing,
        "",
    );
    defer alloc.free(prompt);

    try std.testing.expect(contains(prompt, "## Available Sub-Agents"));
    try std.testing.expect(contains(prompt, "**code-reviewer**"));
}

test "build_agent_prompt with sub_agents_listing: section is omitted when empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    const prompt = try prompts.build_agent_prompt(
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
        "",
    );
    defer alloc.free(prompt);

    try std.testing.expect(!contains(prompt, "## Available Sub-Agents"));
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

    const result = try prompts.loadGlobalKnowledge(alloc, io, null);
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

    const result = try prompts.loadGlobalKnowledge(alloc, io, &env);
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

    const result = try prompts.loadGlobalKnowledge(alloc, io, &env);
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

    const result = try prompts.loadGlobalKnowledge(alloc, io, &env);
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

    const result = try prompts.loadGlobalKnowledge(alloc, io, &env);
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

    const result = try prompts.loadGlobalKnowledge(alloc, io, &env);
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

    const result = try prompts.loadGlobalKnowledge(alloc, io, &env);
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

    const result = try prompts.loadLocalKnowledge(alloc, io, "");
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

    const result = try prompts.loadLocalKnowledge(alloc, io, tmp_cwd);
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

    const result = try prompts.loadLocalKnowledge(alloc, io, tmp_cwd);
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

    const result = try prompts.loadLocalKnowledge(alloc, io, tmp_cwd);
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

    const result = try prompts.loadLocalKnowledge(alloc, io, tmp_cwd);
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

    const result = try prompts.loadLocalKnowledge(alloc, io, tmp_cwd);
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

    const result = try prompts.loadLocalKnowledge(alloc, io, tmp_cwd);
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
// `BuildWorkspaceContext` in `build_messages_for_agent_prompt.zig`. It is
// threaded through `buildMessages` → `build_agent_prompt` as the new last
// parameter. These tests verify the wiring: when the block is non-empty, it
// is appended to the prompt verbatim between the cwd line and the OS info.
// When empty, the section is silently omitted.

test "build_agent_prompt renders Workspace Context when section is non-empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    // Realistic Workspace Context block (the same shape produced by
    // `BuildWorkspaceContext` in `build_messages_for_agent_prompt.zig`).
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
    const prompt = try prompts.build_agent_prompt(
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
    );
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
    const prompt = try prompts.build_agent_prompt(
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
    );
    defer alloc.free(prompt);

    // No Workspace Context section is rendered.
    try std.testing.expect(!contains(prompt, "## Workspace Context"));
    // No self-marker text either.
    try std.testing.expect(!contains(prompt, "*(this task)*"));
}
