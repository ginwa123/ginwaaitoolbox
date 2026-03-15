const std = @import("std");
const builtin = @import("builtin");

/// Maximum size for skills.md file (100KB)
const MAX_SKILLS_SIZE: usize = 100 * 1024;

/// App name for config directory
const APP_NAME = "nalar";

/// Local skills directory
const LOCAL_SKILLS_DIR = ".nalar/skills";

/// Skills file name inside each skill folder
const SKILL_FILE_NAME = "SKILL.MD";

/// Skill information structure
pub const SkillInfo = struct {
    name: []const u8,
    description: []const u8,
};

/// Parsed YAML frontmatter from a skill file
pub const ParsedFrontmatter = struct {
    name: []const u8,
    description: []const u8,
};

/// Parse YAML frontmatter from skill file content
/// Expected format:
/// ---
/// name: skill-name
/// description: "Skill description text"
/// ---
/// # Skill content follows...
///
/// Returns ParsedFrontmatter with allocated strings, or null if no valid frontmatter found.
/// Caller owns the returned memory and must free name and description.
/// Parse YAML frontmatter from skill file content
/// Expected format:
/// ---
/// name: skill-name
/// description: "Skill description text"
/// ---
/// # Skill content follows...
///
/// Returns allocated ParsedFrontmatter with owned name and description strings
/// Caller owns the returned memory and must free name and description.
fn parseYamlFrontmatter(allocator: std.mem.Allocator, content: []const u8) ?ParsedFrontmatter {
    // Find the first --- marker
    const first_newline = std.mem.indexOf(u8, content, "\n") orelse return null;
    const after_first_line = content[first_newline + 1 ..];

    // Find the closing --- marker
    const closing_marker = std.mem.indexOf(u8, after_first_line, "\n---") orelse return null;
    const frontmatter_content = after_first_line[0..closing_marker];

    // Parse name and description from frontmatter
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;

    var line_start: usize = 0;
    while (line_start < frontmatter_content.len) {
        const line_end = std.mem.indexOf(u8, frontmatter_content[line_start..], "\n") orelse frontmatter_content.len - line_start;
        const line = std.mem.trim(u8, frontmatter_content[line_start .. line_start + line_end], " \t\r");

        if (line.len == 0) {
            line_start += line_end + 1;
            continue;
        }

        // Parse "name:" or "description:" lines
        if (std.mem.startsWith(u8, line, "name:")) {
            const value = std.mem.trim(u8, line[5..], " \t");
            // Remove quotes if present, then allocate
            if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
                name = allocator.dupe(u8, value[1 .. value.len - 1]) catch return null;
            } else {
                name = allocator.dupe(u8, value) catch return null;
            }
        } else if (std.mem.startsWith(u8, line, "description:")) {
            const value = std.mem.trim(u8, line[12..], " \t");
            // Remove quotes if present, then allocate
            if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
                description = allocator.dupe(u8, value[1 .. value.len - 1]) catch return null;
            } else {
                description = allocator.dupe(u8, value) catch return null;
            }
        }

        line_start += line_end + 1;
    }
    const parsed_name = name orelse return null;
    const parsed_desc = description orelse "";

    return .{
        .name = parsed_name,
        .description = parsed_desc,
    };
}

/// Free a ParsedFrontmatter allocated by parseYamlFrontmatter
fn freeParsedFrontmatter(allocator: std.mem.Allocator, fm: ParsedFrontmatter) void {
    allocator.free(fm.name);
    allocator.free(fm.description);
}

/// Get the local skills directory path (.nalar/skills/)
/// Returns allocated string that caller must free, or null if cwd unavailable
pub fn getSkillsDirPath(allocator: std.mem.Allocator) ?[]const u8 {
    // Get current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        std.log.debug("Could not get current working directory", .{});
        return null;
    };

    // Build path: .nalar/skills/
    const path = std.fs.path.join(allocator, &[_][]const u8{
        cwd,
        LOCAL_SKILLS_DIR,
    }) catch {
        std.log.debug("Could not build local skills directory path", .{});
        return null;
    };

    return path;
}

/// List all skill files in the skills directory
/// Returns allocated array of file paths to SKILL.MD files inside skill folders
/// Empty files are excluded from the list
pub fn listSkillFiles(allocator: std.mem.Allocator) ?[][]const u8 {
    const dir_path = getSkillsDirPath(allocator) orelse return null;
    defer allocator.free(dir_path);

    // Open the skills directory
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.log.debug("Could not open skills directory at {s}: {s}", .{ dir_path, @errorName(err) });
        return null;
    };
    defer dir.close();

    // Collect skill file paths
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        // Only process directories
        if (entry.kind != .directory) {
            continue;
        }

        const folder_name = entry.name;

        // Build path to SKILL.MD inside the folder
        const skill_file_path = std.fs.path.join(allocator, &[_][]const u8{ dir_path, folder_name, SKILL_FILE_NAME }) catch continue;

        // Check if SKILL.MD exists and is non-empty
        const file = std.fs.cwd().openFile(skill_file_path, .{}) catch {
            allocator.free(skill_file_path);
            continue;
        };
        defer file.close();

        const stat = file.stat() catch {
            allocator.free(skill_file_path);
            continue;
        };

        // Skip empty files
        if (stat.size == 0) {
            allocator.free(skill_file_path);
            continue;
        }

        files.append(allocator, skill_file_path) catch {
            allocator.free(skill_file_path);
            continue;
        };
    }

    return files.toOwnedSlice(allocator) catch null;
}

/// Free a list of skill file paths
pub fn freeSkillFiles(allocator: std.mem.Allocator, files: [][]const u8) void {
    for (files) |file| {
        allocator.free(file);
    }
    allocator.free(files);
}

/// Get the local skills path (.nalar/skills/)
/// Returns allocated string that caller must free, or null if cwd unavailable
pub fn getLocalSkillsPath(allocator: std.mem.Allocator) ?[]const u8 {
    // Get current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        std.log.debug("Could not get current working directory", .{});
        return null;
    };

    // Build path: .nalar/skills/
    const dir_path = std.fs.path.join(allocator, &[_][]const u8{
        cwd,
        LOCAL_SKILLS_DIR,
    }) catch {
        std.log.debug("Could not build local skills path", .{});
        return null;
    };

    return dir_path;
}

/// Get the global skills path following XDG standards
/// Linux: ~/.config/nalar/skills/
/// macOS: ~/Library/Application Support/nalar/skills/
/// Windows: %APPDATA%/nalar/skills/
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
        }
    }

    const dir = config_dir orelse return null;
    defer if (needs_free) allocator.free(dir);

    // Build full path: config_dir/skills/
    const path = std.fs.path.join(allocator, &[_][]const u8{
        dir,
        "skills",
    }) catch {
        std.log.debug("Could not build global skills path", .{});
        return null;
    };

    return path;
}

/// Resolve the skills directory path by checking local first, then global
/// Returns allocated string that caller must free, or null if neither exists
pub fn resolveSkillsPath(allocator: std.mem.Allocator) ?[]const u8 {
    // Try local path first
    if (getLocalSkillsPath(allocator)) |local_path| {
        // Check if directory exists
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
        // Check if directory exists
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

/// Load skills content from a specific file path
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

/// Parse a specific skill from the skills directory by name
/// Returns allocated string with skill content, or null if not found
/// Caller owns the returned memory and must free it with allocator.free()
pub fn parseSkill(allocator: std.mem.Allocator, skill_name: []const u8) ?[]const u8 {
    return parseSkillFromDir(allocator, skill_name);
}

/// Parse a specific skill from the skills directory by name
/// Returns allocated string with skill content (full file including frontmatter), or null if not found
/// Caller owns the returned memory and must free it with allocator.free()
pub fn parseSkillFromDir(allocator: std.mem.Allocator, skill_name: []const u8) ?[]const u8 {
    const files = listSkillFiles(allocator) orelse return null;
    defer freeSkillFiles(allocator, files);

    for (files) |file_path| {
        const content = loadSkillsFromPath(allocator, file_path);
        if (content.len == 0) {
            allocator.free(content);
            continue;
        }

        if (parseYamlFrontmatter(allocator, content)) |parsed| {
            defer freeParsedFrontmatter(allocator, parsed);
            if (std.mem.eql(u8, parsed.name, skill_name)) {
                // Return the full content (including frontmatter)
                return content;
            }
        }
        allocator.free(content);
    }

    return null;
}

/// List all available skills from the skills directory
/// Returns allocated array of SkillInfo structs
/// Caller owns the returned memory and must free it with freeSkillsList()
pub fn listSkills(allocator: std.mem.Allocator) []SkillInfo {
    return listSkillsFromDir(allocator);
}

/// List all available skills from the skills directory
/// Returns allocated array of SkillInfo structs
/// Caller owns the returned memory and must free it with freeSkillsList()
pub fn listSkillsFromDir(allocator: std.mem.Allocator) []SkillInfo {
    const files = listSkillFiles(allocator) orelse return &.{};
    defer freeSkillFiles(allocator, files);

    if (files.len == 0) return &.{};

    // Collect skills with valid frontmatter
    var skills_list: std.ArrayList(SkillInfo) = .empty;
    defer skills_list.deinit(allocator);

    for (files) |file_path| {
        const content = loadSkillsFromPath(allocator, file_path);
        if (content.len == 0) {
            allocator.free(content);
            continue;
        }

        if (parseYamlFrontmatter(allocator, content)) |parsed| {
            skills_list.append(allocator, .{
                .name = parsed.name,
                .description = parsed.description,
            }) catch {
                freeParsedFrontmatter(allocator, parsed);
                allocator.free(content);
                continue;
            };
            // Note: parsed.name and parsed.description are now owned by skills_list
            allocator.free(content);
        } else {
            allocator.free(content);
        }
    }

    return skills_list.toOwnedSlice(allocator) catch &.{};
}

/// Free a skills array allocated by listSkills
pub fn freeSkillsList(allocator: std.mem.Allocator, skills_list: []SkillInfo) void {
    for (skills_list) |skill| {
        allocator.free(skill.name);
        allocator.free(skill.description);
    }
    allocator.free(skills_list);
}

test {
    _ = @import("skills_test.zig");
}
