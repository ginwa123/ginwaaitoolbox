const std = @import("std");

/// Command names only (for completion)
pub fn getCommandNames() []const []const u8 {
    return &.{
        "/sessions",
        "/exit",
        "/help",
        "/clear",
        "/ping",
        "/model",
        "/config",
        "/session",
        "/enabledebug",
        "/disabledebug",
    };
}

/// Command info with descriptions (for help display and completions)
pub const CommandInfo = struct {
    name: []const u8,
    description: []const u8,
};

/// Get all commands with descriptions
pub fn getCommands() []const CommandInfo {
    return &.{
        .{ .name = "/sessions", .description = "List all active sessions" },
        .{ .name = "/exit", .description = "Exit the application" },
        .{ .name = "/help", .description = "Show available commands" },
        .{ .name = "/clear", .description = "Clear the screen" },
        .{ .name = "/ping", .description = "Ping the server" },
        .{ .name = "/model", .description = "Show current AI model" },
        .{ .name = "/config", .description = "Show configuration settings" },
        .{ .name = "/session", .description = "Show current session info" },
        .{ .name = "/enabledebug", .description = "Enable debug mode for AI agent debugging" },
        .{ .name = "/disabledebug", .description = "Disable debug mode" },
    };
}
