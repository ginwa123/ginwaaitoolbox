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
    );
    defer alloc.free(prompt);

    // Dir exists but has no .md files → no section
    try std.testing.expect(!contains(prompt, "## Local Knowledge"));
}

