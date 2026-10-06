// Functional tests for the Agent Knowledge EDIT flow (PR #291).
//
// Zig port of `tests/functional/agent_knowledge_edit_test.py` (same
// test names, same order).
//
// Python docstring, preserved verbatim:
//
//   """Functional tests for the Agent Knowledge EDIT flow (PR #291).
//
//   Exercises the PATCH /api/agents/:agent_id/knowledge/:knowledge_id
//   endpoint against a REAL pabrik binary + REAL SQLite, replaying the
//   EXACT JSON bodies the frontend edit dialog sends.
//
//     Plan: docs/superpowers/plans/2026-08-22-agent-mode-ui-ux.md
//     Lesson (2026-08-22): the first implementation passed unit tests but
//     failed in real use because
//       1. `file_path: ""` (text-mode save) hit `isAbsolute("") == false`
//          → 400 "file_path must be absolute".
//       2. `content: ""` (file-mode save) hit the SqliteBackend
//          empty-slice-binds-as-NULL gotcha → 500 NOT NULL constraint.
//     These tests replay both payloads end-to-end so neither regression
//     can ship again.
//
//   Covers:
//     * TEXT-MODE SAVE  — {label, content, file_path:""} → 200, row flips
//       to content-backed (file_path cleared, content set).
//     * FILE-MODE SAVE  — {label, file_path, content:""} → 200, row flips
//       to file-backed (content cleared, NOT a 500).
//     * ROUND-TRIP      — file→text→file→text switches keep the row
//       consistent after every hop.
//     * LABEL-ONLY      — {label} alone → 200, source fields untouched.
//     * GUARD           — non-empty relative file_path still → 400.
//     * ROUTE ORDER     — PATCH /knowledge/reorder reaches the REORDER
//       handler (not shadowed by /knowledge/:knowledge_id).
//   """
//
// THE PATH SEMANTICS ARE THE POINT OF THIS SUITE, so each case's exact
// path shape is preserved rather than normalised:
//
//   * The agent item's `path` and every seeded `file_path` come from
//     `harness.harnessPath(gpa, h.temp_dir, ...)` — NEVER a literal
//     `/tmp/...`. The server validates with `std.fs.path.isAbsolute`,
//     which is platform-relative, so a literal that is correct on
//     ubuntu-24.04 fails at the HTTP door on windows-2022 and the test
//     reports a server regression that does not exist.
//   * `file_path: ""` in a PATCH body is NOT a path at all — it is the
//     text-mode-save signal ("clear the column"), and it must reach the
//     wire as a literal empty string. That is the whole regression this
//     file was written for.
//   * The GUARD case keeps its deliberately RELATIVE, non-empty
//     `relative/path.md`, because the empty-string exemption must not
//     weaken the absolute-path check. Writing that one through
//     `harnessPath` would delete the test.
//
// PYTHON IDIOM THAT DID NOT SURVIVE THE PORT: `_add_inline_knowledge`
// and `_patch` returned the already-parsed dict, and every caller read
// fields off it. A `harness.Json` borrows the bytes of the `Response`
// body it was parsed from, so a helper may NOT return one. These
// helpers return OWNED values instead — an id string, the raw body —
// and the tests that need several fields off one response parse it
// locally.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// `POST /api/workspaces {"name": ...}` → the new workspace's id. Owned.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `POST /api/workspaces/<ws>/items/agent {"name", "path"}` → the agent
/// item's id. Owned.
fn createAgent(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const agent_path = try harness.harnessPath(gpa, h.temp_dir, &.{"agent-knowledge-edit-test"});
    defer gpa.free(agent_path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .path = agent_path,
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{workspace_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const item = doc.object("item") orelse {
        std.debug.print("agent create returned no `item`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (item.get("id") orelse {
        std.debug.print("agent create item has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("agent create item id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// Seed one INLINE (text) knowledge row → its id. Owned.
fn addInlineKnowledge(h: *Harness, agent_id: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .file_path = "",
        .label = "Seed notes",
        .content = "seed body",
    }, .{});
    defer gpa.free(body);
    return postKnowledge(h, agent_id, body, &.{201});
}

/// Seed one FILE-BACKED knowledge row → its id. Owned.
///
/// The `file_path` is `<harness temp_dir>/agent-knowledge-edit-test/seed.md` —
/// absolute, and deliberately a file that does not exist: the endpoint
/// stores the string, it does not read the file.
fn addFileKnowledge(h: *Harness, agent_id: []const u8) ![]u8 {
    const seed_path = try harness.harnessPath(gpa, h.temp_dir, &.{ "agent-knowledge-edit-test", "seed.md" });
    defer gpa.free(seed_path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .file_path = seed_path,
        .label = "Seed file",
        .content = "",
    }, .{});
    defer gpa.free(body);
    return postKnowledge(h, agent_id, body, &.{201});
}

/// `POST /api/agents/<agent>/knowledge` → the created row's id. Owned.
fn postKnowledge(h: *Harness, agent_id: []const u8, json_body: []const u8, expect: []const u16) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/knowledge", .{agent_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = json_body, .expect = expect });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("knowledge create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `PATCH /api/agents/<agent>/knowledge/<kid>` → the response body as
/// OWNED bytes. A `harness.Json` would alias the `Response` body this
/// frame frees, so the caller parses.
fn patchKnowledge(
    h: *Harness,
    agent_id: []const u8,
    knowledge_id: []const u8,
    json_body: []const u8,
    expect: []const u16,
) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/knowledge/{s}", .{ agent_id, knowledge_id });
    defer gpa.free(path);

    var r = try h.http(io, .PATCH, path, .{ .json_body = json_body, .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `GET /api/workspaces/<ws>/items/<agent>/agent` → OWNED bytes; the
/// caller reads `body["knowledge"]`.
fn getKnowledge(h: *Harness, workspace_id: []const u8, agent_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/{s}/agent", .{ workspace_id, agent_id });
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// The knowledge row whose `id` is `knowledge_id`, borrowed from the
/// live document. `null` when there is no such row.
fn findRow(doc: *const harness.Json, knowledge_id: []const u8) ?std.json.ObjectMap {
    const rows = doc.array("knowledge") orelse return null;
    for (rows.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (obj.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, id, knowledge_id)) return obj;
    }
    return null;
}

fn expectEqualStr(doc: *const harness.Json, key: []const u8, want: []const u8) !void {
    const got = doc.str(key) orelse {
        std.debug.print("response has no string `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("`{s}` = \"{s}\", expected \"{s}\"\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

fn expectRowStr(obj: std.json.ObjectMap, key: []const u8, want: []const u8, body: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("row has no `{s}`: {s}\n", .{ key, body });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .string => |s| s,
        else => {
            std.debug.print("row `{s}` is not a string: {s}\n", .{ key, body });
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got, want)) {
        const shown = try harness.debugString(gpa, got);
        defer gpa.free(shown);
        const expected = try harness.debugString(gpa, want);
        defer gpa.free(expected);
        std.debug.print("row `{s}` = \"{s}\", expected \"{s}\"\n", .{ key, shown, expected });
        return error.TestUnexpectedResult;
    }
}

fn containsIgnoreCase(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle_lower.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle_lower.len], needle_lower)) return true;
    }
    return false;
}

// ============================================================================
// Regression 1: text-mode save (used to 400 NotAbsolutePath)
// ============================================================================

// The edit dialog's Text-mode save sends {label, content, file_path:""}.
//
// Regression: `isAbsolute("")` is false, so the old useCase rejected
// this with 400 "file_path must be absolute". Empty string must mean
// "clear the column" (switch to content-backed), not an error.
test "text_mode_save_clears_file_path_and_sets_content" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "knowledge-edit-ws");
    defer gpa.free(ws);
    const agent = try createAgent(&h, ws, "edit-agent");
    defer gpa.free(agent);
    const row_id = try addFileKnowledge(&h, agent);
    defer gpa.free(row_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .label = "Switched to text",
        .content = "inline body after switch",
        .file_path = "",
    }, .{});
    defer gpa.free(body);

    const raw = try patchKnowledge(&h, agent, row_id, body, &.{200});
    defer gpa.free(raw);

    {
        var doc = try parseJson(raw);
        defer doc.deinit();
        // file_path should be cleared after text-mode save.
        try expectEqualStr(&doc, "file_path", "");
        try expectEqualStr(&doc, "content", "inline body after switch");
        try expectEqualStr(&doc, "label", "Switched to text");
    }

    // Refetch through the agent GET — the row must be consistent there too.
    const rows_raw = try getKnowledge(&h, ws, agent);
    defer gpa.free(rows_raw);

    var rows = try parseJson(rows_raw);
    defer rows.deinit();

    const mine = findRow(&rows, row_id) orelse {
        std.debug.print("knowledge row {s} missing from the agent GET: {s}\n", .{ row_id, rows_raw });
        return error.TestUnexpectedResult;
    };
    try expectRowStr(mine, "file_path", "", rows_raw);
    try expectRowStr(mine, "content", "inline body after switch", rows_raw);
}

// ============================================================================
// Regression 2: file-mode save (used to 500 NOT NULL constraint)
// ============================================================================

// The edit dialog's File-mode save sends {label, file_path, content:""}.
//
// Regression: SqliteBackend.exec binds empty slices as SQL NULL, so
// `content: ""` violated the NOT NULL constraint → 500. Empty string
// must land as '' (clear the column), not NULL.
test "file_mode_save_clears_content_and_sets_path" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "knowledge-edit-ws");
    defer gpa.free(ws);
    const agent = try createAgent(&h, ws, "edit-agent");
    defer gpa.free(agent);
    const row_id = try addInlineKnowledge(&h, agent);
    defer gpa.free(row_id);

    const switched = try harness.harnessPath(gpa, h.temp_dir, &.{ "agent-knowledge-edit-test", "switched.md" });
    defer gpa.free(switched);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .label = "Switched to file",
        .file_path = switched,
        .content = "",
    }, .{});
    defer gpa.free(body);

    const raw = try patchKnowledge(&h, agent, row_id, body, &.{200});
    defer gpa.free(raw);

    try expectEqualStrOwned(raw, "file_path", switched);
    // content should be cleared to ''
    try expectEqualStrOwned(raw, "content", "");

    const rows_raw = try getKnowledge(&h, ws, agent);
    defer gpa.free(rows_raw);

    var rows = try parseJson(rows_raw);
    defer rows.deinit();

    const mine = findRow(&rows, row_id) orelse {
        std.debug.print("knowledge row {s} missing from the agent GET: {s}\n", .{ row_id, rows_raw });
        return error.TestUnexpectedResult;
    };
    try expectRowStr(mine, "file_path", switched, rows_raw);
    try expectRowStr(mine, "content", "", rows_raw);
}

// ============================================================================
// Round-trip: repeated mode switches stay consistent
// ============================================================================

// file→text→file→text: every hop must 200 and leave the row XOR-
// consistent (exactly one of file_path/content non-empty).
test "mode_switch_round_trip_file_text_file_text" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "knowledge-edit-ws");
    defer gpa.free(ws);
    const agent = try createAgent(&h, ws, "edit-agent");
    defer gpa.free(agent);
    const kid = try addFileKnowledge(&h, agent);
    defer gpa.free(kid);

    // hop 1: file → text
    {
        const body = try std.json.Stringify.valueAlloc(gpa, .{
            .label = "hop1",
            .content = "body one",
            .file_path = "",
        }, .{});
        defer gpa.free(body);

        const raw = try patchKnowledge(&h, agent, kid, body, &.{200});
        defer gpa.free(raw);

        var doc = try parseJson(raw);
        defer doc.deinit();
        try expectEqualStr(&doc, "file_path", "");
        try expectEqualStr(&doc, "content", "body one");
    }

    // hop 2: text → file
    {
        const hop2 = try harness.harnessPath(gpa, h.temp_dir, &.{ "agent-knowledge-edit-test", "hop2.md" });
        defer gpa.free(hop2);

        const body = try std.json.Stringify.valueAlloc(gpa, .{
            .label = "hop2",
            .file_path = hop2,
            .content = "",
        }, .{});
        defer gpa.free(body);

        const raw = try patchKnowledge(&h, agent, kid, body, &.{200});
        defer gpa.free(raw);

        var doc = try parseJson(raw);
        defer doc.deinit();
        try expectEqualStr(&doc, "file_path", hop2);
        try expectEqualStr(&doc, "content", "");
    }

    // hop 3: file → text again
    {
        const body = try std.json.Stringify.valueAlloc(gpa, .{
            .label = "hop3",
            .content = "body three",
            .file_path = "",
        }, .{});
        defer gpa.free(body);

        const raw = try patchKnowledge(&h, agent, kid, body, &.{200});
        defer gpa.free(raw);

        var doc = try parseJson(raw);
        defer doc.deinit();
        try expectEqualStr(&doc, "file_path", "");
        try expectEqualStr(&doc, "content", "body three");
    }

    // Final state via GET.
    const rows_raw = try getKnowledge(&h, ws, agent);
    defer gpa.free(rows_raw);

    var rows = try parseJson(rows_raw);
    defer rows.deinit();

    const mine = findRow(&rows, kid) orelse {
        std.debug.print("knowledge row {s} missing from the agent GET: {s}\n", .{ kid, rows_raw });
        return error.TestUnexpectedResult;
    };
    try expectRowStr(mine, "label", "hop3", rows_raw);
    try expectRowStr(mine, "content", "body three", rows_raw);
    try expectRowStr(mine, "file_path", "", rows_raw);
}

// A label-only PATCH must not touch file_path or content.
test "label_only_update_keeps_source_fields" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "knowledge-edit-ws");
    defer gpa.free(ws);
    const agent = try createAgent(&h, ws, "edit-agent");
    defer gpa.free(agent);
    const row_id = try addInlineKnowledge(&h, agent);
    defer gpa.free(row_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{ .label = "Renamed only" }, .{});
    defer gpa.free(body);

    const raw = try patchKnowledge(&h, agent, row_id, body, &.{200});
    defer gpa.free(raw);

    var doc = try parseJson(raw);
    defer doc.deinit();
    try expectEqualStr(&doc, "label", "Renamed only");
    try expectEqualStr(&doc, "content", "seed body");
    try expectEqualStr(&doc, "file_path", "");
}

// ============================================================================
// Guard: non-empty relative path is still rejected
// ============================================================================

// The empty-string exemption must not weaken the absolute-path guard.
//
// `relative/path.md` is deliberately NOT routed through `harnessPath`:
// it is the one payload in this file that must stay relative, or the
// test asserts nothing.
test "relative_path_still_rejected" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "knowledge-edit-ws");
    defer gpa.free(ws);
    const agent = try createAgent(&h, ws, "edit-agent");
    defer gpa.free(agent);
    const row_id = try addInlineKnowledge(&h, agent);
    defer gpa.free(row_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .file_path = "relative/path.md",
    }, .{});
    defer gpa.free(body);

    const raw = try patchKnowledge(&h, agent, row_id, body, &.{400});
    defer gpa.free(raw);

    var doc = try parseJson(raw);
    defer doc.deinit();

    const message = doc.str("error") orelse "";
    if (!containsIgnoreCase(message, "absolute")) {
        std.debug.print("expected an absolute-path error, got: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Route-order: /knowledge/reorder must not be shadowed
// ============================================================================

// PATCH /api/agents/:id/knowledge/reorder must reach the REORDER
// handler. The router matches in registration order, so if
// /knowledge/:knowledge_id is registered first, this request would be
// captured with knowledge_id="reorder" (pre-existing bug caught by
// writing these tests).
test "reorder_route_not_shadowed_by_param_route" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "knowledge-edit-ws");
    defer gpa.free(ws);
    const agent = try createAgent(&h, ws, "edit-agent");
    defer gpa.free(agent);
    const row_a = try addInlineKnowledge(&h, agent);
    defer gpa.free(row_a);
    const row_b = try addFileKnowledge(&h, agent);
    defer gpa.free(row_b);

    // Reorder: put row_b before row_a.
    {
        const body = try std.json.Stringify.valueAlloc(gpa, .{
            .ordered_ids = &[_][]const u8{ row_b, row_a },
        }, .{});
        defer gpa.free(body);

        const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/knowledge/reorder", .{agent});
        defer gpa.free(path);

        var r = try h.http(io, .PATCH, path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();

        // `assert r.json().get("ok") is True` — a missing key must fail.
        const ok = doc.boolean("ok") orelse {
            std.debug.print("reorder response has no boolean `ok`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!ok) {
            std.debug.print("reorder response `ok` is false: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // GET must reflect the new order (position DESC per agents_get).
    const rows_raw = try getKnowledge(&h, ws, agent);
    defer gpa.free(rows_raw);

    var rows = try parseJson(rows_raw);
    defer rows.deinit();

    const knowledge = rows.array("knowledge") orelse {
        std.debug.print("agent GET has no `knowledge` array: {s}\n", .{rows_raw});
        return error.TestUnexpectedResult;
    };
    const idx_b = indexOfId(knowledge, row_b) orelse {
        std.debug.print("row {s} missing from the knowledge list: {s}\n", .{ row_b, rows_raw });
        return error.TestUnexpectedResult;
    };
    const idx_a = indexOfId(knowledge, row_a) orelse {
        std.debug.print("row {s} missing from the knowledge list: {s}\n", .{ row_a, rows_raw });
        return error.TestUnexpectedResult;
    };
    if (idx_b >= idx_a) {
        std.debug.print("reorder did not take effect: b at {d}, a at {d}: {s}\n", .{ idx_b, idx_a, rows_raw });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Assertion helpers
// ============================================================================

fn indexOfId(knowledge: std.json.Array, id: []const u8) ?usize {
    for (knowledge.items, 0..) |row, i| {
        const obj = switch (row) {
            .object => |o| o,
            else => continue,
        };
        const got = switch (obj.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, got, id)) return i;
    }
    return null;
}

/// Assert `key` of a document this helper has not parsed is `want`.
///
/// Used where the caller already owns the raw bytes but not a live
/// `Json` — parsing here is cheaper than threading a `deinit` through
/// the caller's scope for a single assertion.
fn expectEqualStrOwned(raw: []const u8, key: []const u8, want: []const u8) !void {
    var doc = try parseJson(raw);
    defer doc.deinit();
    return expectEqualStr(&doc, key, want);
}

comptime {
    // Body-analysis barrier — an unreferenced helper is never
    // type-checked, so a stdlib rename inside one stays invisible.
    _ = createWorkspace;
    _ = createAgent;
    _ = addInlineKnowledge;
    _ = addFileKnowledge;
    _ = postKnowledge;
    _ = patchKnowledge;
    _ = getKnowledge;
    _ = parseJson;
    _ = findRow;
    _ = indexOfId;
    _ = expectEqualStr;
    _ = expectEqualStrOwned;
    _ = expectRowStr;
    _ = containsIgnoreCase;
}
