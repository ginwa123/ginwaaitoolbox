const std = @import("std");
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");
const helpers = @import("helpers");

/// Maximum size for skills.md file (100KB)
const MAX_SKILLS_SIZE: usize = 100 * 1024;

/// App name for config directory
const APP_NAME = "nalar";

/// Cross-platform `/`-separator path concat. See memories.zig's `joinPath`
/// for the rationale — `std.fs.path.join` produces OS-native separators
/// (`\\` on Windows), which breaks test expectations that hardcode `/`.
fn joinPath(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return allocator.dupe(u8, name);
    const out = try allocator.alloc(u8, dir.len + 1 + name.len);
    @memcpy(out[0..dir.len], dir);
    out[dir.len] = '/';
    @memcpy(out[dir.len + 1 ..][0..name.len], name);
    return out;
}

fn joinPath3(allocator: std.mem.Allocator, a: []const u8, b: []const u8, c: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, a.len + 1 + b.len + 1 + c.len);
    var idx: usize = 0;
    @memcpy(out[idx..][0..a.len], a);
    idx += a.len;
    out[idx] = '/';
    idx += 1;
    @memcpy(out[idx..][0..b.len], b);
    idx += b.len;
    out[idx] = '/';
    idx += 1;
    @memcpy(out[idx..][0..c.len], c);
    return out;
}

fn joinPath4(allocator: std.mem.Allocator, a: []const u8, b: []const u8, c: []const u8, d: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, a.len + 1 + b.len + 1 + c.len + 1 + d.len);
    var idx: usize = 0;
    @memcpy(out[idx..][0..a.len], a);
    idx += a.len;
    out[idx] = '/';
    idx += 1;
    @memcpy(out[idx..][0..b.len], b);
    idx += b.len;
    out[idx] = '/';
    idx += 1;
    @memcpy(out[idx..][0..c.len], c);
    idx += c.len;
    out[idx] = '/';
    idx += 1;
    @memcpy(out[idx..][0..d.len], d);
    return out;
}

/// Local skills directory
const LOCAL_SKILLS_DIR = ".nalar/skills";

/// Skills file name inside each skill folder
const SKILL_FILE_NAME = "SKILL.MD";

/// Skill information structure
pub const SkillInfo = struct {
    name: []const u8,
    description: []const u8,
    /// `'||'`-joined tags from the frontmatter. Empty slice when the
    /// frontmatter has no `tags:` line — which is most of them.
    tags: []const u8,
    path: []const u8,
};

/// Parsed YAML frontmatter from a skill file
pub const ParsedFrontmatter = struct {
    name: []const u8,
    description: []const u8,
    /// `'||'`-joined. Always allocated (empty when absent) so every caller
    /// can free it unconditionally alongside name/description.
    tags: []const u8,
};

/// Parse YAML frontmatter from skill file content
/// Expected format:
/// ---
/// name: skill-name
/// description: "Skill description text"
/// ---
/// # Skill content follows...
///
/// Also parses an optional `tags:` line, in either the bracketed form the
/// skill prompt mandates (`tags: [workflow, api]`) or a bare comma list. The
/// result is `'||'`-joined, mirroring `agent_memories.tags`.
///
/// Returns allocated ParsedFrontmatter with owned name, description and tags
/// strings. Caller owns the returned memory — use `freeParsedFrontmatter`.
pub fn parseYamlFrontmatter(allocator: std.mem.Allocator, content: []const u8) ?ParsedFrontmatter {
    // Find the first --- marker
    const first_newline = std.mem.indexOf(u8, content, "\n") orelse return null;
    const after_first_line = content[first_newline + 1 ..];

    // Find the closing --- marker
    const closing_marker = std.mem.indexOf(u8, after_first_line, "\n---") orelse return null;
    const frontmatter_content = after_first_line[0..closing_marker];

    // Parse name, description and tags from frontmatter
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var tags: ?[]const u8 = null;

    var line_start: usize = 0;
    while (line_start < frontmatter_content.len) {
        const line_end = std.mem.indexOf(u8, frontmatter_content[line_start..], "\n") orelse frontmatter_content.len - line_start;
        const line = std.mem.trim(u8, frontmatter_content[line_start .. line_start + line_end], " \t\r");

        if (line.len == 0) {
            line_start += line_end + 1;
            continue;
        }

        // Parse "name:", "description:" or "tags:" lines
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
        } else if (std.mem.startsWith(u8, line, "tags:")) {
            tags = parseTagsValue(allocator, std.mem.trim(u8, line[5..], " \t")) catch return null;
        }

        line_start += line_end + 1;
    }
    const parsed_name = name orelse return null;
    const parsed_desc = description orelse "";
    // Always allocated, even when absent, so callers can free all three
    // unconditionally.
    const parsed_tags = tags orelse (allocator.dupe(u8, "") catch return null);

    return .{
        .name = parsed_name,
        .description = parsed_desc,
        .tags = parsed_tags,
    };
}

/// Normalise a raw `tags:` value to the `'||'`-joined stored form.
///
/// Accepts the bracketed list the skill prompt mandates (`[a, b]`), a bare
/// comma list (`a, b`), and already-quoted values. Empty in, empty out.
fn parseTagsValue(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
        value = value[1 .. value.len - 1];
    }
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
        value = value[1 .. value.len - 1];
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const tag = std.mem.trim(u8, part, " \t\"");
        if (tag.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(allocator, "||");
        try out.appendSlice(allocator, tag);
    }

    return out.toOwnedSlice(allocator);
}

/// Free a ParsedFrontmatter allocated by parseYamlFrontmatter
pub fn freeParsedFrontmatter(allocator: std.mem.Allocator, fm: ParsedFrontmatter) void {
    allocator.free(fm.name);
    allocator.free(fm.description);
    allocator.free(fm.tags);
}

/// Get the local skills directory path (.nalar/skills/)
/// Returns allocated string that caller must free, or null if cwd unavailable
pub fn get_skills_dir_path(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    // Get current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch {
        std.log.debug("Could not get current working directory", .{});
        return null;
    };
    const cwd = cwd_buf[0..cwd_len];

    // Build path: <cwd>/.nalar/skills/ — see joinPath for why we don't
    // use std.fs.path.join (it produces `\` separators on Windows).
    const path = joinPath(allocator, cwd, LOCAL_SKILLS_DIR) catch {
        std.log.debug("Could not build local skills directory path", .{});
        return null;
    };

    return path;
}

/// List all skill files in the skills directory
/// Returns allocated array of file paths to SKILL.MD files inside skill folders
/// Empty files are excluded from the list
pub fn list_skill_files(allocator: std.mem.Allocator, io: std.Io) ?[][]const u8 {
    const dir_path = get_skills_dir_path(allocator, io) orelse return null;
    defer allocator.free(dir_path);

    // Open the skills directory
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.debug("Could not open skills directory at {s}: {s}", .{ dir_path, @errorName(err) });
        return null;
    };
    defer std.Io.Dir.close(dir, io);

    // Collect skill file paths
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        // Only process directories
        if (entry.kind != .directory) {
            continue;
        }

        const folder_name = entry.name;

        // Build path to SKILL.MD inside the folder
        const skill_file_path = joinPath3(allocator, dir_path, folder_name, SKILL_FILE_NAME) catch continue;

        // Check if SKILL.MD exists and is non-empty
        const file = std.Io.Dir.cwd().openFile(io, skill_file_path, .{}) catch {
            allocator.free(skill_file_path);
            continue;
        };
        defer std.Io.File.close(file, io);

        const stat = std.Io.File.stat(file, io) catch {
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
pub fn free_skill_files(allocator: std.mem.Allocator, files: [][]const u8) void {
    for (files) |file| {
        allocator.free(file);
    }
    allocator.free(files);
}

/// Get the local skills path (.nalar/skills/)
/// Returns allocated string that caller must free, or null if cwd unavailable
pub fn get_local_skills_path(allocator: std.mem.Allocator) ?[]const u8 {
    // Get current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    // `std.posix.getcwd` was removed in Zig 0.16. Use the cross-platform
    // libc-backed `helpers.getcwd` wrapper (works on Linux/macOS/Windows
    // without requiring an `io: std.Io` runtime).
    const cwd = helpers.getcwd(&cwd_buf) orelse {
        std.log.debug("Could not get current working directory", .{});
        return null;
    };

    // Build path: <cwd>/.nalar/skills/ — see joinPath for the rationale.
    const dir_path = joinPath(allocator, cwd, LOCAL_SKILLS_DIR) catch {
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
pub fn get_global_skills_path(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) ?[]const u8 {
    // Use environment map if provided
    if (environment) |env| {
        return get_global_skills_path_from_env(allocator, env);
    }
    // No fallback - environment is required in this codebase
    return null;
}

/// Resolve the skills directory path by checking local first, then global
/// Returns allocated string that caller must free, or null if neither exists
pub fn resolve_skills_path(allocator: std.mem.Allocator) ?[]const u8 {
    // Try local path first
    if (get_local_skills_path(allocator)) |local_path| {
        // Check if directory exists
        const exists = helpers.fileExists(local_path);
        if (exists) {
            return local_path;
        }
        allocator.free(local_path);
    }

    // Try global path
    if (get_global_skills_path(allocator, null)) |global_path| {
        // Check if directory exists
        const exists = helpers.fileExists(global_path);
        if (exists) {
            return global_path;
        }
        allocator.free(global_path);
    }

    return null;
}

/// Free a skills path allocated by get_local_skills_path, get_global_skills_path, or resolve_skills_path
pub fn free_skills_path(allocator: std.mem.Allocator, path: []const u8) void {
    allocator.free(path);
}

/// Load skills content from a specific file path
/// Returns allocated string with skills content, or empty string if file not found/invalid
/// Caller owns the returned memory and must free it with allocator.free()
pub fn load_skills_from_path(allocator: std.mem.Allocator, io: std.Io, path: []const u8) []const u8 {
    // Open file
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        // Log warning but don't crash - skills are optional
        std.log.warn("Could not open skills file at {s}: {s}", .{ path, @errorName(err) });
        return allocator.dupe(u8, "") catch "";
    };
    defer std.Io.File.close(file, io);

    // Check file size
    const stat = std.Io.File.stat(file, io) catch |err| {
        std.log.warn("Could not stat skills file at {s}: {s}", .{ path, @errorName(err) });
        return allocator.dupe(u8, "") catch "";
    };

    if (stat.size > MAX_SKILLS_SIZE) {
        std.log.warn("Skills file too large ({} bytes), max is {} bytes", .{ stat.size, MAX_SKILLS_SIZE });
        return allocator.dupe(u8, "") catch "";
    }

    // Read file content
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(MAX_SKILLS_SIZE)) catch |err| {
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
/// If is_global is true, ONLY the global path (~/.config/nalar/skills/) is searched.
/// If is_global is false (default), both local (.nalar/skills/) and global paths
/// are searched, local first.
/// environment is required when is_global is true (or when global fallback is desired).
/// Returns allocated string with skill content (full file including frontmatter), or null if not found
/// Caller owns the returned memory and must free it with allocator.free()
pub fn parse_skill(allocator: std.mem.Allocator, io: std.Io, skill_name: []const u8, is_global: bool, environment: ?*const std.process.Environ.Map) ?[]const u8 {
    // When is_global is false, try local path first (.nalar/skills/)
    if (!is_global) {
        if (parse_skill_from_path(allocator, io, skill_name)) |content| {
            return content;
        }
    }

    // Try global path (~/.config/nalar/skills/) if environment provided
    if (environment) |env| {
        if (get_global_skills_path_from_env(allocator, env)) |global_path| {
            defer allocator.free(global_path);
            if (parse_skill_from_path_at(allocator, io, skill_name, global_path)) |content| {
                return content;
            }
        }
    }

    return null;
}

/// Parse a specific skill from a specific directory path
/// Returns allocated string with skill content, or null if not found
/// Caller owns the returned memory and must free it with allocator.free()
fn parse_skill_from_path_at(allocator: std.mem.Allocator, io: std.Io, skill_name: []const u8, dir_path: []const u8) ?[]const u8 {
    const files = list_skill_files_in_dir(allocator, io, dir_path) orelse return null;
    defer free_skill_files(allocator, files);

    for (files) |file_path| {
        const content = load_skills_from_path(allocator, io, file_path);
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

/// Parse a specific skill from the local skills directory (.nalar/skills/)
/// Returns allocated string with skill content, or null if not found
/// Caller owns the returned memory and must free it with allocator.free()
fn parse_skill_from_path(allocator: std.mem.Allocator, io: std.Io, skill_name: []const u8) ?[]const u8 {
    const files = list_skill_files(allocator, io) orelse return null;
    defer free_skill_files(allocator, files);

    for (files) |file_path| {
        const content = load_skills_from_path(allocator, io, file_path);
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
/// Caller owns the returned memory and must free it with free_skills_list()
pub fn list_skills(allocator: std.mem.Allocator, io: std.Io) []SkillInfo {
    return list_skills_from_dir(allocator, io);
}

/// List all available skills from the skills directory
/// Returns allocated array of SkillInfo structs
/// Caller owns the returned memory and must free it with free_skills_list()
pub fn list_skills_from_dir(allocator: std.mem.Allocator, io: std.Io) []SkillInfo {
    const files = list_skill_files(allocator, io) orelse return &.{};
    defer free_skill_files(allocator, files);

    if (files.len == 0) return &.{};

    // Collect skills with valid frontmatter
    var skills_list: std.ArrayList(SkillInfo) = .empty;
    defer skills_list.deinit(allocator);

    for (files) |file_path| {
        const content = load_skills_from_path(allocator, io, file_path);
        if (content.len == 0) {
            allocator.free(content);
            continue;
        }

        if (parseYamlFrontmatter(allocator, content)) |parsed| {
            const path_copy = allocator.dupe(u8, file_path) catch {
                freeParsedFrontmatter(allocator, parsed);
                allocator.free(content);
                continue;
            };
            // parsed.{name,description,tags} move into skills_list below, so
            // only path_copy is still ours to free on the failure path.
            skills_list.append(allocator, .{
                .name = parsed.name,
                .description = parsed.description,
                .tags = parsed.tags,
                .path = path_copy,
            }) catch {
                freeParsedFrontmatter(allocator, parsed);
                allocator.free(path_copy);
                allocator.free(content);
                continue;
            };
            allocator.free(content);
        } else {
            allocator.free(content);
        }
    }

    return skills_list.toOwnedSlice(allocator) catch &.{};
}

/// Free a skills array allocated by list_skills
pub fn free_skills_list(allocator: std.mem.Allocator, skills_list: []const SkillInfo) void {
    for (skills_list) |skill| {
        allocator.free(skill.name);
        allocator.free(skill.description);
        allocator.free(skill.tags);
        allocator.free(skill.path);
    }
    allocator.free(skills_list);
}

/// Get global skills path using environment map (not std.posix.getenv)
/// Linux: ~/.config/nalar/skills/ or $XDG_CONFIG_HOME/nalar/skills/
/// macOS: ~/Library/Application Support/nalar/skills/
/// Windows: %APPDATA%/nalar/skills/
/// Returns allocated string that caller must free, or null if home/env not found
pub fn get_global_skills_path_from_env(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) ?[]const u8 {
    // Try XDG_CONFIG_HOME first
    if (environment.get("XDG_CONFIG_HOME")) |xdg_config| {
        return joinPath3(allocator, xdg_config, APP_NAME, "skills") catch return null;
    }

    // Fall back to platform-specific defaults
    if (environment.get("HOME")) |home| {
        // Linux/macOS: ~/.config/<APP>/skills. On macOS the convention
        // is $HOME/Library/Application Support; keep the Unix-style
        // fallback for now (separate task to detect macOS).
        return joinPath4(allocator, home, ".config", APP_NAME, "skills") catch null;
    }

    return null;
}

/// Get local skills path (.nalar/skills/) using io
/// Returns allocated string that caller must free, or null if cwd unavailable
pub fn get_local_skills_path_from_io(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch |err| {
        std.log.debug("Could not get current working directory: {s}", .{@errorName(err)});
        return null;
    };
    const cwd = cwd_buf[0..cwd_len];

    return joinPath(allocator, cwd, LOCAL_SKILLS_DIR) catch null;
}

/// Get local skills path for a specific directory
/// Returns allocated string that caller must free, or null if path unavailable
pub fn get_local_skills_path_for_dir(allocator: std.mem.Allocator, dir_path: []const u8) ?[]const u8 {
    return joinPath(allocator, dir_path, LOCAL_SKILLS_DIR) catch null;
}

/// List all skill file paths in a specific directory
/// Returns allocated array of file paths to SKILL.MD files inside skill folders
/// Empty files are excluded from the list
pub fn list_skill_files_in_dir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ?[][]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.debug("Could not open skills directory at {s}: {s}", .{ dir_path, @errorName(err) });
        return null;
    };
    defer std.Io.Dir.close(dir, io);

    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;

        const skill_file_path = joinPath3(allocator, dir_path, entry.name, SKILL_FILE_NAME) catch continue;

        // Check if SKILL.MD exists and is non-empty
        const file = std.Io.Dir.cwd().openFile(io, skill_file_path, .{}) catch {
            allocator.free(skill_file_path);
            continue;
        };
        defer std.Io.File.close(file, io);

        const stat = std.Io.File.stat(file, io) catch {
            allocator.free(skill_file_path);
            continue;
        };

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

/// List all skills from a specific directory path
/// Returns allocated array of SkillInfo structs
/// Caller owns the returned memory and must free it with free_skills_list()
pub fn list_skills_from_dir_path(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) []SkillInfo {
    const files = list_skill_files_in_dir(allocator, io, dir_path) orelse return &[_]SkillInfo{};
    defer free_skill_files(allocator, files);

    if (files.len == 0) return &[_]SkillInfo{};

    var skills_list: std.ArrayList(SkillInfo) = .empty;
    defer skills_list.deinit(allocator);

    for (files) |file_path| {
        const content = load_skills_from_path(allocator, io, file_path);
        if (content.len == 0) {
            allocator.free(content);
            continue;
        }

        if (parseYamlFrontmatter(allocator, content)) |parsed| {
            const path_copy = allocator.dupe(u8, file_path) catch {
                freeParsedFrontmatter(allocator, parsed);
                allocator.free(content);
                continue;
            };
            // parsed.{name,description,tags} move into skills_list below, so
            // only path_copy is still ours to free on the failure path.
            skills_list.append(allocator, .{
                .name = parsed.name,
                .description = parsed.description,
                .tags = parsed.tags,
                .path = path_copy,
            }) catch {
                freeParsedFrontmatter(allocator, parsed);
                allocator.free(path_copy);
                allocator.free(content);
                continue;
            };
            allocator.free(content);
        } else {
            allocator.free(content);
        }
    }

    return skills_list.toOwnedSlice(allocator) catch &[_]SkillInfo{};
}

