//! Static contract tests for the default-project route.
//!
//! ## Why a test that reads source
//!
//! `matchRoute` walks routes in **registration order** and the first match
//! wins. A literal route registered *after* a param route is unreachable —
//! the param swallows it. That class of bug is invisible to unit tests,
//! because a unit test of the handler never goes through routing at all, and
//! it is invisible to a layout test, because nothing is rendered. The only
//! way to catch it is to assert on the registration list itself.
//!
//! The precedent this follows is `run_all_agents.zig:641-673`, which
//! carries the same kind of static route assertions for
//! `.../kanban/run_all_agents`.
//!
//! Plan: docs/plans/2026-09-27-sidebar-new-chat-default-project.md (Step 3)

const std = @import("std");
const testing = std.testing;

const default_project_route = ".post(\"/api/workspaces/:workspace_id/default-project\"";
const route_marker = "authed.post(\"/api/workspaces/:workspace_id/";

/// Read `src/main.zig` so the test does not depend on the process working
/// directory. `@embedFile` rather than a runtime open: the assertions must
/// see the route list as COMPILED, otherwise a test run from a different
/// cwd would silently pass by reading nothing.
fn readMainSource(allocator: std.mem.Allocator) ![]u8 {
    const src = @embedFile("../main.zig");
    return allocator.dupe(u8, src);
}

test "the default-project route is registered" {
    const alloc = testing.allocator;
    const src = try readMainSource(alloc);
    defer alloc.free(src);

    if (std.mem.indexOf(u8, src, default_project_route) == null) {
        std.debug.print(
            "main.zig does not register {s}\n",
            .{default_project_route},
        );
        return error.DefaultProjectRouteNotRegistered;
    }
}

test "the default-project route is registered before any /api/workspaces POST param sibling" {
    const alloc = testing.allocator;
    const src = try readMainSource(alloc);
    defer alloc.free(src);

    const ours = std.mem.indexOf(u8, src, default_project_route) orelse
        return error.DefaultProjectRouteNotRegistered;

    // Walk every later `authed.post("/api/workspaces/...` registration and
    // fail if one is a bare `:param` in the segment right after
    // `:workspace_id` — that is exactly the shape that would capture
    // `default-project` as a parameter value and shadow us.
    var i = ours + default_project_route.len;
    while (std.mem.indexOfPos(u8, src, i, route_marker)) |pos| {
        const after = pos + route_marker.len;
        // The segment after `/api/workspaces/:workspace_id/`.
        if (src[after] == ':') {
            const tail_end = std.mem.indexOfScalarPos(u8, src, after, '"') orelse src.len;
            std.debug.print(
                "a POST /api/workspaces/:workspace_id/:param route is registered at byte {d}, AFTER default-project at byte {d} - it would shadow it\n",
                .{ pos, ours },
            );
            _ = tail_end;
            return error.DefaultProjectRouteShadowed;
        }
        i = after;
    }
}

test "no POST /api/workspaces/:workspace_id/:param route exists at all" {
    // Stronger than the ordering test above: it proves the collision is
    // impossible today, not merely absent right now. `.../items`,
    // `.../items/agent`, `.../items/kanban`, `.../items/design`,
    // `.../items/routine` are all literals, so they are fine.
    const alloc = testing.allocator;
    const src = try readMainSource(alloc);
    defer alloc.free(src);

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, route_marker)) |pos| {
        const after = pos + route_marker.len;
        if (src[after] == ':') {
            const end = std.mem.indexOfScalarPos(u8, src, after, '"') orelse src.len;
            std.debug.print(
                "found a bare param route: authed.post(\"/api/workspaces/:workspace_id/{s}\"\n",
                .{src[after..end]},
            );
            return error.ParamRouteAfterWorkspaceId;
        }
        i = after;
    }
}

test "the default-project route uses a literal segment, not a param" {
    // The whole anti-shadowing argument rests on `default-project` being a
    // literal. If someone "simplifies" it to a param, the ordering test
    // above would keep passing while the route quietly became ambiguous —
    // so assert the literal directly.
    const alloc = testing.allocator;
    const src = try readMainSource(alloc);
    defer alloc.free(src);

    const bad = "authed.post(\"/api/workspaces/:workspace_id/:param/default-project\"";
    if (std.mem.indexOf(u8, src, bad) != null) return error.DefaultProjectRouteIsAParam;

    const good = default_project_route;
    if (std.mem.indexOf(u8, src, good) == null) return error.DefaultProjectRouteNotRegistered;
}
