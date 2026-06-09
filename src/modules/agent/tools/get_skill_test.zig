const std = @import("std");
const get_skill = @import("get_skill.zig");

// Helper to check if string contains substring
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "get_skill_tool - has correct tool definition" {
    try std.testing.expectEqualStrings("get_skill", get_skill.get_skill_tool.function.name);
    try std.testing.expect(get_skill.get_skill_tool.function.parameters.properties.len == 2);
}

test "GetSkillInput - has correct defaults" {
    const input = get_skill.GetSkillInput{};
    try std.testing.expect(input.path == null);
    try std.testing.expect(input.is_global == false);
}

test "GetSkillResult - has correct struct fields" {
    const result = get_skill.GetSkillResult{
        .skill_name = "test",
        .content = "Test content",
        .loaded = true,
    };
    try std.testing.expectEqualStrings("test", result.skill_name);
    try std.testing.expectEqualStrings("Test content", result.content);
    try std.testing.expect(result.loaded == true);
    try std.testing.expect(result.path == null);
    try std.testing.expect(result.err_msg == null);
    try std.testing.expect(result.available_skills == null);
}

test "execute_get_skill_to_string - missing path returns InvalidInput" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = get_skill.GetSkillInput{};
    const result = get_skill.execute_get_skill_to_string(alloc, io, input, null);
    try std.testing.expectError(error.InvalidInput, result);
}

test "get_skill_tool - description is descriptive" {
    // The tool description should explain what the tool does
    try std.testing.expect(get_skill.get_skill_tool.function.description.len > 10);
    try std.testing.expect(contains(get_skill.get_skill_tool.function.description, "skill"));
    try std.testing.expect(contains(get_skill.get_skill_tool.function.description, "content"));
}

test "execute_get_skill_to_string - loaded skill output preserves skill name" {
    // Sanity test: when the skill is found, the output contains the skill
    // name and content (not a use-after-free case, but worth verifying the
    // happy path still works after the refactor).
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const unique_skill_name = "_regression_uaf_get_skill_loaded_test";
    const unique_marker = "REGRESSION_MARKER_12345";
    const tmp_home = "/tmp/nalar-uaf-test-home-loaded";
    const global_skills_dir = "/tmp/nalar-uaf-test-home-loaded/.config/nalar/skills";

    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ global_skills_dir, unique_skill_name });
    defer alloc.free(skill_dir_path);
    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_content =
        \\---
        \\name: _regression_uaf_get_skill_loaded_test
        \\description: "Loaded-path regression test"
        \\---
        \\
        \\# Test content with REGRESSION_MARKER_12345
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, skill_file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, skill_content);
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const output = try get_skill.execute_get_skill_to_string(
        alloc,
        io,
        .{ .path = skill_file_path },
        &env,
    );
    defer alloc.free(output);

    try std.testing.expect(contains(output, "<loaded>true</loaded>"));
    try std.testing.expect(contains(output, unique_skill_name));
    try std.testing.expect(contains(output, unique_marker));
    try std.testing.expect(std.mem.indexOfScalar(u8, output, 0xAA) == null);
}

test "get_skill_tool - schema declares is_global property" {
    // Find the is_global property in the tool definition. This guards against
    // the field being accidentally removed from the schema.
    const props = get_skill.get_skill_tool.function.parameters.properties;
    var found_is_global = false;
    for (props) |prop| {
        if (std.mem.eql(u8, prop.name, "is_global")) {
            found_is_global = true;
            try std.testing.expectEqualStrings("boolean", prop.type);
            break;
        }
    }
    try std.testing.expect(found_is_global);
}
