const std = @import("std");
const builtin = @import("builtin");

/// Maximum size for skills.md file (100KB)
const MAX_SKILLS_SIZE: usize = 100 * 1024;

/// App name for config directory
const APP_NAME = "zigginagentic";

/// Local skills directory and filename
const LOCAL_SKILLS_DIR = ".zigginagentic/skills";
const SKILLS_FILENAME = "skill.md";

/// Deprecated: Use resolveSkillsPath() instead.
/// This constant is kept for backwards compatibility with *FromPath functions.
pub const SKILLS_PATH = "src/modules/agent/tools/skills.md";

/// Skill information structure
pub const SkillInfo = struct {
    name: []const u8,
    description: []const u8,
};

/// Get the local skills path (cwd/.zigginagentic/skills/skill.md)
/// Returns allocated string that caller must free, or null if cwd unavailable
pub fn getLocalSkillsPath(allocator: std.mem.Allocator) ?[]const u8 {
    // Get current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        std.log.debug("Could not get current working directory", .{});
        return null;
    };

    // Build path: cwd/.zigginagentic/skills/skill.md
    const path = std.fs.path.join(allocator, &[_][]const u8{
        cwd,
        LOCAL_SKILLS_DIR,
        SKILLS_FILENAME,
    }) catch {
        std.log.debug("Could not build local skills path", .{});
        return null;
    };

    return path;
}

/// Get the global skills path following XDG standards
/// Linux: ~/.config/zigginagentic/skills/skill.md
/// macOS: ~/Library/Application Support/zigginagentic/skills/skill.md
/// Windows: %APPDATA%/zigginagentic/skills/skill.md
/// Returns allocated string that caller must free, or null if home/env not found
pub fn getGlobalSkillsPath(allocator: std.mem.Allocator) ?[]const u8 {
    var config_dir: ?[]const u8 = null;
    var needs_free: bool = false;

    switch (builtin.os.tag) {
        .windows => {
            const appdata = std.posix.getenv("APPDATA") orelse {
                std.log.debug("APPDATA environment variable not set", .{});
                return null;
            };
            config_dir = std.fs.path.join(allocator, &[_][]const u8{ appdata, APP_NAME }) catch null;
            if (config_dir != null) needs_free = true;
        },
        .macos => {
            const home = std.posix.getenv("HOME") orelse {
                std.log.debug("HOME environment variable not set", .{});
                return null;
            };
            config_dir = std.fs.path.join(allocator, &[_][]const u8{
                home, "Library", "Application Support", APP_NAME,
            }) catch null;
            if (config_dir != null) needs_free = true;
        },
        else => { // Linux, FreeBSD, etc.
            // XDG_CONFIG_HOME or default to ~/.config
            if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg_config| {
                config_dir = std.fs.path.join(allocator, &[_][]const u8{ xdg_config, APP_NAME }) catch null;
                if (config_dir != null) needs_free = true;
            } else {
                const home = std.posix.getenv("HOME") orelse {
                    std.log.debug("HOME environment variable not set", .{});
                    return null;
                };
                config_dir = std.fs.path.join(allocator, &[_][]const u8{ home, ".config", APP_NAME }) catch null;
                if (config_dir != null) needs_free = true;
            }
        },
    }

    const dir = config_dir orelse return null;
    defer if (needs_free) allocator.free(dir);

    // Build full path: config_dir/skills/skill.md
    const path = std.fs.path.join(allocator, &[_][]const u8{
        dir,
        "skills",
        SKILLS_FILENAME,
    }) catch {
        std.log.debug("Could not build global skills path", .{});
        return null;
    };

    return path;
}

/// Resolve the skills path by checking local first, then global
/// Returns allocated string that caller must free, or null if neither exists
pub fn resolveSkillsPath(allocator: std.mem.Allocator) ?[]const u8 {
    // Try local path first
    if (getLocalSkillsPath(allocator)) |local_path| {
        // Check if file exists
        const exists = blk: {
            std.fs.cwd().access(local_path, .{}) catch {
                break :blk false;
            };
            break :blk true;
        };
        if (exists) {
            return local_path;
        }
        allocator.free(local_path);
    }

    // Try global path
    if (getGlobalSkillsPath(allocator)) |global_path| {
        // Check if file exists
        const exists = blk: {
            std.fs.cwd().access(global_path, .{}) catch {
                break :blk false;
            };
            break :blk true;
        };
        if (exists) {
            return global_path;
        }
        allocator.free(global_path);
    }

    return null;
}

/// Free a skills path allocated by getLocalSkillsPath, getGlobalSkillsPath, or resolveSkillsPath
pub fn freeSkillsPath(allocator: std.mem.Allocator, path: []const u8) void {
    allocator.free(path);
}

/// Load skills content from skills.md file
/// Returns allocated string with skills content, or empty string if file not found/invalid
/// Caller owns the returned memory and must free it with allocator.free()
pub fn loadSkills(allocator: std.mem.Allocator) []const u8 {
    // Try to resolve path
    if (resolveSkillsPath(allocator)) |path| {
        defer allocator.free(path);
        return loadSkillsFromPath(allocator, path);
    }
    // Fallback to hardcoded path for backwards compatibility
    return loadSkillsFromPath(allocator, SKILLS_PATH);
}

/// Load skills content from a specific path
/// Returns allocated string with skills content, or empty string if file not found/invalid
/// Caller owns the returned memory and must free it with allocator.free()
pub fn loadSkillsFromPath(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    // Open file
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        // Log warning but don't crash - skills are optional
        std.log.warn("Could not open skills file at {s}: {s}", .{ path, @errorName(err) });
        return allocator.dupe(u8, "") catch "";
    };
    defer file.close();

    // Check file size
    const stat = file.stat() catch |err| {
        std.log.warn("Could not stat skills file at {s}: {s}", .{ path, @errorName(err) });
        return allocator.dupe(u8, "") catch "";
    };

    if (stat.size > MAX_SKILLS_SIZE) {
        std.log.warn("Skills file too large ({} bytes), max is {} bytes", .{ stat.size, MAX_SKILLS_SIZE });
        return allocator.dupe(u8, "") catch "";
    }

    // Read file content
    const content = file.readToEndAlloc(allocator, MAX_SKILLS_SIZE) catch |err| {
        std.log.warn("Could not read skills file at {s}: {s}", .{ path, @errorName(err) });
        return allocator.dupe(u8, "") catch "";
    };

    // Return empty string if content is empty or whitespace only
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    if (trimmed.len == 0) {
        allocator.free(content);
        return allocator.dupe(u8, "") catch "";
    }

    return content;
}

/// Parse a specific skill from skills.md file
/// Returns allocated string with skill content, or null if not found
/// Caller owns the returned memory and must free it with allocator.free()
pub fn parseSkill(allocator: std.mem.Allocator, skill_name: []const u8) ?[]const u8 {
    // Try to resolve path
    if (resolveSkillsPath(allocator)) |path| {
        defer allocator.free(path);
        return parseSkillFromPath(allocator, path, skill_name);
    }
    // Fallback to hardcoded path for backwards compatibility
    return parseSkillFromPath(allocator, SKILLS_PATH, skill_name);
}

/// Parse a specific skill from a specific path
/// Returns allocated string with skill content, or null if not found
/// Caller owns the returned memory and must free it with allocator.free()
pub fn parseSkillFromPath(allocator: std.mem.Allocator, path: []const u8, skill_name: []const u8) ?[]const u8 {
    // Load the full content
    const content = loadSkillsFromPath(allocator, path);
    defer allocator.free(content);

    if (content.len == 0) return null;

    // Find the skill delimiter: <!-- SKILL: name -->
    const start_marker = "<!-- SKILL: ";
    const end_marker = " -->";
    const end_skill_marker = "<!-- END_SKILL -->";

    var pos: usize = 0;
    while (pos < content.len) {
        // Find start marker
        const start_idx = std.mem.indexOf(u8, content[pos..], start_marker) orelse break;
        const abs_start_idx = pos + start_idx;

        // Find the end of the start marker (the " -->" part)
        const marker_end = std.mem.indexOf(u8, content[abs_start_idx..], end_marker) orelse break;
        const name_start = abs_start_idx + start_marker.len;
        const name_end = abs_start_idx + marker_end;
        const found_name = content[name_start..name_end];

        // Check if this is the skill we're looking for
        if (std.mem.eql(u8, found_name, skill_name)) {
            // Find the end of this skill
            const content_start = abs_start_idx + marker_end + end_marker.len;
            const end_idx = std.mem.indexOf(u8, content[content_start..], end_skill_marker) orelse break;
            const skill_content = content[content_start .. content_start + end_idx];

            // Trim whitespace and return
            const trimmed = std.mem.trim(u8, skill_content, " \t\n\r");
            return allocator.dupe(u8, trimmed) catch null;
        }

        // Move past this skill
        const content_start = abs_start_idx + marker_end + end_marker.len;
        const end_idx = std.mem.indexOf(u8, content[content_start..], end_skill_marker) orelse break;
        pos = content_start + end_idx + end_skill_marker.len;
    }

    return null;
}

/// List all available skills from skills.md file
/// Returns allocated array of SkillInfo structs
/// Caller owns the returned memory and must free it with allocator.free()
pub fn listSkills(allocator: std.mem.Allocator) []SkillInfo {
    // Try to resolve path
    if (resolveSkillsPath(allocator)) |path| {
        defer allocator.free(path);
        return listSkillsFromPath(allocator, path);
    }
    // Fallback to hardcoded path for backwards compatibility
    return listSkillsFromPath(allocator, SKILLS_PATH);
}

/// List all available skills from a specific path
/// Returns allocated array of SkillInfo structs
/// Caller owns the returned memory and must free it with allocator.free()
pub fn listSkillsFromPath(allocator: std.mem.Allocator, path: []const u8) []SkillInfo {
    // Load the full content
    const content = loadSkillsFromPath(allocator, path);
    defer allocator.free(content);

    if (content.len == 0) return &.{};

    // Count skills first
    const start_marker = "<!-- SKILL: ";
    const end_marker = " -->";
    const end_skill_marker = "<!-- END_SKILL -->";

    var count: usize = 0;
    var pos: usize = 0;
    while (pos < content.len) {
        const start_idx = std.mem.indexOf(u8, content[pos..], start_marker) orelse break;
        const abs_start_idx = pos + start_idx;
        const marker_end = std.mem.indexOf(u8, content[abs_start_idx..], end_marker) orelse break;
        const content_start = abs_start_idx + marker_end + end_marker.len;
        const end_idx = std.mem.indexOf(u8, content[content_start..], end_skill_marker) orelse break;
        pos = content_start + end_idx + end_skill_marker.len;
        count += 1;
    }

    if (count == 0) return &.{};

    // Allocate array
    var skills = allocator.alloc(SkillInfo, count) catch return &.{};

    // Parse skills
    pos = 0;
    var idx: usize = 0;
    while (pos < content.len and idx < count) {
        const start_idx = std.mem.indexOf(u8, content[pos..], start_marker) orelse break;
        const abs_start_idx = pos + start_idx;

        const marker_end = std.mem.indexOf(u8, content[abs_start_idx..], end_marker) orelse break;
        const name_start = abs_start_idx + start_marker.len;
        const name_end = abs_start_idx + marker_end;
        const skill_name = content[name_start..name_end];

        const content_start = abs_start_idx + marker_end + end_marker.len;
        const end_idx = std.mem.indexOf(u8, content[content_start..], end_skill_marker) orelse break;
        const skill_content = content[content_start .. content_start + end_idx];

        // Extract description from first line after heading
        const trimmed_content = std.mem.trim(u8, skill_content, " \t\n\r");
        var description: []const u8 = "";

        // Find the first non-heading line for description
        var line_start: usize = 0;
        while (line_start < trimmed_content.len) {
            const line_end = std.mem.indexOf(u8, trimmed_content[line_start..], "\n") orelse trimmed_content.len - line_start;
            const line = std.mem.trim(u8, trimmed_content[line_start .. line_start + line_end], " \t\r");
            if (line.len > 0 and !std.mem.startsWith(u8, line, "#")) {
                description = line;
                break;
            }
            line_start += line_end + 1;
        }

        skills[idx] = .{
            .name = allocator.dupe(u8, skill_name) catch "",
            .description = allocator.dupe(u8, description) catch "",
        };
        idx += 1;

        pos = content_start + end_idx + end_skill_marker.len;
    }

    return skills;
}

/// Free a skills array allocated by listSkills
pub fn freeSkillsList(allocator: std.mem.Allocator, skills_list: []SkillInfo) void {
    for (skills_list) |skill| {
        allocator.free(skill.name);
        allocator.free(skill.description);
    }
    allocator.free(skills_list);
}
