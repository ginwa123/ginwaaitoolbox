const std = @import("std");
const bashMod = @import("bash.zig");
const schemas = @import("schemas.zig");
const BashInput = schemas.BashInput;
const AgentTool = schemas.AgentTool;

pub const WebSearchHelpResult = struct {
    content: []const u8,
    exit_code: i32,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub fn executeWebSearchHelp(allocator: std.mem.Allocator) !WebSearchHelpResult {
    const input = BashInput{
        .command = "agent-browser --help",
        .cwd = "/tmp",
        .max_output = 1024 * 1024, // 1MB for full help
    };

    const result = try bashMod.executeBash(allocator, input);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        allocator.free(result.command);
    }

    return WebSearchHelpResult{
        .content = try allocator.dupe(u8, result.stdout),
        .exit_code = result.exit_code,
    };
}

pub const web_search_help_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "web_search_help",
        .description = "Get help information for the agent-browser CLI tool. Use this to see all available commands, options, and usage examples.",
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
    },
};
