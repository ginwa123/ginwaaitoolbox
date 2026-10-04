//! `GET /health` — connection-health probe.
//!
//! Returns the server's current wall-clock timestamp so the caller can
//! detect clock drift between client and server, plus a constant
//! `"status": "ok"` so the response is forward-compatible with future
//! fields (the frontend only checks `status` for the liveness ping).
//!
//! Layered as:
//!   - `useCase` — reads the clock and returns the data struct.
//!   - `healthHandler` — thin orchestrator: delegates to `useCase`,
//!     builds the JSON response, returns 200.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

/// Domain-level error set for `useCase`. Currently empty — the
/// health probe has no failure modes the caller needs to
/// distinguish (an io-clock read failure would be a system-level
/// bug, surfaced as a different status code).
pub const HealthError = error{};

/// Health-probe data returned by the use-case. We use
/// `http_response.HealthResponse` directly so the handler can hand
/// the value to `makeHealthResponse` without an extra struct
/// translation step.
pub const HealthData = http_response.HealthResponse;

// =====================================================================
// Use case
// =====================================================================

/// Read the current real-clock timestamp and produce the health
/// payload. The clock read can in principle fail (Io runtime
/// cancellation), but on the per-request Io it's effectively
/// infallible — kept as an error union for forward compatibility.
fn useCase(io: std.Io) HealthError!HealthData {
    const ts = std.Io.Clock.now(.real, io);
    return .{
        .status = "ok",
        .timestamp = ts.toSeconds(),
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn healthHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;

    const data = useCase(ctx.io) catch |err| {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = @errorName(err),
            }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeHealthResponse(allocator, data),
    });
}