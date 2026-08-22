const std = @import("std");
const schemas = @import("schemas.zig");
const nalarcore = @import("nalarcore");
const helpers = @import("helpers");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

// NOTE: This is a placeholder import. When agents.zig is available,
// replace this with: const agents = @import("agents.zig");
// For now, we implement placeholder functions that will be replaced.
const agents = struct {
    pub const AgentInfo = struct {
        name: []const u8,
        description: []const u8,
    };

    /// Parse a specific agent by name from the agents directory
    /// Returns allocated string with agent content, or null if not found
    /// Caller owns the returned memory and must free it with allocator.free()
    pub fn parseAgent(allocator: std.mem.Allocator, io: std.Io, _: ?*const std.process.Environ.Map, agent_name: []const u8) ?[]const u8 {
        // Placeholder implementation - will be replaced when agents.zig is available
        // Try to find agent in .nalar/agents/<agent_name>/NALAR.md
        const LOCAL_AGENTS_DIR = ".nalar/agents";
        const AGENT_FILE_NAME = "NALAR.md";

        // Get current working directory
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch return null;
        const cwd = cwd_buf[0..cwd_len];

        // Build path: cwd/.nalar/agents/<agent_name>/NALAR.md
        const agent_path = std.fs.path.join(allocator, &[_][]const u8{
            cwd,
            LOCAL_AGENTS_DIR,
            agent_name,
            AGENT_FILE_NAME,
        }) catch return null;
        defer allocator.free(agent_path);

        // Try to open and read the file
        const file = std.Io.Dir.cwd().openFile(io, agent_path, .{}) catch return null;
        defer std.Io.File.close(file, io);

        const content = std.Io.Dir.cwd().readFileAlloc(io, agent_path, allocator, std.Io.Limit.limited(100 * 1024)) catch return null;
        return content;
    }

    /// List all available agents from the agents directory
    /// Returns allocated array of AgentInfo structs
    /// Caller owns the returned memory and must free it with freeAgentsList()
    pub fn listAgents(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map) []AgentInfo {
        _ = environment;
        // Placeholder implementation - will be replaced when agents.zig is available
        const LOCAL_AGENTS_DIR = ".nalar/agents";

        // Get current working directory
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch return &[_]AgentInfo{};
        const cwd = cwd_buf[0..cwd_len];

        // Build path: cwd/.nalar/agents
        const agents_path = std.fs.path.join(allocator, &[_][]const u8{
            cwd,
            LOCAL_AGENTS_DIR,
        }) catch return &[_]AgentInfo{};
        defer allocator.free(agents_path);

        // Try to open the directory
        var dir = std.Io.Dir.cwd().openDir(io, agents_path, .{ .iterate = true }) catch return &[_]AgentInfo{};
        defer std.Io.Dir.close(dir, io);

        var agents_list: std.ArrayList(AgentInfo) = .empty;
        defer agents_list.deinit(allocator);

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            // Try to read NALAR.md to get name and description
            const agent_file_path = std.fs.path.join(allocator, &[_][]const u8{
                agents_path, entry.name, "NALAR.md",
            }) catch continue;
            defer allocator.free(agent_file_path);

            const file = std.Io.Dir.cwd().openFile(io, agent_file_path, .{}) catch continue;
            defer std.Io.File.close(file, io);

            const content = std.Io.Dir.cwd().readFileAlloc(io, agent_file_path, allocator, std.Io.Limit.limited(100 * 1024)) catch continue;
            defer allocator.free(content);

            // Parse frontmatter to get name and description
            if (parse_frontmatter(allocator, content)) |fm| {
                agents_list.append(allocator, .{
                    .name = fm.name,
                    .description = fm.description,
                }) catch {
                    allocator.free(fm.name);
                    allocator.free(fm.description);
                };
            }
        }

        return agents_list.toOwnedSlice(allocator) catch &[_]AgentInfo{};
    }

    /// Free a agents array allocated by listAgents
    pub fn freeAgentsList(allocator: std.mem.Allocator, agents_list: []AgentInfo) void {
        for (agents_list) |agent| {
            allocator.free(agent.name);
            allocator.free(agent.description);
        }
        allocator.free(agents_list);
    }

    const ParsedFrontmatter = struct {
        name: []const u8,
        description: []const u8,
    };

    fn parse_frontmatter(allocator: std.mem.Allocator, content: []const u8) ?ParsedFrontmatter {
        // Find opening ---
        const start_marker = "---\n";
        const start_idx = std.mem.indexOf(u8, content, start_marker) orelse return null;

        // Find closing ---
        const content_after_start = content[start_idx + start_marker.len ..];
        const end_idx = std.mem.indexOf(u8, content_after_start, "\n---") orelse return null;

        const frontmatter = content_after_start[0..end_idx];

        var name: ?[]const u8 = null;
        var description: ?[]const u8 = null;

        // Parse name field
        const name_prefix = "name:";
        if (std.mem.indexOf(u8, frontmatter, name_prefix)) |name_idx| {
            const after_name = frontmatter[name_idx + name_prefix.len ..];
            const name_start = std.mem.indexOfNone(u8, after_name, " \t") orelse 0;
            const name_end = std.mem.indexOf(u8, after_name[name_start..], "\n") orelse after_name.len;
            const name_value = std.mem.trim(u8, after_name[name_start .. name_start + name_end], " \"\t\r\n");
            name = allocator.dupe(u8, name_value) catch null;
        }

        // Parse description field
        const desc_prefix = "description:";
        if (std.mem.indexOf(u8, frontmatter, desc_prefix)) |desc_idx| {
            const after_desc = frontmatter[desc_idx + desc_prefix.len ..];
            const desc_start = std.mem.indexOfNone(u8, after_desc, " \t") orelse 0;
            const desc_in_slice = after_desc[desc_start..];
            const desc_end = std.mem.indexOf(u8, desc_in_slice, "\n") orelse desc_in_slice.len;
            const desc_value = std.mem.trim(u8, desc_in_slice[0..desc_end], " \"\t\r\n");
            description = allocator.dupe(u8, desc_value) catch null;
        }

        if (name) |n| {
            return .{
                .name = n,
                .description = description orelse allocator.dupe(u8, "") catch "",
            };
        }
        return null;
    }
};

/// Input structure for change_agent tool
pub const ChangeAgentInput = struct {
    agent_name: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

/// Result structure for change_agent tool
pub const ChangeAgentResult = struct {
    agent_name: []const u8,
    content: []const u8,
    loaded: bool,
    path: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
    available_agents: ?[]const []const u8 = null,
};

/// Tool definition for change_agent
pub const change_agent_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "change_agent",
        .description = "Switch to a different agent persona with specialized capabilities. Use when you need a different expertise, perspective, or approach. Examples: 'code-reviewer' for quality feedback, 'zig-expert' for Zig guidance, 'frontend-engineer' for UI work.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "agent_name",
                    .type = "string",
                    .description = "The exact name of the agent to load",
                },
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Load agent from absolute file path",
                },
            },
            .required = &.{},
        },
    },
};

/// Parse change_agent tool input from JSON
pub fn parse_change_agent_input(allocator: std.mem.Allocator, json_str: []const u8) !ChangeAgentInput {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return error.InvalidJson;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    var result = ChangeAgentInput{};

    if (root.object.get("agent_name")) |name_val| {
        if (name_val == .string) {
            result.agent_name = try allocator.dupe(u8, name_val.string);
        }
    }

    if (root.object.get("path")) |path_val| {
        if (path_val == .string) {
            result.path = try allocator.dupe(u8, path_val.string);
        }
    }

    return result;
}

/// Execute the change_agent tool
/// Returns an XML string with the agent content or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_change_agent_to_string(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map, input: ChangeAgentInput) ![]const u8 {
    // Check if path is provided - load from file
    if (input.path) |path| {
        return loadAgentFromPath(allocator, path);
    }

    // Otherwise try to parse by agent name
    if (input.agent_name) |agent_name| {
        return loadAgentByName(allocator, io, environment, agent_name);
    }

    // No agent_name or path provided
    return error.InvalidInput;
}

/// Generate error XML response
pub fn xmlError(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<agent>
        \\  <agent_name></agent_name>
        \\  <content></content>
        \\  <loaded>false</loaded>
        \\  <error>{s}</error>
        \\</agent>
    , .{error_msg}) catch "<agent><error>UnknownError</error></agent>";
}

/// Generate error XML response (comptime, no allocation)
pub fn xmlErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<agent>
        \\  <agent_name></agent_name>
        \\  <content></content>
        \\  <loaded>false</loaded>
        \\  <error>{s}</error>
        \\</agent>
    , .{error_msg}) catch "<agent><error>UnknownError</error></agent>";
}

/// Load agent from absolute file path
fn loadAgentFromPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // `std.fs.openFileAbsolute` was removed in Zig 0.16. Use the
    // cross-platform `helpers.readFile` (libc `fopen`/`fread`) which
    // works on Linux, macOS, and Windows via UCRT without an
    // `io: std.Io` runtime. The helper combines open + read so the
    // previous two-stage error reporting (open vs read) collapses to
    // a single "Failed to open file" message — acceptable since the
    // downstream consumer just checks `loaded=true`.
    const content = helpers.readFile(allocator, path) catch {
        const result = try std.fmt.allocPrint(allocator,
            \\<agent>
            \\  <agent_name></agent_name>
            \\  <content></content>
            \\  <loaded>false</loaded>
            \\  <error>Failed to open file</error>
            \\</agent>
        , .{});
        return result;
    };
    defer allocator.free(content);

    // Extract filename without extension for agent_name
    const filename = std.fs.path.basename(path);
    const ext = std.fs.path.extension(filename);
    const agent_name = if (ext.len > 0) filename[0 .. filename.len - ext.len] else filename;

    const result = try std.fmt.allocPrint(allocator,
        \\<agent>
        \\  <agent_name>{s}</agent_name>
        \\  <content>{s}</content>
        \\  <loaded>true</loaded>
        \\</agent>
    , .{ agent_name, content });
    return result;
}

/// Load agent by name from built-in agents
fn loadAgentByName(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map, agent_name: []const u8) ![]const u8 {
    // Try to parse the agent
    if (agents.parseAgent(allocator, io, environment, agent_name)) |content| {
        defer allocator.free(content);
        // Success - return the agent content
        const result = try std.fmt.allocPrint(allocator,
            \\<agent>
            \\  <agent_name>{s}</agent_name>
            \\  <content>{s}</content>
            \\  <loaded>true</loaded>
            \\</agent>
        , .{ agent_name, content });
        return result;
    } else {
        // Agent not found - list available agents
        const agents_list = agents.listAgents(allocator, io, environment);
        defer agents.freeAgentsList(allocator, agents_list);

        // Build XML string for available agents
        var available_str: std.ArrayList(u8) = .empty;
        defer available_str.deinit(allocator);

        for (agents_list) |agent| {
            try available_str.appendSlice(allocator, "<agent>");
            try available_str.appendSlice(allocator, agent.name);
            try available_str.appendSlice(allocator, "</agent>");
        }

        const result = try std.fmt.allocPrint(allocator,
            \\<agent>
            \\  <agent_name>{s}</agent_name>
            \\  <content></content>
            \\  <loaded>false</loaded>
            \\  <error>Agent not found</error>
            \\  <available_agents>{s}</available_agents>
            \\</agent>
        , .{ agent_name, available_str.items });

        return result;
    }
}

test {
    _ = @import("change_agent_test.zig");
}
