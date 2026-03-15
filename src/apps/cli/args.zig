const std = @import("std");

pub const CommandMode = enum {
    explain_project,
    session,
};

pub const Command = struct {
    mode: CommandMode,
    session_id: []const u8,
    message: []const u8,
    port: u16 = 8080,
};
