const std = @import("std");
const command_defs = @import("command_defs.zig");
const globals = @import("../globals.zig");
const App = @import("../main.zig").App;

/// Execute a command by name
/// Returns true if the app should exit, false otherwise
pub fn executeCommand(app: *App, command: []const u8) !bool {
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
    if (std.mem.eql(u8, command, "/model")) {
        return commandModel(app);
    }
    if (std.mem.eql(u8, command, "/config")) {
        return commandConfig(app);
    }
    if (std.mem.eql(u8, command, "/session")) {
        return commandSession(app);
    }
    if (std.mem.eql(u8, command, "/enabledebug")) {
        return commandEnableDebug(app);
    }
    if (std.mem.eql(u8, command, "/disabledebug")) {
        return commandDisableDebug(app);
    }
    if (std.mem.eql(u8, command, "/compact")) {
        return commandCompact(app);
    }
    return false;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Get the default config path (same logic as config module)
/// Caller owns returned memory
fn getConfigPath(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) ![]u8 {
    const env = environment orelse return error.HomeNotFound;
    const home = env.get("HOME") orelse return error.HomeNotFound;
    const config_home = env.get("XDG_CONFIG_HOME");

    const base: []const u8 = if (config_home) |xch| xch else try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    defer if (config_home == null) allocator.free(base);

    return try std.fmt.allocPrint(allocator, "{s}/nalar/config.json", .{base});
}

// ─── Command Handlers ────────────────────────────────────────────────────────

fn commandExit(_: *App) !bool {
    return true;
}

fn commandHelp(_: *App) !bool {
    std.debug.print("\r\n{s}Available commands:{s}\r\n", .{ globals.bold, globals.reset });
    const commands = command_defs.getCommands();
    for (commands) |cmd| {
        std.debug.print("  {s}{s:<12}{s}{s} - {s}\r\n", .{ globals.bold, cmd.name, globals.reset, globals.dim, cmd.description });
    }
    std.debug.print("{s}Type / followed by a command name to execute{s}\r\n", .{ globals.dim, globals.reset });
    return false;
}

fn commandClear(app: *App) !bool {
    // Clear screen and globals.reset cursor
    std.debug.print("\x1b[2J\x1b[H", .{});
    std.debug.print("{s}>{s} ", .{ globals.bold, globals.reset });
    _ = app;
    return false;
}

fn commandPing(app: *App) !bool {
    std.debug.print("\r\n", .{});
    const messaging = @import("../network/messaging.zig");
    const should_reconnect = messaging.send_ping_command(app) catch false;
    if (should_reconnect) {
        std.debug.print("{s}Server session stale, will reconnect on next request{s}\r\n", .{ globals.dim, globals.reset });
    } else {
        std.debug.print("{s}Server is responsive{s}\r\n", .{ globals.dim, globals.reset });
    }
    return false;
}

/// Show the current AI model being used
fn commandModel(app: *App) !bool {
    std.debug.print("\r\n{s}Current AI Model:{s}\r\n", .{ globals.bold, globals.reset });

    // Read config file directly
    const config_path = try getConfigPath(app.allocator, app.environment);
    defer app.allocator.free(config_path);

    const file = std.Io.Dir.openFileAbsolute(app.io, config_path, .{}) catch |err| {
        std.debug.print("{s}Error opening config: {s}{s}\r\n", .{ globals.yellow, @errorName(err), globals.reset });
        return false;
    };
    defer file.close(app.io);

    var content_buf = try std.ArrayList(u8).initCapacity(app.allocator, 4096);
    defer content_buf.deinit(app.allocator);
    var file_reader_buf: [4096]u8 = undefined;
    var reader = std.Io.File.reader(file, app.io, &file_reader_buf);
    while (true) {
        const n = reader.interface.readSliceShort(&file_reader_buf) catch |err| {
            std.debug.print("{s}Error reading config: {s}{s}\r\n", .{ globals.yellow, @errorName(err), globals.reset });
            return false;
        };
        if (n == 0) break;
        content_buf.appendSlice(app.allocator, file_reader_buf[0..n]) catch break;
    }
    const json_str = try content_buf.toOwnedSlice(app.allocator);

    // Parse JSON to find model
    const parsed = std.json.parseFromSlice(std.json.Value, app.allocator, json_str, .{}) catch |err| {
        std.debug.print("{s}Error parsing config JSON: {s}{s}\r\n", .{ globals.yellow, @errorName(err), globals.reset });
        return false;
    };
    defer parsed.deinit();

    const model = parsed.value.object.get("model") orelse {
        std.debug.print("{s}No model found in config{s}\r\n", .{ globals.yellow, globals.reset });
        return false;
    };

    const model_str = model.string;
    std.debug.print("  {s}Model:{s} {s}{s}{s}\r\n", .{ globals.dim, globals.reset, globals.green, model_str, globals.reset });
    return false;
}

/// Show configuration settings (with sensitive data masked)
fn commandConfig(app: *App) !bool {
    std.debug.print("\r\n{s}Configuration:{s}\r\n", .{ globals.bold, globals.reset });

    // Read config file directly
    const config_path = try getConfigPath(app.allocator, app.environment);
    defer app.allocator.free(config_path);

    const file = std.Io.Dir.openFileAbsolute(app.io, config_path, .{}) catch |err| {
        std.debug.print("{s}Error opening config: {s}{s}\r\n", .{ globals.yellow, @errorName(err), globals.reset });
        return false;
    };
    defer file.close(app.io);

    var content_buf = try std.ArrayList(u8).initCapacity(app.allocator, 4096);
    defer content_buf.deinit(app.allocator);
    var file_reader_buf: [4096]u8 = undefined;
    var reader = std.Io.File.reader(file, app.io, &file_reader_buf);
    while (true) {
        const n = reader.interface.readSliceShort(&file_reader_buf) catch |err| {
            std.debug.print("{s}Error reading config: {s}{s}\r\n", .{ globals.yellow, @errorName(err), globals.reset });
            return false;
        };
        if (n == 0) break;
        content_buf.appendSlice(app.allocator, file_reader_buf[0..n]) catch break;
    }
    const json_str = try content_buf.toOwnedSlice(app.allocator);

    // Parse JSON to extract config values
    const parsed = std.json.parseFromSlice(std.json.Value, app.allocator, json_str, .{}) catch |err| {
        std.debug.print("{s}Error parsing config JSON: {s}{s}\r\n", .{ globals.yellow, @errorName(err), globals.reset });
        return false;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Extract and display values
    const api_key = obj.get("api_key") orelse std.json.Value{ .string = "" };
    const model = obj.get("model") orelse std.json.Value{ .string = "not set" };
    const base_url = obj.get("base_url") orelse std.json.Value{ .string = "not set" };
    const compaction = obj.get("model_compaction_size_kb") orelse std.json.Value{ .integer = 100 };
    const mcp = obj.get("mcpServers");

    // Mask API key (show last 4 chars)
    var masked_key: []u8 = undefined;
    if (api_key.string.len > 4) {
        masked_key = try app.allocator.alloc(u8, api_key.string.len);
        const prefix_len = api_key.string.len - 4;
        for (0..prefix_len) |i| masked_key[i] = '*';
        @memcpy(masked_key[prefix_len..], api_key.string[prefix_len..]);
    } else {
        masked_key = try app.allocator.alloc(u8, api_key.string.len);
        @memcpy(masked_key, api_key.string);
    }
    defer app.allocator.free(masked_key);

    std.debug.print("  {s}API Key:{s}     {s}{s}{s}\r\n", .{ globals.dim, globals.reset, globals.green, masked_key, globals.reset });
    std.debug.print("  {s}Model:{s}       {s}{s}{s}\r\n", .{ globals.dim, globals.reset, globals.green, model.string, globals.reset });
    std.debug.print("  {s}Base URL:{s}    {s}{s}{s}\r\n", .{ globals.dim, globals.reset, globals.green, base_url.string, globals.reset });
    std.debug.print("  {s}Compaction:{s}  {s}{d} KB{s}\r\n", .{ globals.dim, globals.reset, globals.green, compaction.integer, globals.reset });

    if (mcp != null) {
        std.debug.print("  {s}MCP Servers:{s} {s}enabled{s}\r\n", .{ globals.dim, globals.reset, globals.green, globals.reset });
    } else {
        std.debug.print("  {s}MCP Servers:{s} {s}disabled{s}\r\n", .{ globals.dim, globals.reset, globals.yellow, globals.reset });
    }

    return false;
}

/// Show current session information
fn commandSession(app: *App) !bool {
    std.debug.print("\r\n{s}Session Info:{s}\r\n", .{ globals.bold, globals.reset });
    std.debug.print("  {s}Session ID:{s} {s}{s}{s}\r\n", .{ globals.dim, globals.reset, globals.green, app.session_id, globals.reset });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len);
    const cwd: []const u8 = if (cwd_ptr) |p| std.mem.sliceTo(p, 0) else "unknown";
    std.debug.print("  {s}Working Dir:{s} {s}{s}{s}\r\n", .{ globals.dim, globals.reset, globals.green, cwd, globals.reset });

    return false;
}

/// Enable debug mode for AI agent debugging
fn commandEnableDebug(app: *App) !bool {
    app.verbose = true;
    std.debug.print("\r\n{s}╔════════════════════════════════════════╗{s}\r\n", .{ globals.bold, globals.reset });
    std.debug.print("{s}║       {s}✓ DEBUG MODE ENABLED{s}             {s}║{s}\r\n", .{ globals.bold, globals.green, globals.reset, globals.bold, globals.reset });
    std.debug.print("{s}╚════════════════════════════════════════╝{s}\r\n", .{ globals.bold, globals.reset });
    std.debug.print("\r\n{s}Debug logging is now active. The following will be displayed:{s}\r\n", .{ globals.dim, globals.reset });
    std.debug.print("  {s}• Network requests and responses{s}\r\n", .{ globals.dim, globals.reset });
    std.debug.print("  {s}• SSE message parsing details{s}\r\n", .{ globals.dim, globals.reset });
    std.debug.print("  {s}• Tool calls and results{s}\r\n", .{ globals.dim, globals.reset });
    std.debug.print("  {s}• HTTP headers and chunked transfer details{s}\r\n", .{ globals.dim, globals.reset });
    std.debug.print("\r\n{s}Use {s}/disabledebug{s} to turn off debug mode.{s}\r\n", .{ globals.dim, globals.bold, globals.reset, globals.dim });
    return false;
}

/// Disable debug mode
fn commandDisableDebug(app: *App) !bool {
    app.verbose = false;
    std.debug.print("\r\n{s}╔════════════════════════════════════════╗{s}\r\n", .{ globals.bold, globals.reset });
    std.debug.print("{s}║       {s}✗ DEBUG MODE DISABLED{s}           {s}║{s}\r\n", .{ globals.bold, globals.yellow, globals.reset, globals.bold, globals.reset });
    std.debug.print("{s}╚════════════════════════════════════════╝{s}\r\n", .{ globals.bold, globals.reset });
    std.debug.print("\r\n{s}Debug logging is now off.{s}\r\n", .{ globals.dim, globals.reset });
    std.debug.print("\r\n{s}Use {s}/enabledebug{s} to turn on debug mode.{s}\r\n", .{ globals.dim, globals.bold, globals.reset, globals.dim });
    return false;
}

/// Trigger manual conversation history compaction
fn commandCompact(app: *App) !bool {
    std.debug.print("\r\n{s}Compacting conversation history...{s}\r\n", .{ globals.dim, globals.reset });
    const messaging = @import("../network/messaging.zig");
    messaging.sendCompactCommand(app) catch |err| {
        std.debug.print("{s}Error sending compact command: {s}{s}\r\n", .{ globals.yellow, @errorName(err), globals.reset });
        return false;
    };
    std.debug.print("{s}Compaction request sent. The server will process it.{s}\r\n", .{ globals.green, globals.reset });
    return false;
}
