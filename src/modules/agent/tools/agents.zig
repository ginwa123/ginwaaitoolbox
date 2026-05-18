const std = @import("std");
const builtin = @import("builtin");

/// Maximum size for NALAR.md file (100KB)
pub const MAX_AGENT_SIZE: usize = 100 * 1024;

/// App name for config directory
pub const APP_NAME = "nalar";

/// Local agents directory
pub const LOCAL_AGENTS_DIR = ".nalar/agents";

/// Agents file name inside each agent folder
pub const AGENT_FILE_NAME = "NALAR.md";

/// Agent information structure
pub const AgentInfo = struct {
    name: []const u8,
    description: []const u8,
};

/// Parsed YAML frontmatter from an agent file
pub const ParsedAgentFrontmatter = struct {
    name: []const u8,
    description: []const u8,
};

/// Parse YAML frontmatter from agent file content
/// Expected format:
/// ---
/// name: agent-name
/// description: "Agent description text"
/// ---
/// # Agent content follows...
///
/// Returns ParsedAgentFrontmatter with allocated strings, or null if no valid frontmatter found.
/// Caller owns the returned memory and must free name and description.
pub fn parseYamlFrontmatter(allocator: std.mem.Allocator, content: []const u8) ?ParsedAgentFrontmatter {
    // Find the first --- marker
    const first_newline = std.mem.indexOf(u8, content, "\n") orelse return null;
    const after_first_line = content[first_newline + 1 ..];

    // Find the closing --- marker
    const closing_marker = std.mem.indexOf(u8, after_first_line, "\n---");
    if (closing_marker == null) return null;
    const frontmatter_content = after_first_line[0..closing_marker.?];

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
    const parsed_name = name orelse {
        // Free description if it was allocated but name is missing
        if (description) |desc| {
            allocator.free(desc);
        }
        return null;
    };
    const parsed_desc = description orelse "";

    return .{
        .name = parsed_name,
        .description = parsed_desc,
    };
}

/// Free a ParsedAgentFrontmatter allocated by parseYamlFrontmatter
pub fn freeParsedFrontmatter(allocator: std.mem.Allocator, fm: ParsedAgentFrontmatter) void {
    allocator.free(fm.name);
    allocator.free(fm.description);
}

/// Get the local agents directory path (.nalar/agents/)
/// Returns allocated string that caller must free, or null if cwd unavailable
pub fn getLocalAgentsPath(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    // Get current working directory using Io
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch |err| {
        std.log.debug("Could not get current working directory: {s}", .{@errorName(err)});
        return null;
    };
    const cwd = cwd_buf[0..cwd_len];

    // Build path: .nalar/agents/
    const path = std.fs.path.join(allocator, &[_][]const u8{
        cwd,
        LOCAL_AGENTS_DIR,
    }) catch {
        std.log.debug("Could not build local agents directory path", .{});
        return null;
    };

    return path;
}

/// Get the global agents path following XDG standards
/// Linux: ~/.config/nalar/agents/
/// macOS: ~/Library/Application Support/nalar/agents/
/// Windows: %APPDATA%/nalar/agents/
/// Returns allocated string that caller must free, or null if home/env not found
pub fn getGlobalAgentsPath(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) ?[]const u8 {
    var config_dir: ?[]const u8 = null;
    var needs_free: bool = false;

    switch (builtin.os.tag) {
        .windows => {
            if (environment) |env| {
                const appdata = env.get("APPDATA") orelse {
                    std.log.debug("APPDATA environment variable not set", .{});
                    return null;
                };
                config_dir = std.fs.path.join(allocator, &[_][]const u8{ appdata, APP_NAME }) catch null;
                if (config_dir != null) needs_free = true;
            } else {
                std.log.debug("No environment provided", .{});
                return null;
            }
        },
        .macos => {
            if (environment) |env| {
                const home = env.get("HOME") orelse {
                    std.log.debug("HOME environment variable not set", .{});
                    return null;
                };
                config_dir = std.fs.path.join(allocator, &[_][]const u8{
                    home, "Library", "Application Support", APP_NAME,
                }) catch null;
                if (config_dir != null) needs_free = true;
            } else {
                std.log.debug("No environment provided", .{});
                return null;
            }
        },
        else => { // Linux, FreeBSD, etc.
            if (environment) |env| {
                // XDG_CONFIG_HOME or default to ~/.config
                if (env.get("XDG_CONFIG_HOME")) |xdg_config| {
                    config_dir = std.fs.path.join(allocator, &[_][]const u8{ xdg_config, APP_NAME }) catch null;
                    if (config_dir != null) needs_free = true;
                } else if (env.get("HOME")) |home| {
                    config_dir = std.fs.path.join(allocator, &[_][]const u8{ home, ".config", APP_NAME }) catch null;
                    if (config_dir != null) needs_free = true;
                }
            } else {
                std.log.debug("No environment provided", .{});
                return null;
            }
        },
    }

    const dir = config_dir orelse return null;
    defer if (needs_free) allocator.free(dir);

    // Build full path: config_dir/agents
    const path = std.fs.path.join(allocator, &[_][]const u8{
        dir,
        "agents",
    }) catch {
        std.log.debug("Could not build global agents path", .{});
        return null;
    };

    return path;
}

/// Resolve the agents directory path by checking local first, then global
/// Returns allocated string that caller must free, or null if neither exists
pub fn resolveAgentsPath(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map) ?[]const u8 {
    // Try local path first
    if (getLocalAgentsPath(allocator, io)) |local_path| {
        // Check if directory exists
        const exists = blk: {
            std.Io.Dir.cwd().access(io, local_path, .{}) catch {
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
    if (getGlobalAgentsPath(allocator, environment)) |global_path| {
        // Check if directory exists
        const exists = blk: {
            std.Io.Dir.cwd().access(io, global_path, .{}) catch {
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

/// Free an agents path allocated by getLocalAgentsPath, getGlobalAgentsPath, or resolveAgentsPath
pub fn freeAgentsPath(allocator: std.mem.Allocator, path: []const u8) void {
    allocator.free(path);
}

/// List all agent files in the agents directory
/// Returns allocated array of file paths to NALAR.md files inside agent folders
/// Empty files are excluded from the list
pub fn listAgentFiles(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map) ?[][]const u8 {
    const dir_path = resolveAgentsPath(allocator, io, environment) orelse return null;
    defer allocator.free(dir_path);

    // Open the agents directory
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.debug("Could not open agents directory at {s}: {s}", .{ dir_path, @errorName(err) });
        return null;
    };
    defer std.Io.Dir.close(dir, io);

    // Collect agent file paths
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        // Only process directories
        if (entry.kind != .directory) {
            continue;
        }

        const folder_name = entry.name;

        // Build path to NALAR.md inside the folder
        const agent_file_path = std.fs.path.join(allocator, &[_][]const u8{ dir_path, folder_name, AGENT_FILE_NAME }) catch continue;

        // Check if NALAR.md exists and is non-empty
        const file = std.Io.Dir.cwd().openFile(io, agent_file_path, .{}) catch {
            allocator.free(agent_file_path);
            continue;
        };
        defer std.Io.File.close(file, io);

        const stat = std.Io.File.stat(file, io) catch {
            allocator.free(agent_file_path);
            continue;
        };

        // Skip empty files
        if (stat.size == 0) {
            allocator.free(agent_file_path);
            continue;
        }

        files.append(allocator, agent_file_path) catch {
            allocator.free(agent_file_path);
            continue;
        };
    }

    return files.toOwnedSlice(allocator) catch null;
}

/// Free a list of agent file paths
pub fn freeAgentFiles(allocator: std.mem.Allocator, files: [][]const u8) void {
    for (files) |file| {
        allocator.free(file);
    }
    allocator.free(files);
}

/// Load agent content from a specific file path
/// Returns allocated string with agent content, or null if file not found/invalid
/// Caller owns the returned memory and must free it with allocator.free()
pub fn loadAgentFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    // Open file
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        // Log warning but don't crash - agents are optional
        std.log.warn("Could not open agent file at {s}: {s}", .{ path, @errorName(err) });
        return null;
    };
    defer std.Io.File.close(file, io);

    // Check file size
    const stat = std.Io.File.stat(file, io) catch |err| {
        std.log.warn("Could not stat agent file at {s}: {s}", .{ path, @errorName(err) });
        return null;
    };

    if (stat.size > MAX_AGENT_SIZE) {
        std.log.warn("Agent file too large ({} bytes), max is {} bytes", .{ stat.size, MAX_AGENT_SIZE });
        return null;
    }

    // Read file content
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(MAX_AGENT_SIZE)) catch |err| {
        std.log.warn("Could not read agent file at {s}: {s}", .{ path, @errorName(err) });
        return null;
    };

    // Return null if content is empty or whitespace only
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    if (trimmed.len == 0) {
        allocator.free(content);
        return null;
    }

    return content;
}

/// Parse a specific agent from the agents directory by name
/// Returns allocated string with agent content, or null if not found
/// Caller owns the returned memory and must free it with allocator.free()
pub fn parseAgent(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map, agent_name: []const u8) ?[]const u8 {
    return parseAgentFromDir(allocator, io, environment, agent_name);
}

/// Parse a specific agent from the agents directory by name
/// Returns allocated string with agent content (full file including frontmatter), or null if not found
/// Caller owns the returned memory and must free it with allocator.free()
pub fn parseAgentFromDir(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map, agent_name: []const u8) ?[]const u8 {
    const files = listAgentFiles(allocator, io, environment) orelse return null;
    defer freeAgentFiles(allocator, files);

    for (files) |file_path| {
        const content = loadAgentFromPath(allocator, io, file_path);
        if (content == null) {
            continue;
        }
        const content_slice = content.?;

        if (parseYamlFrontmatter(allocator, content_slice)) |parsed| {
            defer freeParsedFrontmatter(allocator, parsed);
            if (std.mem.eql(u8, parsed.name, agent_name)) {
                // Return the full content (including frontmatter)
                return content_slice;
            }
        }
        allocator.free(content_slice);
    }

    return null;
}

/// List all available agents from the agents directory
/// Returns allocated array of AgentInfo structs
/// Caller owns the returned memory and must free it with freeAgentsList()
pub fn listAgents(allocator: std.mem.Allocator, io: std.Io) []AgentInfo {
    return listAgentsFromDir(allocator, io, null);
}

/// List all available agents from the agents directory
/// Returns allocated array of AgentInfo structs
/// Caller owns the returned memory and must free it with freeAgentsList()
pub fn listAgentsFromDir(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map) []AgentInfo {
    const files = listAgentFiles(allocator, io, environment) orelse return &.{};
    defer freeAgentFiles(allocator, files);

    if (files.len == 0) return &.{};

    // Collect agents with valid frontmatter
    var agents_list: std.ArrayList(AgentInfo) = .empty;
    defer agents_list.deinit(allocator);

    for (files) |file_path| {
        const content = loadAgentFromPath(allocator, io, file_path);
        if (content == null) {
            continue;
        }
        const content_slice = content.?;

        if (parseYamlFrontmatter(allocator, content_slice)) |parsed| {
            agents_list.append(allocator, .{
                .name = parsed.name,
                .description = parsed.description,
            }) catch {
                freeParsedFrontmatter(allocator, parsed);
                allocator.free(content_slice);
                continue;
            };
            // Note: parsed.name and parsed.description are now owned by agents_list
            allocator.free(content_slice);
        } else {
            allocator.free(content_slice);
        }
    }

    return agents_list.toOwnedSlice(allocator) catch &.{};
}

/// Free an agents array allocated by listAgents
pub fn freeAgentsList(allocator: std.mem.Allocator, agents_list: []AgentInfo) void {
    for (agents_list) |agent| {
        allocator.free(agent.name);
        allocator.free(agent.description);
    }
    allocator.free(agents_list);
}
