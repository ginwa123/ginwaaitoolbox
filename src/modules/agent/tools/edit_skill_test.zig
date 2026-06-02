const std = @import("std");
const edit_skill_mod = @import("edit_skill.zig");

test "edit_skill - empty skill_name returns error" {
    const alloc = std.testing.allocator;

    const input = edit_skill_mod.EditSkillInput{
        .skill_name = "",
        .description = try alloc.dupe(u8, "New description"),
        .content = null,
        .is_global = false,
    };
    defer alloc.free(input.description.?);

    const io = std.testing.io;
    const output = try edit_skill_mod.executeEditSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<edited>false</edited>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Skill name cannot be empty") != null);
}

test "edit_skill - neither description nor content provided returns error" {
    const alloc = std.testing.allocator;

    const input = edit_skill_mod.EditSkillInput{
        .skill_name = "test-skill",
        .description = null,
        .content = null,
        .is_global = false,
    };

    const io = std.testing.io;
    const output = try edit_skill_mod.executeEditSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<edited>false</edited>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "At least one of description or content must be provided") != null);
}

test "edit_skill - tool definition includes is_global parameter" {
    const tool_def = edit_skill_mod.edit_skill_tool;

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

test "edit_skill - tool definition has skill_name as required" {
    const tool_def = edit_skill_mod.edit_skill_tool;

    // Should have skill_name as required (not description or content)
    const required = tool_def.function.parameters.required;
    try std.testing.expect(required.len == 1);
    try std.testing.expect(std.mem.eql(u8, required[0], "skill_name"));
}

test "edit_skill - is_global defaults to false" {
    const input = edit_skill_mod.EditSkillInput{
        .skill_name = "test-skill",
        .description = null,
        .content = null,
    };
    try std.testing.expect(input.is_global == false);
}

test "edit_skill - local edit (is_global=false) updates .nalar/skills/<name>/SKILL.MD" {
    // Regression test for use-after-free bug: when is_global=false, skills_dir
    // was being freed too early (defer was scoped to the else block), causing
    // path.join to use a dangling pointer. The file would either not be
    // updated or be updated in the wrong place.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-local-edit-skill";
    const tmp_path = "/tmp/nalar-edit-skill-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    // Pre-create a local skill file in the expected format
    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".nalar", "skills", skill_name });
    defer alloc.free(skill_dir_path);
    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    const original_content =
        \\---
        \\name: test-local-edit-skill
        \\description: "Original description"
        \\---
        \\
        \\# Original content
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, skill_file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, original_content);
    }

    // Now edit the local skill
    const new_description = "Updated description for local skill";
    const new_content = "# Updated content\n\nThis is the updated test.";

    const input = edit_skill_mod.EditSkillInput{
        .skill_name = skill_name,
        .description = new_description,
        .content = new_content,
        .is_global = false,
    };

    const output = try edit_skill_mod.executeEditSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);

    // Verify the success response
    try std.testing.expect(std.mem.indexOf(u8, output, "<edited>true</edited>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, skill_name) != null);

    // Read the file and verify it was actually updated with the new content
    const updated_file_content = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(updated_file_content);

    // New description and content should be present
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, new_description) != null);
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, "Updated content") != null);
    // Original description and content should be gone
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, "Original description") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, "Original content") == null);
}
