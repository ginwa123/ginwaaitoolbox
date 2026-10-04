//! `GET /api/workspaces/:workspace_id/documents`.
//!
//! Returns `{documents, count}` for one workspace, most-recently-updated
//! first. This is the read behind the sidebar's Documents section, so it
//! runs on every sidebar load — hence the `idx_documents_workspace_updated`
//! index from Migration 098.
//!
//! Scoping: `workspace_id` is a path param and lands in the query's
//! `WHERE` clause inside `documents_store.listDocuments`. There is no
//! "all documents" mode, so there is no code path here that can return a
//! row from another workspace.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const documents_store = @import("../agentic_loop/documents_store.zig");

pub const DocumentsListError = error{
    WorkspaceIdRequired,
    QueryFailed,
    OutOfMemory,
};

pub const DocumentsListInput = struct {
    workspace_id: []const u8,
};

pub const DocumentsListOutput = struct {
    /// Owned slice; the caller frees it with
    /// `documents_store.freeDocumentRows`.
    documents: []documents_store.DocumentRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: DocumentsListInput,
) DocumentsListError!DocumentsListOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    return .{ .documents = try documents_store.listDocuments(allocator, db, input.workspace_id) };
}

// =====================================================================
// Handler
// =====================================================================

pub fn documentsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";

    const output = useCase(allocator, sqlite_db, .{ .workspace_id = workspace_id }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.QueryFailed, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.QueryFailed => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer documents_store.freeDocumentRows(allocator, output.documents);

    const data = try http_response.makeDocumentListResponse(allocator, output.documents);
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = pabrikcore.sqlite;
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

    try migration.Migration098CreateDocuments.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty workspace_id returns WorkspaceIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "" }),
    );
}

test "useCase: a workspace with no documents returns an empty list" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer documents_store.freeDocumentRows(alloc, output.documents);
    try testing.expectEqual(@as(usize, 0), output.documents.len);
}

test "useCase: never returns another workspace's documents" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, content) VALUES
        \\  ('doc_a', 'ws_1', 'A', 'body a'),
        \\  ('doc_b', 'ws_2', 'B', 'body b')
    , &.{});

    const mine = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer documents_store.freeDocumentRows(alloc, mine.documents);
    try testing.expectEqual(@as(usize, 1), mine.documents.len);
    try testing.expectEqualStrings("doc_a", mine.documents[0].id);
    try testing.expectEqualStrings("body a", mine.documents[0].content);

    // The foreign workspace sees only its own row — no leak in either
    // direction, and no "empty because mis-scoped" false negative.
    const theirs = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_2" });
    defer documents_store.freeDocumentRows(alloc, theirs.documents);
    try testing.expectEqual(@as(usize, 1), theirs.documents.len);
    try testing.expectEqualStrings("doc_b", theirs.documents[0].id);
}

// ─── Static route contracts for the whole documents group ───────────────
//
// Lives here, in the group's entry-point handler, rather than in a
// standalone `documents_routes_test.zig` — this repo keeps an impl file
// and its tests in ONE file.
//
// `matchRoute` walks routes in REGISTRATION ORDER, so a literal segment
// registered after a `:param` sibling is captured by the param. The
// frontend then gets a 404 and the browser silently renders an empty
// list. That failure is invisible to every useCase test above — the
// useCase is correct, the route table is not — so it is asserted here
// against the route table as text, and a future sibling that shadows
// `documents` fails at `zig build test` instead of in a user's browser.
// The Python functional harness (`tests/functional/harness.py`) covers
// the real wire round-trip; this is the cheap fail-closed guard that
// runs on every commit.

const route_src = @embedFile("../http_routes.zig");

const REQUIRED_ROUTES = [_][]const u8{
    "authed.get(\"/api/workspaces/:workspace_id/documents\"",
    "authed.post(\"/api/workspaces/:workspace_id/documents\"",
    "authed.get(\"/api/workspaces/:workspace_id/documents/:document_id\"",
    "authed.patch(\"/api/workspaces/:workspace_id/documents/:document_id\"",
    "authed.delete(\"/api/workspaces/:workspace_id/documents/:document_id\"",
};

test "documents routes: all five verbs are registered in http_routes.zig" {
    var problems: std.ArrayList([]const u8) = .empty;
    defer problems.deinit(testing.allocator);

    for (REQUIRED_ROUTES) |needle| {
        if (std.mem.indexOf(u8, route_src, needle) == null) {
            problems.append(testing.allocator, needle) catch @panic("OOM");
        }
    }
    if (problems.items.len > 0) {
        for (problems.items) |missing| {
            std.debug.print("missing documents route registration: {s}\n", .{missing});
        }
    }
    try testing.expectEqual(@as(usize, 0), problems.items.len);
}

test "documents routes: the collection routes precede the :document_id routes" {
    // Registration order is the shadowing axis. The two collection routes
    // (list + create) must come first so `matchRoute` never reaches the
    // 4-segment `:document_id` pattern when the path has only 3 segments
    // after `/api/workspaces`. `matchPathWithParams` does require the
    // path to be exhausted, so this is belt-and-braces — but the comment
    // in main.zig claims it, and a claim a test does not check is a claim
    // that rots.
    const list_at = std.mem.indexOf(u8, route_src, "authed.get(\"/api/workspaces/:workspace_id/documents\"") orelse
        return error.ListRouteMissing;
    const detail_at = std.mem.indexOf(u8, route_src, "authed.get(\"/api/workspaces/:workspace_id/documents/:document_id\"") orelse
        return error.DetailRouteMissing;

    try testing.expect(list_at < detail_at);
}

test "documents routes: no GET sibling can capture 'documents' as a :param" {
    // The shadow that matters: a `GET /api/workspaces/:workspace_id/:param`
    // registered BEFORE the documents route would match
    // `GET /api/workspaces/ws_1/documents` with param="documents" and the
    // documents list handler would never run. Today no such route exists —
    // the only literal 4th segment is `POST .../default-project`, a
    // different verb, which cannot collide on GET.
    //
    // Asserted by scanning every `authed.get("/api/workspaces/:workspace_id/`
    // registration and requiring its 4th segment to be a literal, not a
    // `:param`. Add such a route later and this fails.
    var it = std.mem.splitSequence(u8, route_src, "authed.get(\"/api/workspaces/:workspace_id/");
    while (it.next()) |tail| {
        // Grab the path up to the closing quote.
        const end = std.mem.indexOfScalar(u8, tail, '"') orelse continue;
        const path = tail[0..end];
        if (path.len == 0) continue;
        // The documents routes are themselves a 4th segment here; skip
        // them (and the detail routes, which share the prefix).
        if (std.mem.startsWith(u8, path, "documents")) continue;
        if (path[0] == ':') {
            std.debug.print(
                "SHADOW RISK: `GET /api/workspaces/:workspace_id/{s}` would capture " ++
                    "the documents collection as a :param. Register the literal " ++
                    "documents routes BEFORE it, or rename the sibling.\n",
                .{path},
            );
            return error.ParamSiblingShadowsDocuments;
        }
    }
}

test "documents handlers are re-exported from http_handlers/mod.zig" {
    // A handler wired in main.zig but missing from the barrel fails to
    // COMPILE, so this is really a guard against the barrel export being
    // deleted together with its route in one bad refactor.
    const mod_src = @embedFile("mod.zig");
    for ([_][]const u8{
        "documentsListHandler",
        "documentsCreateHandler",
        "documentsGetHandler",
        "documentsUpdateHandler",
        "documentsDeleteHandler",
    }) |name| {
        try testing.expect(std.mem.indexOf(u8, mod_src, name) != null);
    }
}
