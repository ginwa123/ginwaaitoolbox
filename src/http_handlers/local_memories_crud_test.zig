//! Static regression checks for the LOCAL memories CRUD HTTP handlers.
//!
//! Why this file exists
//! ────────────────────
//! The five new handlers — `localMemoriesListHandler`,
//! `localMemoryDetailHandler`, `localMemoryCreateHandler`,
//! `localMemoryUpdateHandler`, `localMemoryDeleteHandler` — are
//! thin wrappers over the local-memory helpers added in
//! `src/modules/agent/tools/memories.zig`. The helpers themselves
//! have behavioural tests in `src/modules/agent/tools/memories_test.zig`;
//! this file only checks the *wrapper-shape* contracts that the
//! helpers don't cover:
//!
//!   - The handler resolves the local memories directory from the
//!     request (body `cwd` for POST/PUT, query `cwd` for GET/DELETE),
//!     falling back to the nalar server's CWD via `io.realPath`.
//!   - 500 is returned when the local directory cannot be resolved
//!     (no cwd available from the request and from `io`).
//!   - POST uses `parseFromSliceLeaky` (not `parseFromSlice`)
//!     because the per-request allocator is an arena.
//!   - PUT reads the `:name` URL path parameter and 400s when missing.
//!   - DELETE 400s on bad name and is idempotent (200 even when the
//!     file is already missing).
//!   - All five handlers are re-exported from `http_handlers/mod.zig`
//!     and registered in `main.zig` (a missing re-export or route
//!     registration makes the API silently 404 at runtime).
//!
//! Why static checks (not behavioural tests)
//! ──────────────────────────────────────────
//! Standing up a full HTTP request/response against a real or
//! in-memory `GinwaServer` requires the `nalarcore` singleton, the
//! Io runtime, the SQLite DB, and a real `*const std.process.Environ.Map`.
//! We use the same source-substring pattern as `memories_crud_test.zig`,
//! `routines_run_test.zig`, and `task_create_routines_test.zig` for
//! consistency with the rest of the test suite.
//!
//! Plan: docs/plans/2026-06-20-add-markdown-memory.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
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

test "local_memories_detail resolves cwd from query or io" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DETAIL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "get_local_memories_path_for_dir") == null) {
        std.debug.print("\n!! {s} does not call get_local_memories_path_for_dir !!\n", .{DETAIL_PATH});
        return error.QueryCwdResolverMissing;
    }
    if (std.mem.indexOf(u8, source, "get_local_memories_path_from_io") == null) {
        std.debug.print("\n!! {s} does not call get_local_memories_path_from_io !!\n", .{DETAIL_PATH});
        return error.IoCwdFallbackMissing;
    }
    if (std.mem.indexOf(u8, source, "params.get(\"name\")") == null) {
        std.debug.print(
            "\n!! {s} does not read req.params.get(\"name\") !!\n" ++
                "   The :name path parameter is the only way to identify which\n" ++
                "   local memory to load.\n",
            .{DETAIL_PATH},
        );
        return error.PathParamMissing;
    }
}

test "local_memories_create resolves cwd from body or io" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "get_local_memories_path_for_dir") == null) {
        std.debug.print("\n!! {s} does not call get_local_memories_path_for_dir !!\n", .{CREATE_PATH});
        return error.BodyCwdResolverMissing;
    }
    if (std.mem.indexOf(u8, source, "get_local_memories_path_from_io") == null) {
        std.debug.print("\n!! {s} does not call get_local_memories_path_from_io !!\n", .{CREATE_PATH});
        return error.IoCwdFallbackMissing;
    }
    if (std.mem.indexOf(u8, source, "parsed.cwd") == null) {
        std.debug.print(
            "\n!! {s} does not read parsed.cwd from the body !!\n" ++
                "   The create handler must accept a 'cwd' field in the JSON body.\n",
            .{CREATE_PATH},
        );
        return error.BodyCwdParamMissing;
    }
}

test "local_memories_update resolves cwd from body or io" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, UPDATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "get_local_memories_path_for_dir") == null) {
        std.debug.print("\n!! {s} does not call get_local_memories_path_for_dir !!\n", .{UPDATE_PATH});
        return error.BodyCwdResolverMissing;
    }
    if (std.mem.indexOf(u8, source, "get_local_memories_path_from_io") == null) {
        std.debug.print("\n!! {s} does not call get_local_memories_path_from_io !!\n", .{UPDATE_PATH});
        return error.IoCwdFallbackMissing;
    }
    if (std.mem.indexOf(u8, source, "parsed.cwd") == null) {
        std.debug.print(
            "\n!! {s} does not read parsed.cwd from the body !!\n",
            .{UPDATE_PATH},
        );
        return error.BodyCwdParamMissing;
    }
    if (std.mem.indexOf(u8, source, "params.get(\"name\")") == null) {
        std.debug.print("\n!! {s} does not read req.params.get(\"name\") !!\n", .{UPDATE_PATH});
        return error.PathParamMissing;
    }
}

test "local_memories_delete resolves cwd from query or io" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "get_local_memories_path_for_dir") == null) {
        std.debug.print("\n!! {s} does not call get_local_memories_path_for_dir !!\n", .{DELETE_PATH});
        return error.QueryCwdResolverMissing;
    }
    if (std.mem.indexOf(u8, source, "get_local_memories_path_from_io") == null) {
        std.debug.print("\n!! {s} does not call get_local_memories_path_from_io !!\n", .{DELETE_PATH});
        return error.IoCwdFallbackMissing;
    }
    if (std.mem.indexOf(u8, source, "params.get(\"name\")") == null) {
        std.debug.print("\n!! {s} does not read req.params.get(\"name\") !!\n", .{DELETE_PATH});
        return error.PathParamMissing;
    }
}

// =============================================================================
// 500 contract: when both the request cwd and the io fallback fail, the
// handlers must return 500 with a recognizable error string.
// =============================================================================

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

test "local_memories_create calls localMemoryExists and writeLocalMemoryFile" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "localMemoryExists") == null) {
        std.debug.print(
            "\n!! {s} does not call memories.localMemoryExists !!\n" ++
                "   The 409-on-duplicate contract requires the pre-write check.\n",
            .{CREATE_PATH},
        );
        return error.LocalMemoryExistsCallMissing;
    }
    if (std.mem.indexOf(u8, source, "writeLocalMemoryFile") == null) {
        std.debug.print("\n!! {s} does not call memories.writeLocalMemoryFile !!\n", .{CREATE_PATH});
        return error.WriteLocalMemoryFileCallMissing;
    }
    if (std.mem.indexOf(u8, source, "409") == null) {
        std.debug.print("\n!! {s} does not return 409 on duplicate !!\n", .{CREATE_PATH});
        return error.ConflictStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "201") == null) {
        std.debug.print(
            "\n!! {s} does not return 201 on success !!\n" ++
                "   POST that creates a resource must use 201 Created.\n",
            .{CREATE_PATH},
        );
        return error.CreatedStatusMissing;
    }
}

test "local_memories_update calls localMemoryExists before write" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, UPDATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "localMemoryExists") == null) {
        std.debug.print(
            "\n!! {s} does not call memories.localMemoryExists !!\n" ++
                "   PUT must 404 on a missing local memory, not silently create it.\n",
            .{UPDATE_PATH},
        );
        return error.LocalMemoryExistsCallMissing;
    }
    if (std.mem.indexOf(u8, source, "404") == null) {
        std.debug.print("\n!! {s} does not return 404 on missing local memory !!\n", .{UPDATE_PATH});
        return error.NotFoundStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "writeLocalMemoryFile") == null) {
        std.debug.print("\n!! {s} does not call memories.writeLocalMemoryFile !!\n", .{UPDATE_PATH});
        return error.WriteLocalMemoryFileCallMissing;
    }
}

test "local_memories_delete delegates to deleteLocalMemoryFile" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "deleteLocalMemoryFile") == null) {
        std.debug.print(
            "\n!! {s} does not call memories.deleteLocalMemoryFile !!\n" ++
                "   The delete path must go through the helper (which is the\n" ++
                "   single source of truth for FileNotFound-idempotency).\n",
            .{DELETE_PATH},
        );
        return error.DeleteLocalMemoryFileCallMissing;
    }
    if (std.mem.indexOf(u8, source, "200") == null) {
        std.debug.print(
            "\n!! {s} does not return 200 on success !!\n" ++
                "   DELETE must be idempotent: 200 even when the file is missing.\n",
            .{DELETE_PATH},
        );
        return error.SuccessStatusMissing;
    }
}

test "local_memories_detail calls readLocalMemoryFile and listMemoriesInDir" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DETAIL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "readLocalMemoryFile") == null) {
        std.debug.print("\n!! {s} does not call memories.readLocalMemoryFile !!\n", .{DETAIL_PATH});
        return error.ReadLocalMemoryFileCallMissing;
    }
    if (std.mem.indexOf(u8, source, "listMemoriesInDir") == null) {
        std.debug.print(
            "\n!! {s} does not call listMemoriesInDir !!\n" ++
                "   The detail response must include `title`, `path`, and `size`\n" ++
                "   which require a re-list (readLocalMemoryFile only returns content).\n",
            .{DETAIL_PATH},
        );
        return error.ListMemoriesInDirCallMissing;
    }
    if (std.mem.indexOf(u8, source, "404") == null) {
        std.debug.print("\n!! {s} does not return 404 on missing local memory !!\n", .{DETAIL_PATH});
        return error.NotFoundStatusMissing;
    }
}

// =============================================================================
// JSON serialization contract: every response must use valueAlloc, not
// hand-rolled allocPrint (the `content` field in detail responses
// contains user-provided markdown — quotes/backslashes must be escaped).
// =============================================================================

test "local_memories_detail uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DETAIL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify.valueAlloc !!\n" ++
                "   The detail response carries the file body; quotes must be\n" ++
                "   escaped by the JSON serializer, not by hand.\n",
            .{DETAIL_PATH},
        );
        return error.ValueAllocMissing;
    }
    if (std.mem.indexOf(u8, source, "content") == null) {
        std.debug.print(
            "\n!! {s} response struct does not carry a `content` field !!\n",
            .{DETAIL_PATH},
        );
        return error.ContentFieldMissing;
    }
}

test "local_memories_create uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print("\n!! {s} does not use std.json.Stringify.valueAlloc !!\n", .{CREATE_PATH});
        return error.ValueAllocMissing;
    }
}

test "local_memories_update uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, UPDATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print("\n!! {s} does not use std.json.Stringify.valueAlloc !!\n", .{UPDATE_PATH});
        return error.ValueAllocMissing;
    }
}

test "local_memories_delete uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print("\n!! {s} does not use std.json.Stringify.valueAlloc !!\n", .{DELETE_PATH});
        return error.ValueAllocMissing;
    }
}

// =============================================================================
// Validation contract: every handler that takes `:name` must call
// isValidMemoryName before touching the filesystem. The helper is the
// single source of truth for what counts as a valid memory name (ends
// in .md, no /, no ..).
// =============================================================================

test "local_memories_detail validates the :name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DETAIL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "isValidMemoryName") == null) {
        std.debug.print("\n!! {s} does not call isValidMemoryName !!\n", .{DETAIL_PATH});
        return error.NameValidationMissing;
    }
}

test "local_memories_update validates the :name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, UPDATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "isValidMemoryName") == null) {
        std.debug.print("\n!! {s} does not call isValidMemoryName !!\n", .{UPDATE_PATH});
        return error.NameValidationMissing;
    }
}

test "local_memories_delete validates the :name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "isValidMemoryName") == null) {
        std.debug.print("\n!! {s} does not call isValidMemoryName !!\n", .{DELETE_PATH});
        return error.NameValidationMissing;
    }
}

test "local_memories_create validates the name from the body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "isValidMemoryName") == null) {
        std.debug.print(
            "\n!! {s} does not call isValidMemoryName !!\n" ++
                "   The name from the POST body must be validated to prevent\n" ++
                "   `../escape.md` style attacks.\n",
            .{CREATE_PATH},
        );
        return error.NameValidationMissing;
    }
}

// =============================================================================
// Body-parsing contract: create/update must read the request body and
// reject bad JSON with 400. parseFromSliceLeaky (not parseFromSlice) is
// the right call for per-request arena allocators — see
// src/http_handlers/task_create.zig for the precedent.
// =============================================================================

test "local_memories_create parses JSON body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The per-request allocator is an arena; parseFromSlice creates\n" ++
                "   its own internal arena that needs explicit deinit. Use the Leaky\n" ++
                "   variant — see task_create.zig:44 for the precedent.\n",
            .{CREATE_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
    if (std.mem.indexOf(u8, source, "Invalid JSON body") == null) {
        std.debug.print("\n!! {s} does not return 400 on bad JSON !!\n", .{CREATE_PATH});
        return error.BadJsonStatusMissing;
    }
}

test "local_memories_update parses JSON body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, UPDATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("\n!! {s} does not use parseFromSliceLeaky !!\n", .{UPDATE_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
    if (std.mem.indexOf(u8, source, "Invalid JSON body") == null) {
        std.debug.print("\n!! {s} does not return 400 on bad JSON !!\n", .{UPDATE_PATH});
        return error.BadJsonStatusMissing;
    }
}

// =============================================================================
// Re-export and route-registration contracts: the new handlers must be
// exported from mod.zig AND registered in main.zig. If either side is
// missing, the server compiles but the routes return 404.
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
                    "   the router. Add the `gs.router.{{get,post,put,delete}}` call.\n",
                .{ MAIN_PATH, name },
            );
            return error.RouteRegistrationMissing;
        }
    }

    // The 5 expected routes.
    const routes = [_][]const u8{
        "gs.router.get(\"/api/local-memories\"",
        "gs.router.get(\"/api/local-memories/:name\"",
        "gs.router.post(\"/api/local-memories\"",
        "gs.router.put(\"/api/local-memories/:name\"",
        "gs.router.delete(\"/api/local-memories/:name\"",
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
