const std = @import("std");

// =============================================================================
// Bash Tool Types
// =============================================================================

pub const BashInput = struct {
    command: []const u8,
    timeout: ?u32 = 30,
    cwd: ?[]const u8 = null,
    max_output: ?usize = 1024 * 1024, // default 1MB
    stdin_data: ?[]const u8 = null, // optional stdin input, null = close stdin
    background: bool = false, // run in background using nohup
    max_lines: ?usize = 1000, // default 1000 lines per output stream
};

pub const BashResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u32,
};

pub const BashOutput = struct {
    command: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    truncated: bool,
    timeout: bool,
    stdout_lines: usize = 0, // total lines produced (before truncation)
    stderr_lines: usize = 0, // total lines produced (before truncation)
    is_self: bool = false, // command targeted the current process
};

// =============================================================================
// Read File Tool Types
// =============================================================================

pub const ReadFileInput = struct {
    path: []const u8,
    offset: ?usize = null,
    limit: ?usize = null,
    show_line_numbers: ?bool = null,
};

// =============================================================================
// Agent Tool Schema Types
// =============================================================================

pub const ToolProperty = struct {
    name: []const u8,
    type: []const u8,
    description: []const u8,
};

pub const ToolParameters = struct {
    type: []const u8,
    properties: []const ToolProperty,
    required: []const []const u8,
};

pub const AgentToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: ToolParameters,
};

pub const AgentTool = struct {
    type: []const u8,
    function: AgentToolFunction,
};

// =============================================================================
// List struct for batch building tool properties
// =============================================================================

pub const List = struct {
    items: std.ArrayList(ToolProperty),

    pub fn init() List {
        return .{ .items = std.ArrayList(ToolProperty).empty };
    }

    pub fn deinit(self: *List) void {
        self.items.deinit();
    }

    pub fn append(self: *List, allocator: std.mem.Allocator, name: []const u8, type_: []const u8, description: []const u8) !void {
        try self.items.append(allocator, .{
            .name = name,
            .type = type_,
            .description = description,
        });
    }

    pub fn to_owned_slice(self: *List, allocator: std.mem.Allocator) ![]ToolProperty {
        return try self.items.toOwnedSlice(allocator);
    }
};

// =============================================================================
// Web Search Tool Types
// =============================================================================

pub const WebSearchInput = struct {
    /// URL to browse
    url: []const u8 = "",
    /// Working directory (defaults to /tmp)
    cwd: ?[]const u8 = "/tmp",
};

pub const WebSearchResult = struct {
    success: bool,
    content: []const u8,
    exit_code: i32,
    error_msg: ?[]const u8 = null,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.error_msg) |msg| allocator.free(msg);
    }
};
