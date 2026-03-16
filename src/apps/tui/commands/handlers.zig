const std = @import("std");
const command_defs = @import("command_defs.zig");
const tui_text = @import("tui-text");

const reset = tui_text.ansi.reset;
const bold = tui_text.ansi.bold;
const dim = tui_text.ansi.dim;
const green = tui_text.ansi.green;
const yellow = tui_text.ansi.yellow;

/// App type - forward declared, will be passed as anytype or we use a generic approach
/// Since we're splitting files, we'll use anytype for the app parameter to avoid circular imports

/// Execute a command by name
/// Returns true if the app should exit, false otherwise
pub fn executeCommand(app: anytype, command: []const u8) !bool {
    if (std.mem.eql(u8, command, "/sessions")) {
        return commandSessions(app);
    }
    if (std.mem.eql(u8, command, "/exit")) {
        return commandExit(app);
    }
    if (std.mem.eql(u8, command, "/help")) {
        return commandHelp(app);
    }
    if (std.mem.eql(u8, command, "/clear")) {
        return commandClear(app);
    }
    if (std.mem.eql(u8, command, "/ping")) {
        return commandPing(app);
    }
    return false;
}

// ─── Command Handlers ────────────────────────────────────────────────────────

fn commandSessions(app: anytype) !bool {
    std.debug.print("\r\n", .{});
    // Import the streaming function from network module
    const streaming = @import("../network/streaming.zig");
    const response = streaming.readResponseAndStreamGetSessions(app) catch "";
    defer app.allocator.free(response);
    if (response.len == 0) std.debug.print("{s}No response{s}\r\n", .{ dim, reset });
    return false;
}

fn commandExit(_: anytype) !bool {
    return true;
}

fn commandHelp(_: anytype) !bool {
    std.debug.print("\r\n{s}Available commands:{s}\r\n", .{ bold, reset });
    const commands = command_defs.getCommands();
    for (commands) |cmd| {
        std.debug.print("  {s}{s:<12}{s}{s} - {s}\r\n", .{ bold, cmd.name, reset, dim, cmd.description });
    }
    std.debug.print("{s}Type / followed by a command name to execute{s}\r\n", .{ dim, reset });
    return false;
}

fn commandClear(app: anytype) !bool {
    // Clear screen and reset cursor
    tui_text.print("\x1b[2J\x1b[H", .{});
    std.debug.print("{s}>{s} ", .{ bold, reset });
    _ = app;
    return false;
}

fn commandPing(app: anytype) !bool {
    std.debug.print("\r\n", .{});
    const messaging = @import("../network/messaging.zig");
    const should_reconnect = messaging.sendPingCommand(app) catch false;
    if (should_reconnect) {
        std.debug.print("{s}Server session stale, will reconnect on next request{s}\r\n", .{ dim, reset });
    } else {
        std.debug.print("{s}Server is responsive{s}\r\n", .{ dim, reset });
    }
    return false;
}
