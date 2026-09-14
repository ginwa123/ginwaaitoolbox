// src/apps/desktop_app/cli.zig
//
// Command-line parser for nalar-desktop. Parses --port, --nalar-path,
// --nalar-url, --browser, --window-size, --title, --user-agent, --icon,
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
    /// If set, run as a standalone BROWSER window: open this http(s) URL in a
    /// top-level webview of our own (with the injected chrome bar) and skip
    /// attach / auto-spawn / asset extraction entirely. This is what the
    /// in-app browser tab spawns (`nalar-desktop --browser <url>`); the flag is
    /// also useful on its own as a minimal browser window.
    ///
    /// Only `http://` / `https://` are accepted (validated at parse time) — a
    /// `javascript:` / `data:` / `file:` URL must never reach a window.
    browser_url: ?[]const u8 = null,
    /// Decoupled-service mode (added in 2026-07): when no `nalar` daemon
    /// is running, refuse to auto-spawn one and surface an actionable
    /// error instead. Default: false (auto-spawn is the default).
    no_auto_start: bool = false,
    /// Override the port used by the probe / auto-spawn fallback.
    /// 0 = use the state file's port, or 8081 if no state file.
    attach_port: u16 = 0,
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
    /// If true, enable the webview's DevTools (right-click → Inspect
    /// Element → DevTools panel). Off by default; enable for dev
    /// workflow.
    enable_devtools: bool = false,
    /// Linux-only today (no-op on macOS/Windows): when true, force
    /// `GDK_BACKEND=x11` before gtk_init. The default Wayland backend
    /// silently falls back to software rendering on NVIDIA+Wayland
    /// setups (the wl_drm / linux-dmabuf-feedback path is broken on
    /// Hyprland + GeForce, so WebKitGTK never spawns its GPU process
    /// and rasterizes every frame in the web-process JS thread → 99% CPU
    /// core). XWayland is the workaround: NVIDIA's GL path under X11
    /// is mature and lets WebKitGTK bring up its GPU process normally.
    ///
    /// Off by default so first-time users on the working path (AMD/
    /// Intel + Wayland) are not affected. The user opts in with
    /// `--x11` when they hit the symptom and are happy to pay the
    /// XWayland translation cost.
    force_x11: bool = false,

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        if (self.nalar_path) |p| allocator.free(p);
        if (self.nalar_url) |u| allocator.free(u);
        if (self.browser_url) |u| allocator.free(u);
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
    /// `--browser` got something that is not an absolute http(s) URL.
    InvalidBrowserUrl,
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
    \\  --browser URL            Browser-window mode: open this http(s) URL in
    \\                            a real Nalar-owned webview window (with an
    \\                            injected address/reload bar). Skips the nalar
    \\                            attach/spawn path entirely. http(s) only.
    \\                            This is what the in-app browser tab spawns.
    \\  --window-size WxH        Window size in pixels (default: 1280x800)
    \\  --title TITLE            Window title (default: "Nalar")
    \\  --user-agent UA          User-Agent string for the webview
    \\  --icon PATH              Path to window icon
    \\  --smoke-test             Open, wait 2s, exit (for CI)
    \\  --devtools               Enable webview DevTools (right-click → Inspect
    \\                            Element → DevTools panel). Off by default.
    \\  --x11                    Linux only: force GDK_BACKEND=x11 so WebKitGTK
    \\                            uses XWayland instead of Wayland. Workaround
    \\                            for the NVIDIA + Wayland stack where
    \\                            WebKitGPUProcess silently fails to start and
    \\                            the web-process eats 1 CPU core doing software
    \\                            rasterization. No-op on macOS/Windows.
    \\  --help, -h               Show this help
    \\
;

/// True when `raw` is an absolute `http://` / `https://` URL.
///
/// A prefix check rather than a URL parse, on purpose: the invariant the shell
/// must hold is narrower than "a valid URL" — a `javascript:` / `data:` /
/// `file:` string must never reach a window or a spawn. The frontend does the
/// real address normalization (`helpers/browserUrl.ts`); this is the second,
/// independent check (the bridge re-validates before spawning — see
/// `browser_bridge.zig`).
pub fn isHttpUrl(raw: []const u8) bool {
    const http = "http://";
    const https = "https://";
    if (raw.len > http.len and std.ascii.startsWithIgnoreCase(raw, http)) return true;
    if (raw.len > https.len and std.ascii.startsWithIgnoreCase(raw, https)) return true;
    return false;
}

/// The host (with port, when present) of an absolute http(s) URL — used as the
/// OS window title so a window list reads "github.com", not "Nalar". Returns an
/// owned slice; never fails on a URL `isHttpUrl` already accepted.
pub fn hostOf(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const scheme_len: usize = if (std.ascii.startsWithIgnoreCase(url, "https://")) 8 else 7;
    const rest = if (url.len > scheme_len) url[scheme_len..] else "";
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return allocator.dupe(u8, rest[0..end]);
}

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
        } else if (std.mem.eql(u8, arg, "--browser")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            // Validate at parse time: this URL will be handed to a webview
            // *and* re-used as the spawn argument by the app window's bridge,
            // so it must be http(s) before it goes anywhere.
            if (!isHttpUrl(args[i])) return error.InvalidBrowserUrl;
            cfg.browser_url = try allocator.dupe(u8, args[i]);
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
        } else if (std.mem.eql(u8, arg, "--no-auto-start")) {
            cfg.no_auto_start = true;
        } else if (std.mem.eql(u8, arg, "--attach-port")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.attach_port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--devtools")) {
            cfg.enable_devtools = true;
        } else if (std.mem.eql(u8, arg, "--x11")) {
            // Linux-only flag (no-op on macOS/Windows). Forces the GDK
            // windowing backend to X11 so GDK/XWayland backs the WebKit
            // web view instead of GDK/Wayland. The Wayland+NVIDIA path
            // doesn't bring up WebKitGPUProcess today, which leaves the
            // web-process main thread doing all rasterization in
            // software (≈1 core pinned at 99%). XWayland's NVIDIA GL
            // stack is mature and lets WebKitGPUProcess spawn
            // normally. The opt-in keeps the AMD/Intel+Wayland happy
            // path unchanged for users who don't need the workaround.
            cfg.force_x11 = true;
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
