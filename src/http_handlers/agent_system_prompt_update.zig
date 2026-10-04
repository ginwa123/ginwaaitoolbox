//! `PATCH /api/agents/:agent_id/system_prompt/:prompt_id`.
//!
//! Updates title and/or content of an existing system-prompt entry.
//! Body: `{title?, content?}` (both optional; at least one required).
//!
//! Layered as:
//!   - `useCase` — validate ids + body → build dynamic UPDATE SQL
//!     (Zig 0.16 dropped std.io.fixedBufferStream, so we use
//!     `ArrayList.appendSlice` for the static SQL fragments) →
//!     UPDATE → SELECT refetch → return typed SystemPrompt.
//!   - `agentSystemPromptUpdateHandler` — thin orchestrator over
//!     `useCase`: parses path/body, delegates, maps outcome to HTTP.
//!
//! Memory: the per-request arena reaps all allocations at request
//! end, so neither layer needs explicit `free`s.
//!
//! Plan: docs/superpowers/plans/2026-08-21-agent-system-prompt.md
//! Task: task_1787408958280_1

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");

/// HTTP request body. Decoupled from the domain `SystemPromptUpdateInput`
/// so the wire format can evolve independently without touching the
/// use-case.
const UpdateSystemPromptBody = struct {
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

/// Subset of the system-prompt row returned by the use-case.
pub const SystemPrompt = struct {
    id: []const u8,
    agent_id: []const u8,
    title: []const u8,
    content: []const u8,
    position: i64,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (intentional — adding a new variant fails to compile in
/// the handler until both switches are updated, keeping status
/// codes in lockstep with the error set).
pub const SystemPromptUpdateError = error{
    /// `agent_id` or `prompt_id` path param was missing or empty.
    IdsRequired,
    /// Body had neither `title` nor `content` (nothing to update).
    NothingToUpdate,
    /// `db.exec` failed on the UPDATE.
    UpdateFailed,
    /// Re-fetching the row after UPDATE failed.
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 404).
    RowNotFound,
    /// `allocator.alloc` failed while building the dynamic SQL.
    /// Unreachable under arena allocator but the type system requires
    /// the variant so `try` propagates a typed error.
    OutOfMemory,
};

/// Inputs to the system-prompt-update use-case.
pub const SystemPromptUpdateInput = struct {
    agent_id: []const u8,
    prompt_id: []const u8,
    title: ?[]const u8,
    content: ?[]const u8,
};

/// Output of the system-prompt-update use-case. `system_prompt` is owned by
/// the caller (lifetime = request arena).
pub const SystemPromptUpdateOutput = struct {
    system_prompt: SystemPrompt,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an existing system-prompt row. Validates that at least one of
/// `title` / `content` is provided, then UPDATE-with-dynamic-SQL the
/// requested fields and SELECT-refetch the row. The use-case is
/// transport-agnostic: it works for both the per-request arena
/// (production HTTP handler) and `testing.allocator` (unit tests
/// below) — all allocations go through the passed-in allocator.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: SystemPromptUpdateInput,
) SystemPromptUpdateError!SystemPromptUpdateOutput {
    if (input.agent_id.len == 0 or input.prompt_id.len == 0) {
        return error.IdsRequired;
    }
    if (input.title == null and input.content == null) {
        return error.NothingToUpdate;
    }

    // Build dynamic UPDATE SQL. Zig 0.16 dropped
    // std.io.fixedBufferStream, so we use ArrayList.appendSlice for
    // the static fragments.
    var sql_list: std.ArrayList(u8) = .empty;
    defer sql_list.deinit(allocator);
    try sql_list.appendSlice(allocator, "UPDATE agent_system_prompt SET updated_at = datetime('now')");
    if (input.title != null) try sql_list.appendSlice(allocator, ", title = COALESCE(?, '')");
    if (input.content != null) try sql_list.appendSlice(allocator, ", content = COALESCE(?, '')");
    try sql_list.appendSlice(allocator, " WHERE id = ? AND agent_id = ?");

    // Bind args. Max 4 slots: title, content, prompt_id, agent_id.
    var args_buf: [4][]const u8 = undefined;
    var arg_idx: usize = 0;
    if (input.title) |t| {
        args_buf[arg_idx] = t;
        arg_idx += 1;
    }
    if (input.content) |c| {
        args_buf[arg_idx] = c;
        arg_idx += 1;
    }
    args_buf[arg_idx] = input.prompt_id;
    arg_idx += 1;
    args_buf[arg_idx] = input.agent_id;
    arg_idx += 1;

    // Build argv slice for db.exec — pass an owned slice.
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    for (args_buf[0..arg_idx]) |a| try argv_list.append(allocator, a);

    db.exec(allocator, sql_list.items, argv_list.items) catch return error.UpdateFailed;

    // Read back.
    var q = db.query(allocator,
        "SELECT id, agent_id, title, content, position FROM agent_system_prompt WHERE id = ?",
        &[_][]const u8{input.prompt_id},
    ) catch return error.RefetchFailed;
    defer q.deinit();
    const r = (q.next() catch null) orelse return error.RowNotFound;
    defer r.deinit(allocator); // safe — we dupe the slices below
    const position = std.fmt.parseInt(i64, r.values[4], 10) catch 0;

    // Dupe the slices out of row.values[] so the SystemPrompt struct
    // owns them. Production: arena allocator reaps these at request
    // end. Tests: caller frees explicitly.
    const id = try allocator.dupe(u8, r.values[0]);
    errdefer allocator.free(id);
    const agent_id = try allocator.dupe(u8, r.values[1]);
    errdefer allocator.free(agent_id);
    const title = try allocator.dupe(u8, r.values[2]);
    errdefer allocator.free(title);
    const content = try allocator.dupe(u8, r.values[3]);
    errdefer allocator.free(content);

    return .{
        .system_prompt = .{
            .id = id,
            .agent_id = agent_id,
            .title = title,
            .content = content,
            .position = position,
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentSystemPromptUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";
    const prompt_id = req.params.get("prompt_id") orelse "";

    const parsed = std.json.parseFromSliceLeaky(UpdateSystemPromptBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
        .prompt_id = prompt_id,
        .title = parsed.title,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.NothingToUpdate => 400,
            error.UpdateFailed => 500,
            error.RefetchFailed => 500,
            error.RowNotFound => 404,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "agent_id and prompt_id required",
            error.NothingToUpdate => "title or content required",
            error.UpdateFailed => "Failed to update system prompt",
            error.RefetchFailed => "Failed to read row",
            error.RowNotFound => "system prompt row not found",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.system_prompt, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention for Agent Mode).
// Behavioural tests cover the use-case:
//
//   1. Validation: empty ids OR neither field → respective errors
//   2. Happy path: updates title AND content
//   3. title-only update keeps content
//   4. PATCH with empty-string content is legal (COALESCE → '',
//      NOT NULL — regression for empty-slice-binds-as-NULL)

const sqlite = @import("pabrikcore").sqlite;
const testing = std.testing;
const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = @import("../migrations/migration.zig").Migration076AddAgentsAndAgentKnowledgeAndAgentTools;
const Migration080AddAgentSystemPrompt = @import("../migrations/migration.zig").Migration080AddAgentSystemPrompt;

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

    // See agent_knowledge_delete.zig for why we re-create
    // workspace_items with the full shape.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration076AddAgentsAndAgentKnowledgeAndAgentTools.up(&db, testing.allocator);
    // Production DBs run every migration in order — the harness must
    // mirror that, or the agent_system_prompt table (Migration 080) is
    // missing.
    try Migration080AddAgentSystemPrompt.up(&db, testing.allocator);

    // Seed: 1 agent + 1 system-prompt row.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('ws_item_1', 'ws_item_1', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_system_prompt (id, agent_id, title, content, position) VALUES ('asp_1', 'ws_item_1', 'Original Title', 'Original body', 0)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty agent_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .agent_id = "",
            .prompt_id = "asp_1",
            .title = "New",
            .content = null,
        }),
    );
}

test "useCase: empty prompt_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .prompt_id = "",
            .title = "New",
            .content = null,
        }),
    );
}

test "useCase: neither title nor content returns NothingToUpdate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NothingToUpdate,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .prompt_id = "asp_1",
            .title = null,
            .content = null,
        }),
    );
}

test "useCase: happy path updates both title AND content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .prompt_id = "asp_1",
        .title = "New Title",
        .content = "New body",
    });
    defer {
        alloc.free(output.system_prompt.id);
        alloc.free(output.system_prompt.agent_id);
        alloc.free(output.system_prompt.title);
        alloc.free(output.system_prompt.content);
    }
    try testing.expectEqualStrings("asp_1", output.system_prompt.id);
    try testing.expectEqualStrings("New Title", output.system_prompt.title);
    try testing.expectEqualStrings("New body", output.system_prompt.content);
}

test "useCase: title-only update keeps content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .prompt_id = "asp_1",
        .title = "Renamed only",
        .content = null,
    });
    defer {
        alloc.free(output.system_prompt.id);
        alloc.free(output.system_prompt.agent_id);
        alloc.free(output.system_prompt.title);
        alloc.free(output.system_prompt.content);
    }
    try testing.expectEqualStrings("Renamed only", output.system_prompt.title);
    try testing.expectEqualStrings("Original body", output.system_prompt.content);
}

test "useCase: PATCH with empty-string content is legal (COALESCE binds '' not NULL)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Regression: SqliteBackend.exec binds "" as SQL NULL, which would
    // trip content's NOT NULL constraint without the COALESCE(?, '')
    // wrapper in the UPDATE SET clause.
    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .prompt_id = "asp_1",
        .title = null,
        .content = "",
    });
    defer {
        alloc.free(output.system_prompt.id);
        alloc.free(output.system_prompt.agent_id);
        alloc.free(output.system_prompt.title);
        alloc.free(output.system_prompt.content);
    }
    try testing.expectEqualStrings("", output.system_prompt.content);
    try testing.expectEqualStrings("Original Title", output.system_prompt.title);
}
