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
