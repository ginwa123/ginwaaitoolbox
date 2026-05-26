const std = @import("std");
const remove_skill_mod = @import("remove_skill.zig");

test "remove_skill - empty skill_name returns error" {
    const alloc = std.testing.allocator;

    const input = remove_skill_mod.RemoveSkillInput{
        .skill_name = "",
        .session_id = "test-session",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = try remove_skill_mod.execute_remove_skill_to_string(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<removed>false</removed>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "skill_name cannot be empty") != null);
}

test "remove_skill - tool definition includes is_global parameter" {
    const tool_def = remove_skill_mod.remove_skill_tool;

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

test "remove_skill - tool definition has correct required fields" {
    const tool_def = remove_skill_mod.remove_skill_tool;

    // Should have skill_name and session_id as required (not is_global)
    const required = tool_def.function.parameters.required;
    try std.testing.expect(required.len == 2);
    try std.testing.expect(std.mem.eql(u8, required[0], "skill_name"));
    try std.testing.expect(std.mem.eql(u8, required[1], "session_id"));
}

test "remove_skill - is_global defaults to false" {
    const input = remove_skill_mod.RemoveSkillInput{
        .skill_name = "test-skill",
        .session_id = "test-session",
    };
    try std.testing.expect(input.is_global == false);
}
