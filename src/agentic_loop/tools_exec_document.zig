//! Exec wrappers for the `add_document` / `edit_document` agent tools
//! (Migration 098).
//!
//! The wrapper's whole job is three things the pure tool module must not
//! do: parse the model's JSON arguments, hand `ctx.session_id` down as a
//! plain parameter (so the tool can resolve its own workspace), and wrap
//! the inner payload in the `wrapToolOutput` envelope.
//!
//! Two details that are load-bearing, not boilerplate:
//!
//!  1. `.{ .allocate = .alloc_always, .ignore_unknown_fields = true }`.
//!     `ignore_unknown_fields` is what makes a hallucinated
//!     `"workspace_id": "ws_other"` harmless — it is dropped on the floor
//!     rather than honoured. The tool module has no `workspace_id` field
//!     for it to land in, and `static contract: document tools never
//!     accept a workspace_id` in `document.zig` fails the build if one is
//!     ever added.
//!  2. The `InnerErrorProbe` re-parse. The tool returns
//!     `{"error": "..."}` as its inner payload; without re-probing, that
//!     would be wrapped as `success: true` and the model would read a
//!     refused cross-workspace edit as a completed one.
//!
//! `inner` is intentionally NOT freed here: it comes from the per-iteration
//! arena, matching `execReadWorkspaceSession`. The parse scratch IS freed
//! via `parsed.deinit()`.

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const document_mod = nalarcore.document_tool;
const wrapToolOutput = tools.wrapToolOutput;

/// Probe an inner JSON payload for a top-level `"error"` key. The returned
/// slice borrows from `parsed` — keep it alive through the
/// `wrapToolOutput` call, then `deinit`. A payload that fails to parse is
/// treated as success (the producers always emit valid JSON).
const InnerErrorProbe = struct {
    @"error": ?[]const u8 = null,
};

pub fn execAddDocument(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        document_mod.AddDocumentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "add_document failed to parse input: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_document", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // Workspace scope is derived server-side from the calling session —
    // the LLM never supplies (or spoofs) a workspace id.
    const inner = document_mod.executeAddDocument(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "add_document failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_document", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // The tool module allocated `inner` from `ctx.allocator`, so the
    // wrapper owns it. `defer` fires after `wrapToolOutput` has copied
    // what it needs — the same ownership shape `execSaveMemory` uses.
    defer ctx.allocator.free(inner);

    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "add_document", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "add_document", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execEditDocument(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        document_mod.EditDocumentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "edit_document failed to parse input: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "edit_document", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = document_mod.executeEditDocument(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "edit_document failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "edit_document", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // The tool module allocated `inner` from `ctx.allocator`, so the
    // wrapper owns it. `defer` fires after `wrapToolOutput` has copied
    // what it needs — the same ownership shape `execSaveMemory` uses.
    defer ctx.allocator.free(inner);

    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "edit_document", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "edit_document", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = nalarcore.sqlite;
const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(testing.allocator,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT DEFAULT 'active', cwd TEXT)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)
    , &.{});
    try migration.Migration098CreateDocuments.up(&db, testing.allocator);

    try db.exec(testing.allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES
        \\  ('i1', 'ws_1', 'kanban', 'A', '/proj/a', 1),
        \\  ('i2', 'ws_2', 'kanban', 'B', '/proj/b', 1)
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES
        \\  ('s1', 'T1', 'i1'), ('s2', 'T2', 'i2')
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO sessions (id, name, status, cwd) VALUES
        \\  ('s1', 'One', 'active', '/proj/a'),
        \\  ('s2', 'Two', 'active', '/proj/b')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn makeTestCtx(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = testing.io,
        .db = db,
        .logger = undefined,
        .session_id = session_id,
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test-key",
        .base_url = "http://test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .active_loops = undefined,
    };
}

fn fakeToolCall(name: []const u8, args: []const u8) agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = args },
    };
}

/// Flattened, OWNED view of a tool envelope.
///
/// Two things this deliberately does not do:
///
///  - Return `p.value` after `deinit()`. `std.json.parseFromSlice`
///    allocates every string into an arena owned by `Parsed`, and
///    `deinit` frees it — so a returned struct of those slices is a
///    dangling-pointer farm that segfaults inside `std.mem.eql` on the
///    first comparison, with nothing in the trace pointing at the
///    lifetime bug. Hence: dup everything, free it in `deinit`.
///  - Expose `data` as a `std.json.Value`. A Value is a TREE of arena
///    slices; keeping it would mean keeping the whole arena alive and
///    carefully not outliving it. The four fields the assertions
///    actually read are lifted to the top level instead.
const Envelope = struct {
    allocator: std.mem.Allocator,
    tool: []const u8 = "",
    success: bool = false,
    err: ?[]const u8 = null,
    id: []const u8 = "",
    workspace_id: []const u8 = "",
    title: []const u8 = "",
    content: []const u8 = "",

    fn deinit(self: *Envelope) void {
        const a = self.allocator;
        a.free(self.tool);
        if (self.err) |e| a.free(e);
        a.free(self.id);
        a.free(self.workspace_id);
        a.free(self.title);
        a.free(self.content);
    }
};

fn parseEnvelope(allocator: std.mem.Allocator, raw: []const u8) !Envelope {
    const Wire = struct {
        tool: []const u8 = "",
        success: bool = false,
        @"error": ?[]const u8 = null,
        data: ?struct {
            id: []const u8 = "",
            workspace_id: []const u8 = "",
            title: []const u8 = "",
            content: []const u8 = "",
        } = null,
    };
    const p = try std.json.parseFromSlice(Wire, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer p.deinit();
    return .{
        .allocator = allocator,
        .tool = try allocator.dupe(u8, p.value.tool),
        .success = p.value.success,
        .err = if (p.value.@"error") |e| try allocator.dupe(u8, e) else null,
        .id = try allocator.dupe(u8, if (p.value.data) |d| d.id else ""),
        .workspace_id = try allocator.dupe(u8, if (p.value.data) |d| d.workspace_id else ""),
        .title = try allocator.dupe(u8, if (p.value.data) |d| d.title else ""),
        .content = try allocator.dupe(u8, if (p.value.data) |d| d.content else ""),
    };
}

test "execAddDocument: success envelope carries the created document" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tc = makeTestCtx(alloc, &ctx.db, "s1");
    const result = try execAddDocument(tc, fakeToolCall(
        "add_document",
        "{\"title\":\"Notes\",\"content\":\"# hi\"}"
    ));
    defer alloc.free(result.output);

    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try testing.expectEqualStrings("add_document", env.tool);
    try testing.expect(env.success);
    try testing.expect(env.err == null);
    try testing.expectEqualStrings("ws_1", env.workspace_id);
    try testing.expectEqualStrings("Notes", env.title);
}

test "execAddDocument: a tool-level refusal surfaces as success=false" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The tool returns {"error": "..."} as its INNER payload. Without the
    // InnerErrorProbe re-parse this would be wrapped as success=true and
    // the model would read a refusal as a written document.
    const tc = makeTestCtx(alloc, &ctx.db, "");
    const result = try execAddDocument(tc, fakeToolCall("add_document", "{\"title\":\"Nowhere\"}"));
    defer alloc.free(result.output);

    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try testing.expect(!env.success);
    try testing.expect(env.err != null);
    try testing.expect(std.mem.indexOf(u8, env.err.?, "session") != null);
}

test "execAddDocument: malformed JSON arguments become a parse failure, not a crash" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tc = makeTestCtx(alloc, &ctx.db, "s1");
    const result = try execAddDocument(tc, fakeToolCall("add_document", "{not json"));
    defer alloc.free(result.output);

    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try testing.expect(!env.success);
    try testing.expect(std.mem.indexOf(u8, env.err.?, "parse input") != null);
}

test "execAddDocument: a hallucinated workspace_id is ignored, not honoured" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // s1 belongs to ws_1. The model asks for ws_2. The wrapper parses with
    // ignore_unknown_fields, the field is dropped, and the write lands in
    // ws_1 — the session's own workspace, never the requested one.
    const tc = makeTestCtx(alloc, &ctx.db, "s1");
    const result = try execAddDocument(tc, fakeToolCall(
        "add_document",
        "{\"title\":\"Spoof attempt\",\"content\":\"x\",\"workspace_id\":\"ws_2\"}"
    ));
    defer alloc.free(result.output);

    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqualStrings("ws_1", env.workspace_id);
}

test "execEditDocument: a cross-workspace edit is refused and the row is untouched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const create = try execAddDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall(
        "add_document",
        "{\"title\":\"Private\",\"content\":\"TOPSECRET\"}"
    ));
    defer alloc.free(create.output);
    var created = try parseEnvelope(alloc, create.output);
    defer created.deinit();
    const id = created.id;

    const args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\",\"content\":\"hijacked\"}}", .{id});
    defer alloc.free(args);
    const edit = try execEditDocument(makeTestCtx(alloc, &ctx.db, "s2"), fakeToolCall(
        "edit_document",
        args,
    ));
    defer alloc.free(edit.output);

    var env = try parseEnvelope(alloc, edit.output);
    defer env.deinit();
    try testing.expect(!env.success);
    try testing.expect(env.err != null);
    try testing.expect(std.mem.indexOf(u8, edit.output, "TOPSECRET") == null);
}

test "execEditDocument: success envelope echoes the new body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const create = try execAddDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall(
        "add_document",
        "{\"title\":\"Plan\",\"content\":\"v1\"}"
    ));
    defer alloc.free(create.output);
    var created2 = try parseEnvelope(alloc, create.output);
    defer created2.deinit();
    const id = created2.id;

    const args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\",\"content\":\"v2\"}}", .{id});
    defer alloc.free(args);
    const edit = try execEditDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("edit_document", args));
    defer alloc.free(edit.output);

    var env = try parseEnvelope(alloc, edit.output);
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqualStrings("v2", env.content);
    // The title was omitted, so it must have survived.
    try testing.expectEqualStrings("Plan", env.title);
}

// ─── Static wiring contracts ────────────────────────────────────────────
// These grep the wiring files so a future refactor that drops a
// registration fails closed here instead of silently hiding the tools
// from the LLM (registered nowhere = the model can never call them, and
// nothing else in the build complains).

const equipped_src = @embedFile("tools_equipped.zig");
const tools_src = @embedFile("tools.zig");
const root_src = @embedFile("../root.zig");

test "static contract: document tools are wired into tools_equipped.zig" {
    // equips() (advertised to the model) + UNIFIED_TOOL_REGISTRY()
    // (dispatch) + DEFAULT_AGENT_TOOLS (seeded when an agent item is
    // created). All three are required: a registry entry alone makes the
    // tool dispatchable but invisible, an equips() entry alone makes it
    // visible but undispatchable.
    try testing.expect(std.mem.indexOf(u8, equipped_src, "document_mod") != null);
    try testing.expect(std.mem.indexOf(u8, equipped_src, "add_document_tool") != null);
    try testing.expect(std.mem.indexOf(u8, equipped_src, "edit_document_tool") != null);
    try testing.expect(std.mem.indexOf(u8, equipped_src, "execAddDocument") != null);
    try testing.expect(std.mem.indexOf(u8, equipped_src, "execEditDocument") != null);
    try testing.expect(std.mem.indexOf(u8, equipped_src, "\"add_document\"") != null);
    try testing.expect(std.mem.indexOf(u8, equipped_src, "\"edit_document\"") != null);
}

test "static contract: document exec wrappers are re-exported from tools.zig" {
    try testing.expect(std.mem.indexOf(u8, tools_src, "execAddDocument") != null);
    try testing.expect(std.mem.indexOf(u8, tools_src, "execEditDocument") != null);
    try testing.expect(std.mem.indexOf(u8, tools_src, "tools_exec_document.zig") != null);
}

test "static contract: the document tool module is aliased on the nalarcore root" {
    try testing.expect(std.mem.indexOf(u8, root_src, "document_tool") != null);
    try testing.expect(std.mem.indexOf(u8, root_src, "modules/agent/tools/document.zig") != null);
    // The store must be reachable from the same root, or the tool module
    // would have to reach into agentic_loop by relative path.
    try testing.expect(std.mem.indexOf(u8, root_src, "documents_store") != null);
    try testing.expect(std.mem.indexOf(u8, root_src, "agentic_loop/documents_store.zig") != null);
}
