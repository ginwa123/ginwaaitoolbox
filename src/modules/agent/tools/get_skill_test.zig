const std = @import("std");
const get_skill = @import("get_skill.zig");

// Helper to check if string contains substring
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "get_skill_tool - has correct tool definition" {
    try std.testing.expectEqualStrings("get_skill", get_skill.get_skill_tool.function.name);
    try std.testing.expect(get_skill.get_skill_tool.function.parameters.properties.len == 3);
}

test "GetSkillInput - has correct defaults" {
    const input = get_skill.GetSkillInput{};
    try std.testing.expect(input.skill_name == null);
    try std.testing.expect(input.path == null);
    try std.testing.expect(input.is_global == false);
}

test "GetSkillInput - skill_name and path can be set" {
    const input = get_skill.GetSkillInput{
        .skill_name = "test-skill",
        .path = "/some/path",
    };
    try std.testing.expectEqualStrings("test-skill", input.skill_name.?);
    try std.testing.expectEqualStrings("/some/path", input.path.?);
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

test "execute_get_skill_to_string - missing skill_name and path returns InvalidInput" {
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

test "execute_get_skill_to_string - skill-not-found output has no freed-memory fill bytes (use-after-free regression)" {
    // Regression test for the use-after-free bug in loadSkillByName.
    //
    // The previous implementation copied `skill.name` slice headers into an
    // intermediate `all_skills: ArrayList([]const u8)`, then
    // `defer free_skills_list(allocator, ...)` freed the backing memory. The
    // subsequent loop read 0xAA-filled freed memory (Zig debug allocator's
    // free-fill pattern) instead of real skill names, producing the garbled
    // `<skill>...</skill>` entries that look like an encoding bug.
    //
    // We point HOME at a temp dir containing a known global skill, then call
    // `execute_get_skill_to_string` with a non-existent name. We assert that
    // (a) the output has no 0xAA bytes anywhere, and (b) our known skill
    // name appears in the `available_skills` list — proving the data is real
    // (not freed memory).
    //
    // We use HOME (not cwd) because `get_local_skills_path_from_io` relies
    // on `std.Io.Dir.cwd().realPath`, which is unreliable under
    // `std.testing.io`. The HOME path is built from the env var alone, with
    // no realPath call, so it's stable in tests.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const unique_skill_name = "_regression_uaf_get_skill_test";
    const tmp_home = "/tmp/nalar-uaf-test-home";
    const global_skills_dir = "/tmp/nalar-uaf-test-home/.config/nalar/skills";

    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ global_skills_dir, unique_skill_name });
    defer alloc.free(skill_dir_path);
    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    // Clean up any leftover from a previous failed run.
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    // Create the global skill under the temp HOME.
    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_content =
        \\---
        \\name: _regression_uaf_get_skill_test
        \\description: "Regression test skill for use-after-free in loadSkillByName"
        \\---
        \\
        \\# Test content
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, skill_file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, skill_content);
    }

    // Set up env with HOME pointing to our temp dir.
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    // Call execute_get_skill_to_string with a non-existent name.
    const output = try get_skill.execute_get_skill_to_string(
        alloc,
        io,
        .{ .skill_name = "definitely-not-a-real-skill-xyz" },
        &env,
    );
    defer alloc.free(output);

    // Sanity: response structure is correct.
    try std.testing.expect(contains(output, "<loaded>false</loaded>"));
    try std.testing.expect(contains(output, "<error>Skill not found</error>"));
    try std.testing.expect(contains(output, "<available_skills>"));
    try std.testing.expect(contains(output, "</available_skills>"));

    // The known skill name must appear in the available_skills list,
    // proving the data is real (not freed memory).
    try std.testing.expect(contains(output, unique_skill_name));

    // CRITICAL: no 0xAA bytes anywhere in the output. 0xAA is the Zig
    // debug allocator's free-fill byte — its presence is a definitive
    // marker of a use-after-free.
    try std.testing.expect(std.mem.indexOfScalar(u8, output, 0xAA) == null);
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
        .{ .skill_name = unique_skill_name },
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

test "execute_get_skill_to_string - is_global=true finds skill in global path" {
    // Verifies that when is_global=true, a skill located in the global path
    // is still discoverable. We point HOME at a temp dir, create a known global
    // skill, and call execute_get_skill_to_string with is_global=true.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const unique_skill_name = "_regression_is_global_get_skill_test";
    const unique_marker = "IS_GLOBAL_MARKER_ABCDEF";
    const tmp_home = "/tmp/nalar-is-global-test-home";
    const global_skills_dir = "/tmp/nalar-is-global-test-home/.config/nalar/skills";

    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ global_skills_dir, unique_skill_name });
    defer alloc.free(skill_dir_path);
    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_content =
        \\---
        \\name: _regression_is_global_get_skill_test
        \\description: "is_global=true behavior test"
        \\---
        \\
        \\# Test content with IS_GLOBAL_MARKER_ABCDEF
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

    // With is_global=true, the global-only skill must be found.
    const output = try get_skill.execute_get_skill_to_string(
        alloc,
        io,
        .{ .skill_name = unique_skill_name, .is_global = true },
        &env,
    );
    defer alloc.free(output);

    try std.testing.expect(contains(output, "<loaded>true</loaded>"));
    try std.testing.expect(contains(output, unique_skill_name));
    try std.testing.expect(contains(output, unique_marker));
}

test "execute_get_skill_to_string - is_global=true returns not-found for missing global skill" {
    // With is_global=true, a non-existent skill should produce
    // <loaded>false</loaded> with available_skills listing only global skills
    // (local must be excluded from the suggestions list).
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const known_global = "_regression_is_global_known_in_list";
    const tmp_home = "/tmp/nalar-is-global-list-test-home";
    const global_skills_dir = "/tmp/nalar-is-global-list-test-home/.config/nalar/skills";

    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ global_skills_dir, known_global });
    defer alloc.free(skill_dir_path);
    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_content =
        \\---
        \\name: _regression_is_global_known_in_list
        \\description: "is_global list test"
        \\---
        \\
        \\# body
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
        .{ .skill_name = "definitely-not-a-real-skill-zzz", .is_global = true },
        &env,
    );
    defer alloc.free(output);

    try std.testing.expect(contains(output, "<loaded>false</loaded>"));
    try std.testing.expect(contains(output, "<error>Skill not found</error>"));
    try std.testing.expect(contains(output, "<available_skills>"));
    // The known global skill should be in the list (proves global is searched).
    try std.testing.expect(contains(output, known_global));
    // No 0xAA bytes - guards against use-after-free regression.
    try std.testing.expect(std.mem.indexOfScalar(u8, output, 0xAA) == null);
}
