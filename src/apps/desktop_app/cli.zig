// src/apps/desktop_app/cli.zig
//
// Command-line parser for nalar-desktop. Parses --port, --nalar-path,
// --nalar-url, --window-size, --title, --user-agent, --icon,
// --smoke-test, --help / -h.
// Returns a Config struct with all the parameters. The caller is responsible
// for calling `cfg.deinit(allocator)` to free heap-allocated strings.
//
// The parser writes usage to stderr when --help is requested or when an
// unknown argument is given, then returns an error from `CliError`. The caller
// typically treats `error.ShowHelp` as a clean exit (don't print the error to
// the user) and all other errors as "show the error to the user, then exit".

const std = @import("std");

pub const Config = struct {
    /// Port to bind nalar on. 0 = auto-pick a free port.
    /// Ignored when `nalar_url` is set (connect mode).
    port: u16 = 0,
    /// Optional explicit path to the nalar binary.
    /// Ignored when `nalar_url` is set (connect mode).
    nalar_path: ?[]const u8 = null,
    /// If set, skip the spawn/healthcheck/asset-extraction path entirely
    /// and just point the webview at this URL. Useful for dev workflows
    /// where you already have a nalar running and just want a window
    /// wrapper (e.g. `--nalar-url http://127.0.0.1:8081` to attach to a
    /// nalar you started by hand). `--port` and `--nalar-path` are ignored
    /// in this mode.
    nalar_url: ?[]const u8 = null,
    /// Window dimensions.
    window_width: u32 = 1280,
    window_height: u32 = 800,
    /// Window title. The default value is a string literal — do NOT free
    /// it. Heap-allocated titles (set via `--title`) MUST be freed by
    /// deinit(). See deinit() for the (slightly leaky) edge case when
    /// the user passes `--title "Nalar"` (same as default).
    title: []const u8 = "Nalar",
    /// Optional User-Agent override.
    user_agent: ?[]const u8 = null,
    /// Optional path to a window icon.
    icon_path: ?[]const u8 = null,
    /// If true, the app runs in CI-friendly mode: open, wait briefly, exit.
    smoke_test: bool = false,

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        if (self.nalar_path) |p| allocator.free(p);
        if (self.nalar_url) |u| allocator.free(u);
        // title: free only if heap-allocated (i.e. user set --title with
        // a value different from the default literal). If the user passed
        // `--title "Nalar"`, we treat the title as still the literal and
        // skip the free — this is a small memory leak for that edge case
        // (the user is unlikely to type the default). For v1 this is fine.
        if (!std.mem.eql(u8, self.title, "Nalar")) allocator.free(self.title);
        if (self.user_agent) |ua| allocator.free(ua);
        if (self.icon_path) |ip| allocator.free(ip);
    }
};

pub const CliError = error{
    ShowHelp,
    InvalidPort,
    InvalidSize,
    MissingValue,
    UnknownArg,
    /// allocator.dupe() failure — Zig 0.16 requires this in the error set
    /// since `try` propagates OutOfMemory as a distinct error.
    OutOfMemory,
};

const usage =
    \\Usage: nalar-desktop [options]
    \\
    \\Two modes:
    \\  Spawn mode (default): spawn nalar as a child process, wait for it
    \\    to be healthy, then open the webview. Closing the window kills
    \\    the spawned nalar. Uses --port and --nalar-path.
    \\  Connect mode (--nalar-url): skip spawning; just open the webview at
    \\    the given URL. Useful for attaching to a nalar you already have
    \\    running. --port and --nalar-path are ignored in this mode.
    \\
    \\Options:
    \\  --port PORT              Port for nalar to bind on (default: 0 = auto-pick)
    \\  --nalar-path PATH        Explicit path to nalar binary
    \\  --nalar-url URL          Connect mode: point webview at this URL
    \\                            (e.g. http://127.0.0.1:8081) instead of
    \\                            spawning a new nalar
    \\  --window-size WxH        Window size in pixels (default: 1280x800)
    \\  --title TITLE            Window title (default: "Nalar")
    \\  --user-agent UA          User-Agent string for the webview
    \\  --icon PATH              Path to window icon
    \\  --smoke-test             Open, wait 2s, exit (for CI)
    \\  --help, -h               Show this help
    \\
;

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) CliError!Config {
    var cfg: Config = .{};
    errdefer cfg.deinit(allocator);

    var i: usize = 1; // skip argv[0]
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--nalar-path")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.nalar_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--nalar-url")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.nalar_url = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--window-size")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const x_idx = std.mem.indexOfScalar(u8, args[i], 'x') orelse return error.InvalidSize;
            const w = std.fmt.parseInt(u32, args[i][0..x_idx], 10) catch return error.InvalidSize;
            const h = std.fmt.parseInt(u32, args[i][x_idx + 1..], 10) catch return error.InvalidSize;
            cfg.window_width = w;
            cfg.window_height = h;
        } else if (std.mem.eql(u8, arg, "--title")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            // Free the previous title if it was heap-allocated (i.e. user
            // passed --title twice with a non-default value). If the previous
            // value was the literal "Nalar", skip the free.
            if (!std.mem.eql(u8, cfg.title, "Nalar")) allocator.free(cfg.title);
            cfg.title = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--user-agent")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (cfg.user_agent) |ua| allocator.free(ua);
            cfg.user_agent = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--icon")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (cfg.icon_path) |ip| allocator.free(ip);
            cfg.icon_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--smoke-test")) {
            cfg.smoke_test = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            // std.debug.print writes to stderr by default. Zig 0.16 removed
            // std.fs.File.stderr() in favor of std.Io.File.stderr() which
            // requires an Io handle; using std.debug.print avoids threading
            // io through the parser for what is a startup-only path.
            std.debug.print("{s}", .{usage});
            return error.ShowHelp;
        } else {
            std.debug.print("Unknown argument: {s}\n\n{s}", .{ arg, usage });
            return error.UnknownArg;
        }
    }
    return cfg;
}
