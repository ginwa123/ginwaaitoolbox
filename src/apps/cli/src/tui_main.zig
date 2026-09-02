//! `nalar-tui` — interactive streaming chat TUI for the nalar backend.
//!
//! Usage:
//!   nalar-tui [--server <url>] [--session <id>] [--profile <name>]
//!
//! Flags mirror `nalarcli`; env vars NALARCLI_SERVER / NALARCLI_SESSION_ID /
//! NALARCLI_PROFILE are honored as fallbacks.

const std = @import("std");
const tui = @import("tui");
const app_mod = tui.app;
const transport = tui.transport;

fn usage() []const u8 {
    return
    \\nalar-tui — interactive chat TUI for the nalar backend.
    \\
    \\Usage:
    \\  nalar-tui [flags]
    \\
    \\Flags:
    \\  --server <url>     Backend URL (default http://localhost:8081)
    \\  --session <id>     Resume an existing session (default: new)
    \\  --profile <name>   LLM profile name
    \\  --cwd <path>       Working directory for the agent (default: shell cwd)
    \\  --help             Show this help
    \\
    \\Keys:
    \\  Enter              Send the message
    \\  Ctrl-C / Ctrl-D    Quit
    \\  Up/Down            Input history
    \\  PgUp / PgDn        Scroll chat history
    \\  Mouse wheel        Scroll chat history
    \\
    ;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    const argv_full = try init.minimal.args.toSlice(allocator);
    const argv = if (argv_full.len > 0) argv_full[1..] else &[_][]const u8{};

    var cfg = app_mod.Config{};
    var profile: ?[]const u8 = null;
    var flag_cwd: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printOut(io, usage());
            return;
        } else if (std.mem.eql(u8, a, "--server")) {
            i += 1;
            if (i >= argv.len) return fail("--server requires a value");
            cfg.server = argv[i];
        } else if (std.mem.eql(u8, a, "--session")) {
            i += 1;
            if (i >= argv.len) return fail("--session requires a value");
            cfg.session_id = argv[i];
        } else if (std.mem.eql(u8, a, "--profile")) {
            i += 1;
            if (i >= argv.len) return fail("--profile requires a value");
            profile = argv[i]; // accepted for parity with nalarcli; sent as "" in v1
        } else if (std.mem.eql(u8, a, "--cwd")) {
            i += 1;
            if (i >= argv.len) return fail("--cwd requires a value");
            flag_cwd = argv[i];
        } else {
            return fail("unknown flag; try --help");
        }
    }

    // Env fallbacks (same names as nalarcli).
    if (cfg.session_id == null) {
        if (env.get("NALARCLI_SESSION_ID")) |v| {
            if (v.len > 0) cfg.session_id = v;
        }
    }

    // Resolve cwd: --cwd flag > NALARCLI_CWD env > OS cwd > "" (sandbox fallback).
    // Priority mirrors nalarcli's --cwd handling but auto-detects OS cwd when
    // no explicit value is given — the TUI's project is the shell's cwd.
    if (flag_cwd) |v| {
        cfg.cwd = v;
    } else if (env.get("NALARCLI_CWD")) |v| {
        if (v.len > 0) cfg.cwd = v;
    } else {
        // Capture OS cwd via realPathFile with ".". On failure (e.g., cwd deleted),
        // fall back to "" so the backend uses its sandbox fallback.
        // NOTE: Dir.realPath (no sub_path) fails with FileNotFound on Linux
        // (see /tmp/test_cwd.zig) — must use realPathFile with ".".
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buf)) |cwd_len| {
            const cwd_slice = cwd_buf[0..cwd_len];
            // Only use if absolute — defensive, realPathFile should always be absolute.
            if (cwd_slice.len > 0 and std.fs.path.isAbsolute(cwd_slice)) {
                // Dupe into arena so it lives for the process lifetime.
                cfg.cwd = allocator.dupe(u8, cwd_slice) catch "";
            }
        } else |_| {
            // Keep cfg.cwd = "" (sandbox fallback)
        }
    }
    // Validate: non-empty cwd must be absolute; otherwise fall back to sandbox.
    if (cfg.cwd.len > 0 and !std.fs.path.isAbsolute(cfg.cwd)) {
        cfg.cwd = "";
    }

    var app = try app_mod.App.init(allocator, io, cfg);
    defer app.deinit();

    var program = tui.Program(app_mod.App).init(&app, allocator, io);
    program.exec_cmd = &execCmd;
    program.run() catch |e| {
        if (e == error.NotATerminal) return;
        return e;
    };

    // On exit, tell the user which session to resume.
    var buf: [256]u8 = undefined;
    const msg_text = if (app.session_id) |sid|
        std.fmt.bufPrint(&buf, "\nnalar-tui: session saved as {s} (resume with --session {s})\n", .{ sid, sid }) catch ""
    else
        "\nnalar-tui: bye\n";
    printOut(io, msg_text);
}

/// Execute the Cmd returned by App.update. Runs on the main thread,
/// between update and the next draw.
fn execCmd(model: *app_mod.App, cmd: tui.Cmd) void {
    switch (cmd) {
        .send_msg => |msg_text| {
            defer model.freeCmd(cmd);
            sendAndTrack(model, msg_text);
        },
        .poll_messages => pollMessages(model),
        .none, .tick_after => {},
    }
}

fn sendAndTrack(model: *app_mod.App, msg_text: []const u8) void {
    // Session id: existing or fresh `session-<unix-ms>`.
    var sid_buf: [64]u8 = undefined;
    const session_id: []const u8 = model.session_id orelse blk: {
        const ts = std.Io.Clock.now(.real, model.io).toMilliseconds();
        const s = std.fmt.bufPrint(&sid_buf, "session-{d}", .{ts}) catch "session-0";
        break :blk s;
    };

    const resp = transport.postSend(
        model.allocator,
        &model.http_client,
        model.cfg.server,
        session_id,
        msg_text,
        model.cfg.cwd,
    ) catch {
        model.viewport.appendLine("! failed to reach server", .{ .fg = .red }) catch {};
        model.is_streaming = false;
        return;
    };
    model.allocator.free(resp);

    model.onSendOk(session_id) catch {};
}

fn pollMessages(model: *app_mod.App) void {
    const sid = model.session_id orelse return;
    const body = transport.getMessages(
        model.allocator,
        &model.http_client,
        model.cfg.server,
        sid,
        100,
    ) catch return; // transient failure — retry on next tick
    defer model.allocator.free(body);
    model.onMessages(body) catch {};
}

fn printOut(io: std.Io, text: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(text) catch {};
    w.interface.flush() catch {};
}

fn fail(msg_text: []const u8) anyerror {
    std.log.err("{s}", .{msg_text});
    return error.InvalidArgs;
}

test "usage mentions flags" {
    try testing.expect(std.mem.indexOf(u8, usage(), "--server") != null);
    try testing.expect(std.mem.indexOf(u8, usage(), "--session") != null);
}

const testing = std.testing;
