// Wire tests for the `spawn_sub_agent` required-tools + worktree wording.
//
// Zig port of `tests/functional/spawn_sub_agent_tools_required_test.py`
// (same test names, same order).
//
// WHAT THIS COVERS
// ================
// `spawn_sub_agent` (`src/modules/agent/tools/spawn_sub_agent.zig`) now
// requires an explicit per-sub-agent `tools` allowlist (missing, empty,
// or `["all"]` is a parse error — no omit-means-all) and teaches the
// explorer-shares / writer-isolates worktree rule. The model learns
// both rules from the tool-level `description`, which is exactly what
// `GET /api/agent-tools/registry` exposes (`{tools: [{name,
// description}]}` built from `UNIFIED_TOOL_REGISTRY()`, the same source
// the workflow fills the LLM's `tools[]` from).
//
// There is NO HTTP hook that executes a spawn: the only production
// caller is the exec adapter (`tools_exec_spawn_sub_agent.zig`), which
// runs exclusively inside the LLM agentic loop and therefore needs
// live LLM API credentials (unavailable in this environment). So these
// tests drive the strongest feasible path without creds:
//
//   1. `GET /api/agent-tools/registry`, index by name.
//   2. Assert the `spawn_sub_agent` description carries the
//      load-bearing sentences (not just keywords), and that the old
//      omit-means-all sentence stays dead.
//
// WHAT THIS DOES NOT COVER (needs LLM creds)
// ==========================================
// The `<results>` envelope for missing/empty/`all` tools is never
// produced here — no chat completion is issued. That parse rejection
// IS covered by the Zig unit tests inline in `spawn_sub_agent.zig`
// (MissingSubAgentTools / EmptySubAgentTools / AllToolsNotAllowed). A
// regression in the envelope rendering would fail `zig build test`, not
// this file. The `parameters` schema text and per-tool `system_prompt`
// are not exposed by any HTTP route, so their wording is locked by the
// inline description/prompt tests in the same Zig file instead.
//
// Run:
//     PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \
//       zig build test

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const REGISTRY_ROUTE = "/api/agent-tools/registry";

// ============================================================================
// Helpers
// ============================================================================

/// `GET /api/agent-tools/registry` indexed by name.
///
/// The Python original returned `{t["name"]: t for t in tools}` after
/// asserting the list is non-empty and that EVERY entry carries both
/// `name` and `description`. Those per-entry shape assertions are
/// load-bearing: an entry missing `description` is exactly how a
/// hand-written tool silently drops the sentence the next test is
/// about to look for, so they are kept verbatim rather than folded
/// into the lookup.
///
/// The map's keys and values both BORROW from `doc`'s parse arena, so
/// `deinit` must run before `doc.deinit` — which is the order
/// `Registry.deinit` below spells out.
const Registry = struct {
    resp: harness.Response,
    doc: harness.Json,
    by_name: std.StringArrayHashMapUnmanaged([]const u8),

    fn load(h: *Harness) !Registry {
        var resp = try h.http(io, .GET, REGISTRY_ROUTE, .{ .expect = &.{200} });
        errdefer resp.deinit();
        var doc = try resp.json();
        errdefer doc.deinit();

        var by_name: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        errdefer by_name.deinit(gpa);

        const tools = doc.array("tools") orelse {
            std.debug.print("registry response has no `tools` array: {s}\n", .{resp.body});
            return error.TestUnexpectedResult;
        };
        if (tools.items.len == 0) {
            std.debug.print("empty registry: {s}\n", .{resp.body});
            return error.TestUnexpectedResult;
        }

        for (tools.items) |entry| {
            const obj = switch (entry) {
                .object => |o| o,
                else => {
                    std.debug.print("registry entry is not an object: {s}\n", .{resp.body});
                    return error.TestUnexpectedResult;
                },
            };
            const name = switch (obj.get("name") orelse {
                std.debug.print("registry entry missing 'name': {s}\n", .{resp.body});
                return error.TestUnexpectedResult;
            }) {
                .string => |s| s,
                else => {
                    std.debug.print("registry entry 'name' is not a string\n", .{});
                    return error.TestUnexpectedResult;
                },
            };
            const desc = switch (obj.get("description") orelse {
                std.debug.print("registry entry {s} missing 'description'\n", .{name});
                return error.TestUnexpectedResult;
            }) {
                .string => |s| s,
                else => {
                    std.debug.print("registry entry {s} 'description' is not a string\n", .{name});
                    return error.TestUnexpectedResult;
                },
            };
            try by_name.put(gpa, name, desc);
        }

        return .{ .resp = resp, .doc = doc, .by_name = by_name };
    }

    fn deinit(self: *Registry) void {
        // Map FIRST: its keys/values point into the parse arena below.
        self.by_name.deinit(gpa);
        self.doc.deinit();
        self.resp.deinit();
    }

    /// The description the MODEL is sent for `name`, or null.
    fn description(self: *const Registry, name: []const u8) ?[]const u8 {
        return self.by_name.get(name);
    }

    /// The registry's names, sorted — the Python `sorted(tools)` in the
    /// "missing from registry" failure message.
    fn sortedNames(self: *const Registry) ![]const []const u8 {
        const names = try gpa.alloc([]const u8, self.by_name.count());
        errdefer gpa.free(names);
        var it = self.by_name.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) names[i] = kv.key_ptr.*;
        std.mem.sort([]const u8, names, {}, strLessThan);
        return names;
    }
};

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The description for `name`, failing with the registry's sorted name
/// list if the tool is absent.
///
/// Python: `assert "spawn_sub_agent" in tools, f"… missing from
/// registry: {sorted(tools)}"`.
fn requireDescription(reg: *const Registry, name: []const u8) ![]const u8 {
    if (reg.description(name)) |d| return d;
    const names = reg.sortedNames() catch return error.TestUnexpectedResult;
    defer gpa.free(names);
    std.debug.print("{s} missing from registry: [", .{name});
    for (names, 0..) |n, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{n});
    }
    std.debug.print("]\n", .{});
    return error.TestUnexpectedResult;
}

/// `needle` must occur in `desc`. Prints the whole description on
/// failure — a substring assertion is unreadable without it.
fn expectCarries(desc: []const u8, tool: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, desc, needle) != null) return;
    std.debug.print(
        "`{s}` description does not carry {s}:\n--- description ---\n{s}\n--- end ---\n",
        .{ tool, (harness.debugString(gpa, needle) catch "?"), desc },
    );
    return error.TestUnexpectedResult;
}

/// `needle` must NOT occur in `desc`. The old omit-means-all sentence
/// is the load-bearing negative: leaving it in place would teach the
/// model exactly what the feature forbids.
fn expectAbsent(desc: []const u8, tool: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, desc, needle) == null) return;
    std.debug.print(
        "`{s}` description still carries the removed sentence {s}:\n--- description ---\n{s}\n--- end ---\n",
        .{ tool, (harness.debugString(gpa, needle) catch "?"), desc },
    );
    return error.TestUnexpectedResult;
}

// ============================================================================
// Tests
// ============================================================================

// The model-facing description must demand an explicit allowlist.
//
// The WHAT is the point of the feature: without this sentence the
// model keeps omitting `tools` and every child silently receives ALL
// tools. Asserting the sentences (not just the word "required") is
// what keeps the rule from being edited away later.
test "spawn_description_requires_explicit_tools" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var reg = try Registry.load(&h);
    defer reg.deinit();

    const desc = try requireDescription(&reg, "spawn_sub_agent");

    // WHAT: required explicit allowlist, with the three rejected shapes
    // named.
    try expectCarries(desc, "spawn_sub_agent", "REQUIRED, explicit allowlist");
    try expectCarries(desc, "spawn_sub_agent", "Missing, empty, or [\"all\"] is rejected");
    try expectCarries(desc, "spawn_sub_agent", "There is no omit-means-all");
    // The old omit-means-all sentence must stay dead.
    try expectAbsent(desc, "spawn_sub_agent", "Omit \"tools\" to give the sub-agent access to ALL");
    // Unknown names are ignored (allowlistFilter), never an error.
    try expectCarries(desc, "spawn_sub_agent", "Unknown names are ignored");
}

// The description must carry the worktree rule with its trigger.
//
// Explorer-code (read-only) shares the parent cwd — NO new worktree.
// A writer must be told explicitly in `instruction` to call
// `set_git_worktree` first, work there, then summarize (and optionally
// push). Without the trigger words the model either isolates explorers
// (wasted worktrees) or shares writers (dirty parent checkout).
test "spawn_description_teaches_explorer_shares_writer_isolates" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var reg = try Registry.load(&h);
    defer reg.deinit();

    const desc = try requireDescription(&reg, "spawn_sub_agent");

    try expectCarries(desc, "spawn_sub_agent", "Explorer-code sub-agent");
    try expectCarries(desc, "spawn_sub_agent", "NO new worktree");
    try expectCarries(desc, "spawn_sub_agent", "set_git_worktree");
    try expectCarries(desc, "spawn_sub_agent", "return a summary of changed files");
    try expectCarries(desc, "spawn_sub_agent", "whether it pushed");
}
