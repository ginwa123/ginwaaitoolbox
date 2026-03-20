const std = @import("std");
const builtin = @import("builtin");
const keybindings = @import("keybindings.zig");
const tui_text = @import("tui-text");

// Enable TLS support for HTTP client
pub const std_options: std.Options = .{
    .http_disable_tls = false,
};

// Import all modules
const globals = @import("globals.zig");
const commands = @import("commands/command_defs.zig");
const command_handlers = @import("commands/handlers.zig");
const raw_mode = @import("terminal/raw_mode.zig");
const backend = @import("terminal/backend.zig");
const network = @import("network/streaming.zig");
const messaging = @import("network/messaging.zig");
const tool_display = @import("display/tool_results.zig");
const input = @import("input/handle_input.zig");
const cli = @import("cli/opts.zig");

pub const CompletionState = struct {
    last_match_count: usize = 0,
    visible: bool = false,
    selected: usize = 0,
    matches: std.ArrayList([]const u8),
};

const App = struct {
    http_client: std.http.Client,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    original_termios: ?std.posix.termios,
    session_id: []u8,
    input: std.ArrayList(u8),
    pasting: bool,
    last_esc_time: ?i64 = null,
    agent_name_buf: [64]u8 = [_]u8{0} ** 64,
    keybindings: keybindings.Keybindings,
    verbose: bool = false,
    state: CompletionState = CompletionState{ .matches = .empty },
    is_noninteractive: bool = false,
    http_port: u16 = 8080,

    pub fn init(allocator: std.mem.Allocator, verbose: bool, is_noninteractive: bool, http_port: u16) !App {
        // Spawn the backend if it's not already running
        backend.spawnBackend(verbose, http_port) catch |err| {
            std.debug.print("{s}Error: Failed to spawn nalar backend: {s}{s}\n", .{ globals.red, @errorName(err), globals.reset });
            std.debug.print("{s}Make sure /usr/local/bin/nalar exists (run: zig build install){s}\n", .{ globals.yellow, globals.reset });
            return err;
        };
        std.log.info("Spawned backend", .{});
        try backend.waitForHttpServer(10000, http_port);
        std.log.info("HTTP server ready", .{});

        // Only enable raw mode when running interactively (has a real TTY)
        // In non-interactive mode (e.g., -q flag), there's no terminal
        var original_termios: ?std.posix.termios = null;
        const stdin_is_tty = std.posix.isatty(std.posix.STDIN_FILENO);
        if (!is_noninteractive) {
            if (stdin_is_tty) {
                original_termios = try raw_mode.enableRawMode();
                std.log.info("Raw mode enabled", .{});
            } else {
                std.log.info("Running in non-interactive mode (stdin is not a TTY)", .{});
            }
        }

        const kb = try keybindings.loadKeybindings(allocator);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const http_client = std.http.Client{ .allocator = arena.allocator() };
        return App{
            .http_client = http_client,
            .arena = arena,
            .allocator = allocator,
            .original_termios = original_termios,
            .session_id = "",
            .input = std.ArrayList(u8).empty,
            .pasting = false,
            .last_esc_time = null,
            .keybindings = kb,
            .verbose = verbose,
            .state = CompletionState{
                .matches = std.ArrayList([]const u8).empty,
            },
            .is_noninteractive = is_noninteractive,
            .http_port = http_port,
        };
    }

    pub fn deinit(app: *App) void {
        app.keybindings.deinit();
        if (app.original_termios) |orig| {
            raw_mode.disableRawMode(orig);
        }
        app.allocator.free(app.session_id);
        app.input.deinit(app.allocator);
        app.state.matches.deinit(app.allocator);
        app.http_client.deinit();
        app.arena.deinit();
    }
};

/// Run query mode - send single query and exit
fn runQueryMode(app: *App, query: []const u8) !void {
    const response = network.readResponseAndStreamRunLLM(app, query) catch |err| {
        tui_text.print("Error: {s}\n", .{@errorName(err)});
        return;
    };
    defer app.allocator.free(response);
    // Response is already printed by readResponseAndStreamRunLLM
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena_allocator = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();

    // Initialize the text module's global allocator
    tui_text.setGlobalAllocator(allocator);

    // Parse CLI arguments
    const opts = cli.parseCliArgs(allocator) catch |err| {
        if (err == error.MissingQueryArgument) {
            tui_text.print("Error: -q/--query requires an argument\n", .{});
            return error.MissingQueryArgument;
        }
        if (err == error.MissingSessionArgument) {
            tui_text.print("Error: -c/--continue requires an argument\n", .{});
            return error.MissingSessionArgument;
        }
        if (err == error.MissingPortArgument) {
            tui_text.print("Error: -p/--port requires an argument\n", .{});
            return error.MissingPortArgument;
        }
        if (err == error.InvalidPortArgument) {
            tui_text.print("Error: -p/--port must be a valid u16 number\n", .{});
            return error.InvalidPortArgument;
        }
        return err;
    };

    // Handle help and version flags
    if (opts.show_help) {
        cli.printHelp();
        return;
    }

    if (opts.show_version) {
        tui_text.print("nalar-tui version {s}\n", .{globals.VERSION});
        return;
    }

    // Determine if we're in non-interactive mode (CLI query mode vs interactive TUI)
    // Also consider non-interactive if stdin is not a TTY
    const stdin_is_tty = std.posix.isatty(std.posix.STDIN_FILENO);
    const is_noninteractive = opts.query != null or !stdin_is_tty;

    // Initialize app (always needed, even for query mode)
    var app = try App.init(
        allocator,
        opts.verbose,
        is_noninteractive,
        opts.port,
    );
    if (opts.continue_session) |session_id| {
        app.session_id = try app.allocator.dupe(u8, session_id);

        // Check if session exists in database before continuing
        const session_found = messaging.check_session_exists(&app) catch |err| {
            tui_text.print("{s}Error: Failed to check session: {s}{s}\n", .{ globals.red, @errorName(err), globals.reset });
            return err;
        };
        if (!session_found) {
            tui_text.print("{s}Error: Session '{s}' not found.{s}\n", .{ globals.red, session_id, globals.reset });
            tui_text.print("{s}Use /sessions to see available sessions or start a new session.{s}\n", .{ globals.yellow, globals.reset });
            return error.SessionNotFound;
        }
        // TODO: Fetch history when backend supports get_history command
    }

    if (std.mem.eql(u8, app.session_id, "")) {
        app.session_id = try std.fmt.allocPrint(app.allocator, "session_{}", .{std.time.timestamp()});
    }

    // Query mode: send single query and exit
    if (opts.query) |query| {
        try runQueryMode(&app, query);
        std.debug.print("\r\n{s}Bye!{s} session_id: {s}\r\n", .{ globals.dim, globals.reset, app.session_id });
        return;
    }

    // Interactive mode (default)
    std.debug.print("Type message and press Enter. Ctrl+C to exit.\r\n\r\n", .{});
    std.debug.print("\x1b[?2004h", .{});
    defer std.debug.print("\x1b[?2004l", .{});
    std.debug.print("{s}>{s} ", .{ globals.bold, globals.reset });

    while (true) {
        const should_exit = try input.handleInput(&app);
        if (should_exit) {
            std.debug.print("\r\n{s}Bye!{s} session_id: {s}\r\n", .{ globals.dim, globals.reset, app.session_id });
            break;
        }
    }

    // tui_text.print("\r\n{s}Bye!{s}\r\n", .{ globals.dim, globals.reset });
}

test {
    _ = @import("main_test.zig");
}
