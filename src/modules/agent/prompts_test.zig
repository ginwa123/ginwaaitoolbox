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
// build_sub_agent_prompt — empty / no-memory cases
// -------------------------------------------------------------------------

test "build_sub_agent_prompt with no environment: no Global Knowledge section" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{
        makeTool("read_file", "Read a file"),
    };
    const prompt = try prompts.build_sub_agent_prompt(
        alloc,
        io,
        "/tmp/some-cwd",
        "",
        "do the thing",
        &tools,
        null,
    );
    defer alloc.free(prompt);

    // No environment → no auto-loaded knowledge
    try std.testing.expect(!contains(prompt, "## Global Knowledge"));
    // The mission and tools still appear
    try std.testing.expect(contains(prompt, "## Your Mission"));
    try std.testing.expect(contains(prompt, "do the thing"));
    try std.testing.expect(contains(prompt, "read_file"));
}

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

test "build_sub_agent_prompt with empty memories dir: no Global Knowledge section" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // HOME points to a dir without a memories/ subfolder
    const tmp_home = "/tmp/nalar-prompt-test-empty-memories";
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const prompt = try prompts.build_sub_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "test task",
        &[_]AgentTool{},
        &env,
    );
    defer alloc.free(prompt);

    // No memories folder → no section
    try std.testing.expect(!contains(prompt, "## Global Knowledge"));
}

// -------------------------------------------------------------------------
// build_sub_agent_prompt — populated case
// -------------------------------------------------------------------------

test "build_sub_agent_prompt loads memory files into Global Knowledge section" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-prompt-test-with-memories";
    const memories_dir = "/tmp/nalar-prompt-test-with-memories/.config/nalar/memories";
    const file1_path = "/tmp/nalar-prompt-test-with-memories/.config/nalar/memories/after-fix-test.md";
    const file2_path = "/tmp/nalar-prompt-test-with-memories/.config/nalar/memories/stderr-debug.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, file1_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Write Regression Test First
            \\
            \\After fixing a tricky bug, write a regression test before touching
            \\anything else. Fixes without tests regress.
            \\
        );
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file2_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Use stderr for Debug Output
            \\
            \\Stderr can be redirected without affecting stdout, so it is the
            \\right place for diagnostic output that should not pollute results.
            \\
        );
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const prompt = try prompts.build_sub_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "test task",
        &[_]AgentTool{},
        &env,
    );
    defer alloc.free(prompt);

    // The Global Knowledge section is present
    try std.testing.expect(contains(prompt, "## Global Knowledge"));

    // Both memory files are loaded with their content
    try std.testing.expect(contains(prompt, "after-fix-test.md"));
    try std.testing.expect(contains(prompt, "Write Regression Test First"));
    try std.testing.expect(contains(prompt, "Fixes without tests regress"));

    try std.testing.expect(contains(prompt, "stderr-debug.md"));
    try std.testing.expect(contains(prompt, "Use stderr for Debug Output"));
    // Substring: file content has a line break between "the" and "right",
    // so we check just the actionable part.
    try std.testing.expect(contains(prompt, "right place for diagnostic output"));

    // The header is in there too — tells the agent what the section is
    try std.testing.expect(contains(prompt, "auto-loaded from"));
    try std.testing.expect(contains(prompt, "Use `list_memory`"));
}

// -------------------------------------------------------------------------
// build_agent_prompt — GlobalMemorySystem gating
// -------------------------------------------------------------------------


test "build_agent_prompt omits GlobalMemorySystem section when list_memory tool is absent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    // No list_memory in tools
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
        null,
    );
    defer alloc.free(prompt);

    // The section is gated — must not appear without list_memory
    try std.testing.expect(!contains(prompt, "## Global Memory System"));
    try std.testing.expect(!contains(prompt, "Generalize, don't specialize"));
}

// -------------------------------------------------------------------------
// build_sub_agent_prompt — no aggregate cap
// -------------------------------------------------------------------------

test "build_sub_agent_prompt loads large memory files fully (no aggregate cap)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/nalar-prompt-test-no-cap";
    const memories_dir = "/tmp/nalar-prompt-test-no-cap/.config/nalar/memories";
    const big_file = "/tmp/nalar-prompt-test-no-cap/.config/nalar/memories/big-memory.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    // Write a ~60KB memory file with a unique END marker so we can verify
    // the FULL content was loaded. If the prompt is capped at 50KB, the
    // marker would be cut off and the assertion would fail.
    const total_size: usize = 60 * 1024;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, big_file, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "# Big Memory\n\n");
        var buf: [1024]u8 = undefined;
        @memset(&buf, 'A');
        var written: usize = 0;
        while (written < total_size) : (written += buf.len) {
            try std.Io.File.writeStreamingAll(f, io, &buf);
        }
        // Append a unique marker so we can detect truncation
        try std.Io.File.writeStreamingAll(f, io, "\n\nEND_OF_MEMORY_MARKER_12345\n");
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const prompt = try prompts.build_sub_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "task",
        &[_]AgentTool{},
        &env,
    );
    defer alloc.free(prompt);

    // The section header is present
    try std.testing.expect(contains(prompt, "## Global Knowledge"));
    // The full file was loaded — the end-of-file marker survived
    try std.testing.expect(contains(prompt, "END_OF_MEMORY_MARKER_12345"));
    // No truncation note (because there is no truncation)
    try std.testing.expect(!contains(prompt, "additional memories were not auto-loaded"));
    // Prompt contains the full ~60KB of content (plus heading + framing)
    try std.testing.expect(prompt.len > total_size);
}
