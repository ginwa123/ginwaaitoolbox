//! `GET /api/local-memories?cwd=...` — list `.md` memory files in
//! `<cwd>/.nalar/memories/`. The `cwd` query param is optional —
//! when omitted, the handler falls back to the nalar server's own
//! CWD via `io.realPath`.
//!
//! Returns JSON: `{"memories":[{"name":"...","title":"...","path":"...","size":N}]}`
//! Empty list when the directory does not exist or has no .md files.
//!
//! Layered as:
//!   - `useCase` — resolves the local memories dir (query `cwd`
//!     first, then io fallback) and produces the memories-list JSON.
//!   - `localMemoriesListHandler` — thin orchestrator: extracts the
//!     `?cwd=` query, calls `useCase`, maps errors to status codes,
//!     builds the JSON response.
//!
//! Preserves the static-contract assertions in `local_memories_crud_test.zig`:
//!   - `get_local_memories_path_for_dir` + `get_local_memories_path_from_io`
//!     substring checks (cwd-resolution fallback chain)
//!   - `req.query.get("cwd")` substring check (per-call cwd override)
//!   - `500` + `no cwd available` substring checks

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const list_memory_mod = nalarcore.list_memory_tool;
const http_response = @import("http_response.zig");

/// Domain-level error set for `useCase`. The only failure mode is
/// "could not resolve the local memories directory" — both the query
/// `cwd` and the io fallback returned null/empty.
pub const LocalMemoriesListError = error{
    /// Neither the per-request `cwd` query nor the io fallback
    /// yielded a usable local-memories directory.
    NoCwdAvailable,
    /// `list_memory_mod.toJson` returned `error.OutOfMemory`. Maps to 500.
    /// In production this is effectively unreachable (the
    /// per-request arena reaps everything at request end) but the
    /// type system requires the variant so the `try` on the call
    /// propagates a typed error.
    OutOfMemory,
};

/// Inputs to the list use-case.
pub const LocalMemoriesListInput = struct {
    /// The `?cwd=` query value (may be null/empty — the use-case
    /// will fall back to the io CWD in that case).
    cwd: []const u8,
};

/// Output of the list use-case: the heap-owned JSON body to return
/// to the caller. Borrowed `dir_path` is freed by the use-case's
/// internal defer; the JSON body lives until the per-request arena
/// reaps at request end.
pub const LocalMemoriesListOutput = struct {
    json_body: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Resolve the local memories dir and produce the list JSON.
///
/// Steps:
///   1. Prefer `get_local_memories_path_for_dir(allocator, cwd)`
///      when `input.cwd` is non-empty.
///   2. Fall back to `get_local_memories_path_from_io(allocator, io)`.
///   3. Both null → `NoCwdAvailable`.
///   4. List via `listMemoriesInDir` and serialize to JSON.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: LocalMemoriesListInput,
) LocalMemoriesListError!LocalMemoriesListOutput {
    var dir_path_alloc: ?[]const u8 = null;
    if (input.cwd.len > 0) {
        dir_path_alloc = memories_mod.get_local_memories_path_for_dir(allocator, input.cwd);
    }
    if (dir_path_alloc == null) {
        dir_path_alloc = memories_mod.get_local_memories_path_from_io(allocator, io);
    }
    const dir_path = dir_path_alloc orelse return error.NoCwdAvailable;
    defer allocator.free(dir_path);

    const list = memories_mod.listMemoriesInDir(allocator, io, dir_path);
    defer memories_mod.freeMemoriesList(allocator, list);

    const json_body = try list_memory_mod.toJson(allocator, list);
    return .{ .json_body = json_body };
}

// =====================================================================
// Handler
// =====================================================================

pub fn localMemoriesListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const cwd_raw = req.query.get("cwd") orelse "";
    const outcome = useCase(allocator, ctx.io, .{ .cwd = cwd_raw }) catch |err| {
        const status: u16 = switch (err) {
            error.NoCwdAvailable => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.NoCwdAvailable => "Could not resolve local memories directory (no cwd available)",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = outcome.json_body });
}

// ===== Tests merged from local_memories_crud_test.zig (2026-09-11 flatten) =====
// Static regression checks for the LOCAL memories CRUD HTTP handlers.
// 
// Why this file exists
// ────────────────────
// The five new handlers — `localMemoriesListHandler`,
// `localMemoryDetailHandler`, `localMemoryCreateHandler`,
// `localMemoryUpdateHandler`, `localMemoryDeleteHandler` — are
// thin wrappers over the local-memory helpers added in
// `src/modules/agent/tools/memories.zig`. The helpers themselves
// have behavioural tests in `src/modules/agent/tools/memories_test.zig`;
// this file only checks the *wrapper-shape* contracts that the
// helpers don't cover:
// 
//   - The handler resolves the local memories directory from the
//     request (body `cwd` for POST/PUT, query `cwd` for GET/DELETE),
//     falling back to the nalar server's CWD via `io.realPath`.
//   - 500 is returned when the local directory cannot be resolved
//     (no cwd available from the request and from `io`).
//   - POST uses `parseFromSliceLeaky` (not `parseFromSlice`)
//     because the per-request allocator is an arena.
//   - PUT reads the `:name` URL path parameter and 400s when missing.
//   - DELETE 400s on bad name and is idempotent (200 even when the
//     file is already missing).
//   - All five handlers are re-exported from `http_handlers/mod.zig`
//     and registered in `main.zig` (a missing re-export or route
//     registration makes the API silently 404 at runtime).
// 
// Why static checks (not behavioural tests)
// ──────────────────────────────────────────
// Standing up a full HTTP request/response against a real or
// in-memory `GinwaServer` requires the `nalarcore` singleton, the
// Io runtime, the SQLite DB, and a real `*const std.process.Environ.Map`.
// We use the same source-substring pattern as `memories_crud_test.zig`,
// `routines_run_test.zig`, and `task_create_routines_test.zig` for
// consistency with the rest of the test suite.
// 
// Plan: docs/plans/2026-06-20-add-markdown-memory.md

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const LIST_PATH = "src/http_handlers/local_memories_list.zig";
const DETAIL_PATH = "src/http_handlers/local_memories_detail.zig";
const CREATE_PATH = "src/http_handlers/local_memories_create.zig";
const UPDATE_PATH = "src/http_handlers/local_memories_update.zig";
const DELETE_PATH = "src/http_handlers/local_memories_delete.zig";
const MOD_PATH = "src/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
const MEMORIES_HELPERS_PATH = "src/modules/agent/tools/memories.zig";

/// Read a source file from disk, relative to the project root
/// (the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// =============================================================================
// Cwd-resolution contract: every handler must resolve the local directory
// via `get_local_memories_path_for_dir` (body/query) with a fallback to
// `get_local_memories_path_from_io` (io). Missing both paths → 500.
// =============================================================================

test "local_memories_list resolves cwd from query or io" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LIST_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "get_local_memories_path_for_dir") == null) {
        std.debug.print(
            "\n!! {s} does not call get_local_memories_path_for_dir !!\n" ++
                "   The list handler must resolve the local memories dir from the\n" ++
                "   query (?cwd=...) or fall back to the nalar server's CWD.\n",
            .{LIST_PATH},
        );
        return error.QueryCwdResolverMissing;
    }
    if (std.mem.indexOf(u8, source, "get_local_memories_path_from_io") == null) {
        std.debug.print(
            "\n!! {s} does not call get_local_memories_path_from_io !!\n" ++
                "   Without the io fallback the handler cannot find the local\n" ++
                "   memories dir when no explicit cwd is provided.\n",
            .{LIST_PATH},
        );
        return error.IoCwdFallbackMissing;
    }
    if (std.mem.indexOf(u8, source, "req.query.get(\"cwd\")") == null) {
        std.debug.print(
            "\n!! {s} does not read req.query.get(\"cwd\") !!\n" ++
                "   The list handler must accept ?cwd=... to scope the listing\n" ++
                "   to a specific project directory.\n",
            .{LIST_PATH},
        );
        return error.QueryCwdParamMissing;
    }
}

test "local_memories handlers return 500 when no cwd is available" {
    const allocator = testing.allocator;
    const paths = [_][]const u8{ LIST_PATH, DETAIL_PATH, CREATE_PATH, UPDATE_PATH, DELETE_PATH };
    for (paths) |p| {
        const source = try readSource(allocator, p);
        defer allocator.free(source);
        if (std.mem.indexOf(u8, source, "500") == null) {
            std.debug.print(
                "\n!! {s} does not return 500 on missing cwd !!\n" ++
                    "   The 'no cwd available' branch is a server-side condition;\n" ++
                    "   500 is the correct status code.\n",
                .{p},
            );
            return error.MissingCwdStatusMissing;
        }
        if (std.mem.indexOf(u8, source, "no cwd available") == null) {
            std.debug.print(
                "\n!! {s} does not include the `no cwd available` error message !!\n",
                .{p},
            );
            return error.MissingCwdMessageMissing;
        }
    }
}

// =============================================================================
// Helper-call contract: each handler delegates to the right local-memory
// helper in memories.zig. If any call disappears, the thin-wrapper
// shape is gone — restore it.
// =============================================================================

test "local_memories_crud handlers are re-exported from http_handlers/mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    const expected = [_][]const u8{
        "localMemoriesListHandler",
        "localMemoryDetailHandler",
        "localMemoryCreateHandler",
        "localMemoryUpdateHandler",
        "localMemoryDeleteHandler",
    };
    for (expected) |name| {
        if (std.mem.indexOf(u8, source, name) == null) {
            std.debug.print(
                "\n!! {s} does not re-export `{s}` !!\n" ++
                    "   Without the re-export, main.zig cannot import the handler\n" ++
                    "   and the corresponding route returns 404 at runtime.\n",
                .{ MOD_PATH, name },
            );
            return error.ReExportMissing;
        }
    }
}

test "local_memories_crud routes are registered in main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    const expected = [_][]const u8{
        "localMemoriesListHandler",
        "localMemoryDetailHandler",
        "localMemoryCreateHandler",
        "localMemoryUpdateHandler",
        "localMemoryDeleteHandler",
    };
    for (expected) |name| {
        if (std.mem.indexOf(u8, source, name) == null) {
            std.debug.print(
                "\n!! {s} does not reference `{s}` !!\n" ++
                    "   The handler exists in mod.zig but is not registered with\n" ++
                    "   the router. Add the `authed.{{get,post,put,delete}}` call.\n",
                .{ MAIN_PATH, name },
            );
            return error.RouteRegistrationMissing;
        }
    }

    // The 5 expected routes.
    const routes = [_][]const u8{
        "authed.get(\"/api/local-memories\"",
        "authed.get(\"/api/local-memories/:name\"",
        "authed.post(\"/api/local-memories\"",
        "authed.put(\"/api/local-memories/:name\"",
        "authed.delete(\"/api/local-memories/:name\"",
    };
    for (routes) |route| {
        if (std.mem.indexOf(u8, source, route) == null) {
            std.debug.print(
                "\n!! {s} does not register the route `{s}` !!\n",
                .{ MAIN_PATH, route },
            );
            return error.RouteMissing;
        }
    }
}

// =============================================================================
// Helper-availability contract: the local-memory helpers used by the
// handlers must remain `pub` in memories.zig. This catches a future
// refactor that accidentally tightens the visibility and breaks all
// five local-memory handlers at once.
// =============================================================================

test "memories.zig keeps the local-memory helpers pub" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MEMORIES_HELPERS_PATH);
    defer allocator.free(source);

    const expected = [_][]const u8{
        "pub fn get_local_memories_path_from_io",
        "pub fn get_local_memory_file_path",
        "pub fn readLocalMemoryFile",
        "pub fn writeLocalMemoryFile",
        "pub fn deleteLocalMemoryFile",
        "pub fn localMemoryExists",
    };
    for (expected) |name| {
        if (std.mem.indexOf(u8, source, name) == null) {
            std.debug.print(
                "\n!! {s} does not contain `{s}` !!\n" ++
                    "   The five local-memory handlers depend on this helper being public.\n" ++
                    "   Re-add the `pub` modifier.\n",
                .{ MEMORIES_HELPERS_PATH, name },
            );
            return error.HelperNotPub;
        }
    }
}
