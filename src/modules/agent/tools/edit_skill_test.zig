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
