//! `POST /test/shutdown` — gracefully shut the server down.
//!
//! Triggers `di.server.shutdown()` and returns 200 with a status
//! message. After the response is flushed, a detached thread calls
//! `std.process.exit(0)` so the process actually terminates for the
//! functional-test harness.
//!
//! Without the explicit exit, the listener loop alone does not cause
//! the process to die — the cronjob manager thread started in
//! `listen()` outlives main's defers and segfaults ~10s later
//! (rc=-11). The harness would then wait full SIGTERM + SIGKILL
//! deadlines (10s per test × 64 tests ≈ 10 min of CI waste). The
//! `/test/shutdown` endpoint is a test-only convenience; production
//! uses SIGINT (Ctrl+C) / SIGTERM via `signal_handlers`
//! (`installShutdownHandlers` in main), which calls the same
//! `GinwaServer.shutdown()` and lets `listen()` return into the
//! `cronjob_manager.stop() / sse_manager.stop() / defer` unwind.
//!
//! Layered as `useCase` (call shutdown + schedule exit) and a thin
//! handler that maps the outcome to the JSON response.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = nalarcore.http_response;

pub const ShutdownError = error{
    GlobalContextNotInitialized,
};

pub const ShutdownResponse = struct {
    message: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase() ShutdownError!ShutdownResponse {
    _ = nalarcore.getSingleton() catch return error.GlobalContextNotInitialized;
    // Deferred shutdown: do NOT call di.server.shutdown() synchronously.
    // Closing the listener before the 200 body flushes races the
    // worker_pool dispatcher (main.zig listenEventLoop) and surfaces
    // as curl (52) Empty reply from server in the CI smoke test.
    // Spawn a detached thread that exits the process after a brief
    // delay (so the HTTP response has time to flush over the wire).
    // If the thread can't be spawned (resource exhaustion), fall back
    // to a synchronous exit — the handler's contract is "shut the
    // server down", and the client doesn't need a 200 response if
    // we're going to immediately terminate anyway.
    //
    // Zig 0.16 cross-platform sleep: `helpers.sleepMillis` uses
    // libc nanosleep on Linux/macOS and Win32 Sleep on Windows. We
    // previously inlined `std.c.timespec{...}` + `std.c.nanosleep(&ts,
    // null)` here but `std.c.timespec` is exposed as `void` on
    // Windows in 0.16 — see helpers/mod.zig:220 for the full
    // rationale. `sleepMillis(50)` is the documented equivalent
    // for our ~50 ms "let the response flush" delay.
    const helpers = @import("helpers");
    const spawn_fn = struct {
        fn run() void {
            helpers.sleepMillis(250);
            if (nalarcore.getSingleton()) |di| {
                di.server.shutdown();
            } else |_| {}
            helpers.sleepMillis(50);
            std.process.exit(0);
        }
    }.run;
    if (std.Thread.spawn(.{}, spawn_fn, .{})) |t| {
        t.detach();
    } else |_| {
        const di = nalarcore.getSingleton() catch return error.GlobalContextNotInitialized;
        di.server.shutdown();
        std.process.exit(0);
    }
    return .{ .message = "Server shutdown initiated" };
}

// =====================================================================
// Handler
// =====================================================================

pub fn shutdownHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;

    const response = useCase() catch |err| {
        const status: u16 = switch (err) {
            error.GlobalContextNotInitialized => 500,
        };
        const message: []const u8 = switch (err) {
            error.GlobalContextNotInitialized => "Global context not initialized",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const json_str = try std.json.Stringify.valueAlloc(allocator, response, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}