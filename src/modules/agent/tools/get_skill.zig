const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");

/// Input structure for get_skill tool
pub const GetSkillInput = struct {
    /// Load skill from file path. Accepts both absolute paths and relative
    /// paths (resolved against the session's current working directory).
    path: ?[]const u8 = null,
    /// Reserved for forward compatibility — currently has no effect because
    /// the only code path is `loadSkillFromPath`, which reads the file as-is.
    is_global: bool = false,
};

/// Result structure for get_skill tool
pub const GetSkillResult = struct {
    skill_name: []const u8,
    content: []const u8,
    loaded: bool,
    path: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

/// Tool definition for get_skill
pub const get_skill_tool_system_prompt =
    \\## Get Skill Tool — Behavior
    \\Use `get_skill` to load a skill's full instructions by exact file path (from `list_skills`).
    \\- The path is case-sensitive and ends in `SKILL.MD` — don't construct it from the name. Pass it verbatim.
    \\
;

pub const get_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "get_skill",
        .description = "Load a skill's full content from a file path. Use this when you need detailed guidance for a specific capability. Pass the file path (absolute or relative to the session's current working directory) via the `path` argument.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Load skill from file path. Accepts both absolute paths (e.g. /home/user/skill.md) and relative paths (resolved against the session's current working directory).",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "Reserved. Currently has no effect; the file is always loaded as-is from `path`.",
                },
            },
            .required = &.{ "path", "is_global" },
        },
        .system_prompt = get_skill_tool_system_prompt,
    },
};

/// Execute the get_skill tool
/// Returns an XML string with the skill content or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_get_skill_to_string(allocator: std.mem.Allocator, io: std.Io, input: GetSkillInput, environment: ?*const std.process.Environ.Map) ![]const u8 {
    _ = environment; // kept for signature compatibility; not used by the path-only code path
    const path = input.path orelse return error.InvalidInput;
    return loadSkillFromPath(allocator, io, path);
}

/// Load skill from a file path. Accepts both absolute and relative paths —
/// relative paths are resolved against the io's current working directory.
///
/// NOTE: this used to call `std.Io.Dir.openFileAbsolute` which has the
/// precondition `assert(path.isAbsolute(absolute_path))`. In debug builds
/// a non-absolute path triggered `unreachable`, killing the entire worker
/// process and bypassing every catch/try in the call chain
/// (see docs/plans/2025-01-15-get-skill-relative-path-panic.md). We now
/// use `cwd().openFile` which handles both cases — `openFileAbsolute` is
/// literally `openFile(.cwd(), ...)` + that assert.
fn loadSkillFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Failed to open file "{s}": {s}</error>
        , .{ path, @errorName(err) });
        return result;
    };
    defer std.Io.File.close(file, io);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(std.math.maxInt(usize))) catch |err| {
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Failed to read file "{s}": {s}</error>
        , .{ path, @errorName(err) });
        return result;
    };
    defer allocator.free(content);

    // Extract skill_name: prefer the YAML frontmatter `name:` field;
    // fall back to the file basename (without extension) for files that
    // don't use the frontmatter convention. In both branches we own the
    // returned slice and free it after the XML result is built.
    const skill_name: []const u8 = blk: {
        const filename = std.fs.path.basename(path);
        const ext = std.fs.path.extension(filename);
        const basename = filename[0 .. filename.len - ext.len];

        if (skills.parseYamlFrontmatter(allocator, content)) |fm| {
            defer allocator.free(fm.description);
            // Take ownership of fm.name; the defer below frees it after
            // allocPrint copies the bytes into the result.
            break :blk fm.name;
        }
        // basename points into `content` (freed below); dupe to give it
        // the same lifetime as the frontmatter branch.
        break :blk try allocator.dupe(u8, basename);
    };
    defer allocator.free(skill_name);

    const result = try std.fmt.allocPrint(allocator,
        \\<skill_name>{s}</skill_name>
        \\<content>{s}</content>
        \\<loaded>true</loaded>
    , .{ skill_name, content });
    return result;
}

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

test "execute_get_skill_to_string - absolute path loads skill file (loadSkillFromPath baseline)" {
    // Baseline: loadSkillFromPath with an absolute path must still work
    // after the openFileAbsolute → cwd().openFile swap. This guards against
    // a regression where the new code accidentally breaks the existing
    // absolute-path happy path.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/nalar-get-skill-abs-path-test";
    const skill_file = "/tmp/nalar-get-skill-abs-path-test/SKILL.MD";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    {
        const f = try std.Io.Dir.cwd().createFile(io, skill_file, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: absolute-path-test
            \\description: "Absolute path baseline test"
            \\---
            \\
            \\# Absolute path body
            \\
        );
    }

    const input = get_skill.GetSkillInput{ .path = skill_file };
    const output = try get_skill.execute_get_skill_to_string(alloc, io, input, null);
    defer alloc.free(output);

    try std.testing.expect(contains(output, "<loaded>true</loaded>"));
    try std.testing.expect(contains(output, "absolute-path-test"));
    try std.testing.expect(contains(output, "Absolute path body"));
}

test "execute_get_skill_to_string - relative path resolves against cwd (panic regression)" {
    // REGRESSION: previously, passing a relative path caused
    // std.Io.Dir.openFileAbsolute to `unreachable`-panic, killing the
    // entire worker process and bypassing every catch/try in the call
    // chain. See docs/plans/2025-01-15-get-skill-relative-path-panic.md
    //
    // We create a skill file at a relative path under cwd, then call
    // execute_get_skill_to_string with that relative path. Before the fix
    // this would SIGABRT; after the fix it loads successfully.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "tmp_get_skill_relative_test";
    const skill_file = "tmp_get_skill_relative_test/SKILL.MD";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    {
        const f = try std.Io.Dir.cwd().createFile(io, skill_file, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: relative-path-test
            \\description: "Relative path regression test"
            \\---
            \\
            \\# Relative path body
            \\
        );
    }

    const input = get_skill.GetSkillInput{ .path = skill_file };
    const output = try get_skill.execute_get_skill_to_string(alloc, io, input, null);
    defer alloc.free(output);

    try std.testing.expect(contains(output, "<loaded>true</loaded>"));
    try std.testing.expect(contains(output, "relative-path-test"));
    try std.testing.expect(contains(output, "Relative path body"));
}

test "execute_get_skill_to_string - non-existent path returns XML error (no panic, includes path)" {
    // REGRESSION: previously, a non-existent relative path would return a
    // generic "Failed to open file" with no path or OS error info — and if
    // a future caller ever wrapped openFileAbsolute without the same
    // defensive logic, it would panic and kill the worker. The fix
    // surfaces the path and the underlying OS error so the LLM can
    // self-correct on the next turn.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const missing_path = "this/path/does/not/exist/SKILL.MD";
    const input = get_skill.GetSkillInput{ .path = missing_path };
    const output = try get_skill.execute_get_skill_to_string(alloc, io, input, null);
    defer alloc.free(output);

    try std.testing.expect(contains(output, "<loaded>false</loaded>"));
    // The path must appear in the error so the LLM knows what was tried.
    try std.testing.expect(contains(output, missing_path));
    // Must NOT contain the word "unreachable" from the panic message.
    try std.testing.expect(std.mem.indexOf(u8, output, "unreachable") == null);
}
