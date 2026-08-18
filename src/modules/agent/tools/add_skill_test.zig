const std = @import("std");
const add_skill_mod = @import("add_skill.zig");

test "add_skill - empty name returns error" {
    const alloc = std.testing.allocator;

    const input = add_skill_mod.AddSkillInput{
        .name = "",
        .description = "Test description",
        .content = "Test content",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = add_skill_mod.executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<created>false</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Skill name cannot be empty") != null);
}

test "add_skill - empty description returns error" {
    const alloc = std.testing.allocator;

    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "",
        .content = "Test content",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = add_skill_mod.executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<created>false</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Description cannot be empty") != null);
}

test "add_skill - empty content returns error" {
    const alloc = std.testing.allocator;

    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = add_skill_mod.executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<created>false</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Content cannot be empty") != null);
}

test "add_skill - tool definition includes is_global parameter" {
    const tool_def = add_skill_mod.add_skill_tool;

    // Find is_global in the properties
    var found_is_global = false;
    inline for (tool_def.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "is_global")) {
            found_is_global = true;
            try std.testing.expect(std.mem.eql(u8, prop.type, "boolean"));
        }
    }
    try std.testing.expect(found_is_global);
}

test "add_skill - tool definition has correct required fields" {
    const tool_def = add_skill_mod.add_skill_tool;

    // Should have name, description, content as required (not is_global)
    const required = tool_def.function.parameters.required;
    try std.testing.expect(required.len == 3);
    try std.testing.expect(std.mem.eql(u8, required[0], "name"));
    try std.testing.expect(std.mem.eql(u8, required[1], "description"));
    try std.testing.expect(std.mem.eql(u8, required[2], "content"));
}

test "add_skill - is_global defaults to false" {
    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "Test content",
    };
    try std.testing.expect(input.is_global == false);
}

test "add_skill - buildSkillContent with special characters" {
    const alloc = std.testing.allocator;

    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "Test \"description\" with quotes",
        .content = "Test content with\\backslash",
        .is_global = false,
    };

    const content = add_skill_mod.buildSkillContent(alloc, input);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "name: test-skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "description: \"Test \\\"description\\\" with quotes\"") != null);
}

test "add_skill - executeAddSkillToString validates empty content" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "",  // Empty content should fail
        .is_global = false,
    };

    const output = add_skill_mod.executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<created>false</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Content cannot be empty") != null);
}

test "add_skill - buildSkillContent escapes special characters" {
    const alloc = std.testing.allocator;

    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "Test \"description\" with quotes and\\backslash",
        .content = "Test content",
        .is_global = false,
    };

    const content = add_skill_mod.buildSkillContent(alloc, input);
    defer alloc.free(content);

    // Should contain escaped description
    try std.testing.expect(std.mem.indexOf(u8, content, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\\\\") != null);
}

// ---------------------------------------------------------------------------
// Overwrite-contract regression tests (added 2026-08-15)
//
// add_skill writes the skill file via `std.Io.Dir.createFileAbsolute(io,
// skill_file, .{})` (add_skill.zig:121) — that call relies on the default
// `truncate: bool = true` to OVERWRITE (not fail-with-FileAlreadyExists,
// not append-to) an existing skill with the same name. These tests pin
// that contract end-to-end: re-running add_skill with the same `name`
// must produce the new skill content, with no leftover bytes from the
// first call.
//
// Why this matters: when the LLM refines a skill (e.g. updates its
// description based on user feedback), it re-runs add_skill with the
// same name — a regression that left the old bytes appended would
// silently corrupt the skill file.
// ---------------------------------------------------------------------------

test "add_skill - re-running with same name OVERWRITES (truncates, no append)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-overwrite-skill";
    const tmp_path = "/tmp/nalar-add-skill-overwrite-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{
        tmp_path, ".nalar", "skills", skill_name, "SKILL.MD",
    });
    defer alloc.free(skill_file_path);

    // First add_skill: write a long skill body
    const first_input = add_skill_mod.AddSkillInput{
        .name = skill_name,
        .description = "First version description",
        .content = "# First version\n\nThis is the original long body that should be completely replaced on overwrite.",
        .create_with_dir = true,
        .is_global = false,
    };
    const first_output = add_skill_mod.executeAddSkillToString(alloc, io, tmp_path, null, first_input);
    defer alloc.free(first_output);
    try std.testing.expect(std.mem.indexOf(u8, first_output, "<created>true</created>") != null);

    // Sanity-check the first version landed on disk
    const first_read = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(first_read);
    try std.testing.expect(std.mem.indexOf(u8, first_read, "First version description") != null);

    // Second add_skill: write a SHORTER skill body with the SAME name.
    // If the createFile call is buggy and appends, the file would
    // contain BOTH versions concatenated.
    const second_input = add_skill_mod.AddSkillInput{
        .name = skill_name,
        .description = "Second desc",
        .content = "v2",
        .create_with_dir = true,
        .is_global = false,
    };
    const second_output = add_skill_mod.executeAddSkillToString(alloc, io, tmp_path, null, second_input);
    defer alloc.free(second_output);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "<created>true</created>") != null);

    // Read back — must contain ONLY second-version markers, NO first-version
    const second_read = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(second_read);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "Second desc") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "v2") != null);
    // CRITICAL: no leftover from first call — would prove append-mode corruption
    try std.testing.expect(std.mem.indexOf(u8, second_read, "First version description") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "First version\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "should be completely replaced") == null);
}

test "add_skill - local creation (is_global=false) writes to .nalar/skills/<name>/SKILL.MD" {
    // Regression test for use-after-free bug: when is_global=false, skills_dir
    // was being freed too early (defer was scoped to the else block), causing
    // path.join to use a dangling pointer. The file would either not be
    // created or be created in the wrong place.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-local-skill";
    const tmp_path = "/tmp/nalar-add-skill-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const input = add_skill_mod.AddSkillInput{
        .name = skill_name,
        .description = "Test description for local skill",
        .content = "# Test skill content\n\nThis is a test.",
        .create_with_dir = true,
        .is_global = false,
    };

    const output = add_skill_mod.executeAddSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);

    // Verify the success response
    try std.testing.expect(std.mem.indexOf(u8, output, "<created>true</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, skill_name) != null);

    // Verify the file was actually created at the correct path:
    // <tmp_path>/.nalar/skills/<skill_name>/SKILL.MD
    // Check that the directory structure exists (this would fail with the old bug
    // because createDirPath was called with a freed-and-reused pointer)
    const dir_check = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".nalar", "skills", skill_name });
    defer alloc.free(dir_check);
    const dir_exists = blk: {
        std.Io.Dir.cwd().access(io, dir_check, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(dir_exists);

    // Check that the SKILL.MD file exists
    const file_check = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".nalar", "skills", skill_name, "SKILL.MD" });
    defer alloc.free(file_check);
    const file_exists = blk: {
        std.Io.Dir.cwd().access(io, file_check, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(file_exists);

    // Read the file and verify it has the expected content
    const file_content = try std.Io.Dir.cwd().readFileAlloc(io, file_check, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(file_content);

    try std.testing.expect(std.mem.indexOf(u8, file_content, "name: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, skill_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "Test description for local skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "Test skill content") != null);
}
