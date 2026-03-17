const std = @import("std");

/// CLI options structure
pub const CliOptions = struct {
    query: ?[]const u8 = null,
    continue_session: ?[]const u8 = null,
    show_help: bool = false,
    show_version: bool = false,
    verbose: bool = false,
    port: u16 = 8080,
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
            opts.query = args[i];
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "--session")) {
            if (i + 1 >= args.len) {
                return error.MissingSessionArgument;
            }
            i += 1;
            opts.continue_session = args[i];
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
    std.debug.print("  -c, --continue, --session <session_id> Resume an existing session\n", .{});
    std.debug.print("  -p, --port <port>       HTTP server port (default: 8080)\n", .{});
    std.debug.print("  -v, --version           Print version\n", .{});
    std.debug.print("  -h, --help              Show help\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  nalar-tui -q \"What is the capital of France?\"\n", .{});
    std.debug.print("  nalar-tui -c abc123 -q \"Summarize that in one sentence.\"\n", .{});
    std.debug.print("  nalar-tui --session sessionContinue -q \"Continue the conversation\"\n", .{});
    std.debug.print("  nalar-tui -p 8081       Connect to HTTP server on port 8081\n", .{});
    std.debug.print("  nalar-tui               Start interactive session\n", .{});
}
