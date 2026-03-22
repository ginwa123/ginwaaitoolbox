const std = @import("std");
const globals = @import("../globals.zig");
const tui_text = @import("tui-text");
const command_defs = @import("../commands/command_defs.zig");
const command_handlers = @import("../commands/handlers.zig");
const escape = @import("escape.zig");
const raw_mode = @import("../terminal/raw_mode.zig");
const App = @import("../main.zig").App;

const KEYBINDING = enum(u8) {
    CTRL_C = 3,
    ENTER = 13,
};

/// Clear completion display
pub fn clearCompletions(app: *App) void {
    if (app.state.last_match_count == 0) return;
    var i: usize = 0;
    while (i < app.state.last_match_count) : (i += 1) {
        tui_text.print("\x1b[1B", .{});
        tui_text.print("\x1b[2K", .{});
    }
    tui_text.print("\x1b[{}A", .{app.state.last_match_count});
    app.state.visible = false;
    app.state.last_match_count = 0;
}

/// Render completion suggestions
pub fn renderCompletions(app: *App) void {
    if (app.state.last_match_count > 0) {
        var i: usize = 0;
        while (i < app.state.last_match_count) : (i += 1) {
            tui_text.print("\x1b[1B", .{});
            tui_text.print("\x1b[2K", .{});
        }
        tui_text.print("\x1b[{}A", .{app.state.last_match_count});
    }

    // Show command bar at bottom with descriptions
    tui_text.print("\x1b[s", .{});

    // Move to bottom of screen
    tui_text.print("\x1b[999;1H", .{});
    tui_text.print("\x1b[2K", .{}); // Clear the line

    // Draw command bar border
    tui_text.print("\x1b[7m", .{}); // Inverse colors
    tui_text.print(" Commands: ", .{});

    // Print each matching command with its description
    const commands = command_defs.getCommands();
    for (app.state.matches.items, 0..) |cmd_name, i| {
        // Find the command description
        var desc: []const u8 = "";
        for (commands) |cmd| {
            if (std.mem.eql(u8, cmd.name, cmd_name)) {
                desc = cmd.description;
                break;
            }
        }

        if (i == app.state.selected) {
            tui_text.print("\x1b[0m\x1b[42m {s} ", .{cmd_name}); // Green highlight
            tui_text.print("\x1b[90m{s}\x1b[0m ", .{desc});
            tui_text.print("\x1b[7m", .{});
        } else {
            tui_text.print("\x1b[0m {s} ", .{cmd_name});
            tui_text.print("\x1b[90m{s}\x1b[0m ", .{desc});
        }
    }

    // Restore cursor position
    tui_text.print("\x1b[u", .{});

    app.state.last_match_count = app.state.matches.items.len;
    std.debug.print("\x1b[u", .{});
}

/// Handle keyboard input
pub fn handle_input(app: *App) !bool {
    var buf: [1]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;
    if (n == 0) {
        // EOF detected - exit if in non-interactive mode
        if (app.is_noninteractive) {
            return true;
        }
        std.Thread.sleep(10000000);
        return false;
    }
    const keystroke = buf[0];
    if (keystroke == @intFromEnum(KEYBINDING.CTRL_C)) return true;

    if (keystroke == 0x1b) {
        var esc: [16]u8 = undefined;
        const len = try escape.readEscapeSequence(&esc);
        const seq = esc[0..len];

        if (std.mem.eql(u8, seq, "\x1b[200~")) {
            app.pasting = true;
            app.last_esc_time = null;
            // Wrap pasted content with data boundary markers for security
            try app.input.appendSlice(app.allocator, "[START DATA]\n");
            std.debug.print("{s}[START DATA]{s}", .{ globals.dim, globals.reset });
        } else if (std.mem.eql(u8, seq, "\x1b[201~")) {
            app.pasting = false;
            app.last_esc_time = null;
            // Wrap pasted content with data boundary markers for security
            try app.input.appendSlice(app.allocator, "\n[END DATA]");
            std.debug.print("{s}[END DATA]{s}", .{ globals.dim, globals.reset });
        } else {
            // Check for double escape (quick consecutive escape presses)
            const now = std.time.milliTimestamp();
            var is_double_escape = false;
            if (app.last_esc_time) |last| {
                if (now - last < globals.DOUBLE_ESC_WINDOW_MS) {
                    is_double_escape = true;
                }
            }
            app.last_esc_time = now;

            if (is_double_escape) {
                // Double escape detected - send double_escape command to unregister session
                const messaging = @import("../network/messaging.zig");
                messaging.sendDoubleEscapeCommand(app) catch {
                    std.debug.print("\r\n{s}Failed to send double escape command{s}\r\n", .{ globals.dim, globals.reset });
                };
                // Also clear completions
                clearCompletions(app);
                return false;
            }
            // Only clear completions for non-paste escape sequences
            clearCompletions(app);
        }
        return false;
    }

    if (keystroke == 127 or keystroke == 8) {
        if (!app.pasting and app.input.items.len > 0) {
            _ = app.input.pop();
            std.debug.print("\x08 \x08", .{});
        }
    } else if (keystroke == '\t') {
        if (!app.pasting) {
            // _ = try handleCompletion(app);
        } else {
            // Treat tab as spaces during paste
            try app.input.append(app.allocator, ' ');
            std.debug.print(" ", .{});
        }
    } else if (keystroke == @intFromEnum(KEYBINDING.ENTER) or keystroke == 10) {
        if (app.pasting) {
            // During paste, newlines become spaces instead of submitting
            try app.input.append(app.allocator, ' ');
            std.debug.print(" ", .{});
            return false;
        }
        if (app.input.items.len > 0) {
            // Check if it's a command (starts with /)
            if (app.input.items[0] == '/') {
                const input_str = app.input.items;
                const should_exit = try command_handlers.executeCommand(app, input_str);

                if (!should_exit) {
                    // Command executed successfully or wasn't found
                    // Check if the command was actually found by looking at input
                    const commands = command_defs.getCommands();
                    var cmd_found = false;
                    for (commands) |cmd| {
                        if (std.mem.eql(u8, input_str, cmd.name)) {
                            cmd_found = true;
                            break;
                        }
                    }

                    if (!cmd_found) {
                        // Command not found - show error
                        std.debug.print("\r\n{s}Unknown command: {s}{s}\r\n", .{ globals.dim, input_str, globals.reset });
                        std.debug.print("{s}Type /help for available commands{s}\r\n", .{ globals.dim, globals.reset });
                    }
                    // Clear any leftover completion display and reset cursor state
                    clearCompletions(app);
                    app.input.clearRetainingCapacity();
                    // Print prompt fresh on a new line
                    std.debug.print("{s}>{s} ", .{ globals.bold, globals.reset });
                    return false;
                }
                // else: exit was returned, so we return true to exit
                return should_exit;
            }

            // Regular input - send to LLM
            std.debug.print("\r\n\r\n", .{});
            const streaming = @import("../network/streaming.zig");
            const response = streaming.readResponseAndStreamRunLLM(app, app.input.items) catch "";
            defer app.allocator.free(response);
            if (response.len == 0) std.debug.print("{s}No response{s}\r\n", .{ globals.dim, globals.reset });
            app.input.clearRetainingCapacity();
        }
        std.debug.print("\r\n{s}>{s} ", .{ globals.bold, globals.reset });
    } else if (keystroke >= 32) {
        if (!app.pasting) clearCompletions(app);
        try app.input.append(app.allocator, keystroke);
        std.debug.print("{c}", .{keystroke});
    }
    return false;
}
