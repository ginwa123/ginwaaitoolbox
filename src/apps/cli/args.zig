const std = @import("std");

pub const CommandMode = enum {
    explain_project,
    session,
};

pub const Command = struct {
    mode: CommandMode,
    session_id: []const u8,
    message: []const u8,
};

pub const CliError = error{
    NoArguments,
    InvalidCommand,
    MissingSessionId,
    MissingMessage,
};

/// Parse command line arguments
/// 
/// Supported formats:
/// - `nalarcore-cli "explain-this-project"` - Run LLM to explain the project
/// - `nalarcore-cli "session_id" "message"` - Continue session with message
pub fn parseArgs(args: []const [:0]const u8) CliError!Command {
    if (args.len == 0) {
        return CliError.NoArguments;
    }
    
    const first_arg = args[0];
    
    // Check for explain-this-project mode
    if (std.mem.eql(u8, first_arg, "explain-this-project")) {
        return Command{
            .mode = .explain_project,
            .session_id = &.{},
            .message = &.{},
        };
    }
    
    // Check for session mode: needs at least 2 args
    if (args.len < 2) {
        // If only one arg and not explain-this-project, it's invalid
        return CliError.InvalidCommand;
    }
    
    const session_id = args[0];
    const message = args[1];
    
    // Validate session_id format (should start with SES-)
    if (!std.mem.startsWith(u8, session_id, "SES-")) {
        return CliError.InvalidCommand;
    }
    
    return Command{
        .mode = .session,
        .session_id = session_id,
        .message = message,
    };
}

// Tests
test "parse explain-this-project command" {
    const args = try parseArgs(&[_][:0]const u8{"explain-this-project"});
    try std.testing.expect(args.mode == .explain_project);
    try std.testing.expect(args.session_id.len == 0);
    try std.testing.expect(args.message.len == 0);
}

test "parse session command with id and message" {
    const args = try parseArgs(&[_][:0]const u8{ "SES-12345678", "Hello, how are you?" });
    try std.testing.expect(args.mode == .session);
    try std.testing.expectEqualStrings("SES-12345678", args.session_id);
    try std.testing.expectEqualStrings("Hello, how are you?", args.message);
}

test "parse session command with multi-word message" {
    const args = try parseArgs(&[_][:0]const u8{ "SES-abcdef12", "What is the meaning of life?" });
    try std.testing.expect(args.mode == .session);
    try std.testing.expectEqualStrings("SES-abcdef12", args.session_id);
    try std.testing.expectEqualStrings("What is the meaning of life?", args.message);
}

test "no arguments returns error" {
    const args = parseArgs(&[_][:0]const u8{});
    try std.testing.expectError(error.NoArguments, args);
}

test "single argument that's not explain-this-project" {
    const args = parseArgs(&[_][:0]const u8{"random"});
    try std.testing.expectError(error.InvalidCommand, args);
}
