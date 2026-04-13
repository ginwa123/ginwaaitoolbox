const std = @import("std");

/// CLI options structure
pub const CliOptions = struct {
    query: ?[]const u8 = null,
    continue_session: bool = false,  // true = auto-detect latest session
    continue_session_id: ?[]const u8 = null,  // specific session ID if provided
    show_help: bool = false,
    show_version: bool = false,
    verbose: bool = false,
    port: u16 = 8080,
    process: []const u8 = "nalar",  // backend binary name to spawn
    json: bool = false,              // output response as clean JSON
};

/// Parse command line arguments
pub fn parseCliArgs(allocator: std.mem.Allocator) !CliOptions {
    var opts = CliOptions{};
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--query")) {
            if (i + 1 >= args.len) {
                return error.MissingQueryArgument;
            }
            i += 1;
            // CRITICAL: Allocate query BEFORE args is freed
            opts.query = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "--session")) {
            // -c alone = auto-detect latest session
            // -c <session_id> = continue specific session
            opts.continue_session = true;
            if (i + 1 < args.len) {
                // Check if next arg is a flag or a session ID
                const next_arg = args[i + 1];
                if (std.mem.startsWith(u8, next_arg, "-")) {
                    // Next arg is a flag, not a session ID - auto-detect only
                } else {
                    // Next arg is a session ID
                    i += 1;
                    opts.continue_session_id = try allocator.dupe(u8, args[i]);
                }
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.show_help = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            opts.show_version = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-V")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            if (i + 1 >= args.len) {
                return error.MissingPortArgument;
            }
            i += 1;
            opts.port = std.fmt.parseInt(u16, args[i], 10) catch {
                return error.InvalidPortArgument;
            };
        } else if (std.mem.eql(u8, arg, "--process")) {
            if (i + 1 >= args.len) {
                return error.MissingProcessArgument;
            }
            i += 1;
            opts.process = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else {
            // Unknown argument, ignore for compatibility
        }
    }
    return opts;
}

/// Print help text
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
