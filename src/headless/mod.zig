//! `pabrik headless` — run the real backend with NO HTTP server and NO port.
//!
//! ## Why this exists
//!
//! Every other way to drive pabrik goes through the HTTP server: the Vue
//! webapp, `pabrikcli`, `pabrik-tui`, and the functional-test harness all
//! speak to a bound listener. That is fine for a human at a browser, and
//! wrong for an AI agent that wants to run one turn and read the result:
//! it has to boot a server, pick a port, poll for readiness, and tear the
//! whole thing down again — and the port it picks can collide with the
//! dev server already running on 8081.
//!
//! Headless mode boots the SAME backend the server boots — the same
//! `LlmConfig`, the same SQLite database with the same migration chain,
//! the same `App` singleton, the same event bus, the same routine
//! scheduler, and the same `runAgenticMultiStepnew` agentic loop with the
//! same tools — and then runs one turn and exits. Nothing binds a socket.
//! There is no port to collide with, no readiness poll, and no teardown
//! race.
//!
//! ## What it deliberately does NOT do
//!
//! It does not re-implement the agent loop. `run` calls
//! `pabrikcore.agentic_loop_mod.runAgenticMultiStepnew` — the exact
//! function the HTTP path reaches through `App.emit_run_agent` — so a
//! headless turn and a browser turn execute the same code. A headless
//! run that passes is evidence about the real backend, not about a
//! parallel implementation of it.
//!
//! ## Output
//!
//! Every subcommand writes one JSON object to stdout and nothing else, so
//! an agent can parse it without scraping a log. Diagnostics go to the
//! log file (`$TMPDIR/agentic_coding.log` by default, `--log-file` to
//! override) exactly as the server does, which keeps stdout clean.
//!
//! ## Layout
//!
//!     headless/
//!     ├── mod.zig        this file — the module surface + shared types
//!     ├── args.zig       argv parsing (pure, unit-tested without booting)
//!     ├── boot.zig       the backend boot sequence (no server, no port)
//!     ├── run.zig        `headless run` — one agentic turn
//!     ├── sessions.zig   `headless sessions` / `headless messages`
//!     └── README.md      the user-facing contract

const std = @import("std");

pub const args = @import("args.zig");
pub const boot = @import("boot.zig");
pub const run = @import("run.zig");
pub const sessions = @import("sessions.zig");

/// The subcommand to run, with its arguments already parsed.
///
/// `help` is a first-class variant rather than an error so
/// `pabrik headless --help` exits 0.
pub const Command = union(enum) {
    /// One agentic turn: send a message, wait for the assistant reply.
    run: args.RunArgs,
    /// List recent sessions.
    sessions: args.SessionsArgs,
    /// Print one session's messages.
    messages: args.MessagesArgs,
    /// Print the usage text.
    help,
    /// The argv was rejected; `failure` says why.
    invalid: args.Failure,
};

/// Parse `argv` (WITHOUT argv[0] and WITHOUT the leading `headless` word)
/// into a `Command`.
pub fn parseCommand(argv: []const []const u8) args.ParseError!Command {
    return switch (try args.parse(argv)) {
        .run => |a| .{ .run = a },
        .sessions => |a| .{ .sessions = a },
        .messages => |a| .{ .messages = a },
        .help => .help,
        .invalid => |f| .{ .invalid = f },
    };
}

test {
    _ = args;
    _ = boot;
    _ = run;
    _ = sessions;
}

test "parseCommand: maps every Outcome variant onto a Command" {
    try std.testing.expect((try parseCommand(&.{"help"})) == .help);
    try std.testing.expect((try parseCommand(&.{})).? == .help);
    const r = try parseCommand(&.{ "run", "hi" });
    try std.testing.expectEqualStrings("hi", r.run.message);
    const bad = try parseCommand(&.{"nope"});
    try std.testing.expect(bad == .invalid);
}
