const std = @import("std");

pub const CliOptions = struct {
    query: ?[]const u8 = null,
    continue_session: bool = false,
    continue_session_id: ?[]const u8 = null,
    show_help: bool = false,
    show_version: bool = false,
    verbose: bool = false,
    port: u16 = 8080,
    process: []const u8 = "nalar",
    json: bool = false,
};

pub fn parseCliArgs(allocator: std.mem.Allocator, io: std.Io, environment: *std.process.Environ.Map, args: std.process.Args) !CliOptions {
    _ = io;
    _ = environment;
    var opts = CliOptions{};

    var args_iter = std.process.Args.iterate(args);
    var i: usize = 0;
    while (args_iter.next()) |arg| {
        i += 1;
        if (i == 1) continue;
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--query")) {
            if (args_iter.next()) |next_arg| {
                opts.query = try allocator.dupe(u8, next_arg);
            } else {
                return error.MissingQueryArgument;
            }
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "--session")) {
            opts.continue_session = true;
            if (args_iter.next()) |next_arg| {
                if (!std.mem.startsWith(u8, next_arg, "-")) {
                    opts.continue_session_id = try allocator.dupe(u8, next_arg);
                }
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.show_help = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            opts.show_version = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-V")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            if (args_iter.next()) |port_arg| {
                opts.port = std.fmt.parseInt(u16, port_arg, 10) catch {
                    return error.InvalidPortArgument;
                };
            } else {
                return error.MissingPortArgument;
            }
        } else if (std.mem.eql(u8, arg, "--process")) {
            if (args_iter.next()) |process_name| {
                opts.process = try allocator.dupe(u8, process_name);
            } else {
                return error.MissingProcessArgument;
            }
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else {
        }
    }
    return opts;
}

pub fn printHelp() void {
    std.debug.print("nalar-tui - AI Agent Terminal UI\n\n", .{});
    std.debug.print("Usage: nalar-tui [options]\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -q, --query <prompt>    Send a query prompt (one-shot mode)\n", .{});
    std.debug.print("  -c, --continue          Resume latest session (auto-detect)\n", .{});
    std.debug.print("  -c <session_id>         Resume specific session\n", .{});
    std.debug.print("  -p, --port <port>       HTTP server port (default: 8080)\n", .{});
    std.debug.print("  --process <name>        Backend binary to spawn (default: nalar)\n", .{});
    std.debug.print("  --json                  Output response as clean JSON (use with -q)\n", .{});
    std.debug.print("  -v, --version           Print version\n", .{});
    std.debug.print("  -h, --help              Show help\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  nalar-tui               Start new session\n", .{});
    std.debug.print("  nalar-tui -c            Resume latest session\n", .{});
    std.debug.print("  nalar-tui -c abc123     Resume specific session\n", .{});
    std.debug.print("  nalar-tui -q \"What is the capital of France?\"\n", .{});
    std.debug.print("  nalar-tui -c -p 8081    Resume latest session on port 8081\n", .{});
    std.debug.print("  nalar-tui --process nalar-dev\n", .{});
}