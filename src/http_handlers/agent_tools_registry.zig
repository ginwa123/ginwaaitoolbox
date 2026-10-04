//! `GET /api/agent-tools/registry`.
//!
//! Returns the canonical tool registry as `{tools: [{name, description}]}`.
//! Sourced from `tools_equipped.UNIFIED_TOOL_REGISTRY()` — the same
//! source of truth the runtime tool filter reads. When a tool is added
//! or removed in that function, the registry endpoint automatically
//! reflects it (no drift, no second list to maintain).
//!
//! Layered as:
//!   - `useCase` — transforms the runtime registry into a
//!     [{name, description}] list.
//!   - `agentToolsRegistryHandler` — thin orchestrator over
//!     `useCase`: delegates to `useCase`, marshals the result to
//!     JSON.
//!
//! Memory: the per-request arena reaps all allocations at request
//! end, so neither layer needs explicit `free`s.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");

/// One entry in the registry response.
pub const RegistryEntry = struct {
    name: []const u8,
    /// Owned by the use-case (lifetime = request arena).
    description: []const u8,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (intentional — adding a new variant fails to compile in
/// the handler until both switches are updated, keeping status
/// codes in lockstep with the error set).
pub const RegistryError = error{
    /// `allocator.dupe` failed while copying descriptions. In
    /// production this is effectively unreachable (the per-request
    /// arena reaps everything at request end) but the type system
    /// requires the variant so the `try` propagates a typed error.
    OutOfMemory,
};

/// Output of the registry use-case.
pub const RegistryOutput = struct {
    entries: []const RegistryEntry,
};

// =====================================================================
// Use case
// =====================================================================

/// Transform the runtime registry into a slice of `{name,description}`
/// entries. The use-case is transport-agnostic: it works for both
/// the per-request arena (production HTTP handler) and
/// `testing.allocator` (unit tests below) — all allocations go
/// through the passed-in allocator.
fn useCase(allocator: std.mem.Allocator) RegistryError!RegistryOutput {
    const registry = tools_equipped.UNIFIED_TOOL_REGISTRY();

    var list: std.ArrayList(RegistryEntry) = .empty;
    for (registry) |entry| {
        try list.append(allocator, .{
            .name = entry.name,
            .description = try allocator.dupe(u8, entry.tool_def.function.description),
        });
    }
    return .{ .entries = try list.toOwnedSlice(allocator) };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentToolsRegistryHandler(
    ctx: gserverz.HttpContext,
    _: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const output = useCase(allocator) catch |err| {
        const status: u16 = switch (err) {
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Pass the entries directly — std.json.Stringify flattens the
    // struct fields into a `{name, description}` JSON object.
    const data = try std.json.Stringify.valueAlloc(allocator, .{ .tools = output.entries }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention for Agent Mode).
// 2 behavioural tests cover the use-case:
//
//   1. Registry is non-empty (sanity — if UNIFIED_TOOL_REGISTRY is
//      accidentally emptied, the frontend's Tools panel dies)
//   2. Every entry has a non-empty `name` and `description`

const testing = std.testing;

test "useCase: returns a non-empty registry" {
    const alloc = testing.allocator;
    const output = try useCase(alloc);
    defer {
        for (output.entries) |e| alloc.free(e.description);
        alloc.free(output.entries);
    }
    try testing.expect(output.entries.len > 0);
}

test "useCase: every entry has non-empty name and description" {
    const alloc = testing.allocator;
    const output = try useCase(alloc);
    defer {
        for (output.entries) |e| alloc.free(e.description);
        alloc.free(output.entries);
    }
    for (output.entries) |e| {
        try testing.expect(e.name.len > 0);
        try testing.expect(e.description.len > 0);
    }
}