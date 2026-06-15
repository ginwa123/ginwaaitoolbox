//! Static regression checks for the memories CRUD HTTP handlers
//! (Chunk 3 of `docs/plans/2026-06-17-add-memories-settings-menu.md`).
//!
//! Why this file exists
//! ────────────────────
//! The four new handlers — `memoryDetailHandler`, `memoryCreateHandler`,
//! `memoryUpdateHandler`, `memoryDeleteHandler` — are thin wrappers
//! over the `readMemoryFile` / `writeMemoryFile` / `deleteMemoryFile`
//! helpers in `src/modules/agent/tools/memories.zig` (added in
//! Chunk 1 of the plan). The helpers themselves have behavioural
//! tests in `src/modules/agent/tools/memories_test.zig`; this file
//! only checks the *wrapper-shape* contracts that the helpers don't
//! cover:
//!
//!   - The handler gets the `environment` from the singleton and
//!     returns 500 when it's missing.
//!   - The handler reads the `:name` URL path parameter and
//!     returns 400 when it's missing.
//!   - The handler calls the right helper with the right arguments
//!     and maps its boolean return into the right HTTP status code.
//!   - The handler uses `std.json.Stringify.valueAlloc` (typed
//!     response struct), NOT hand-rolled `std.fmt.allocPrint` (which
//!     doesn't escape quotes in `content`).
//!   - The handler respects the right HTTP verb semantics:
//!     `200` for GET / PUT / DELETE success, `201` for POST success,
//!     `400` for bad input, `404` for not-found, `409` for duplicate.
//!   - DELETE is idempotent (200 even when the file is already
//!     missing).
//!
//! Why static checks (not behavioural tests)
//! ──────────────────────────────────────────
//! Standing up a full HTTP request/response against a real or in-memory
//! `GinwaServer` requires the `nalarcore` singleton, the Io runtime,
//! the SQLite DB, and a real `*const std.process.Environ.Map`. That's
//! the same problem the existing `routines_run_test.zig` and
//! `task_create_routines_test.zig` solve with static substring
//! checks, and we follow the same pattern. The integration test
//! (live `curl` smoke test in Chunk 10 of the plan) covers the
//! end-to-end behaviour; here we just lock the contract that future
//! refactors must keep.
//!
//! Plan: docs/plans/2026-06-17-add-memories-settings-menu.md (Chunk 3)

const std = @import("std");
const testing = std.testing;

const DETAIL_PATH = "src/ai_workflow/tui/http_handlers/memories_detail.zig";
const CREATE_PATH = "src/ai_workflow/tui/http_handlers/memories_create.zig";
const UPDATE_PATH = "src/ai_workflow/tui/http_handlers/memories_update.zig";
const DELETE_PATH = "src/ai_workflow/tui/http_handlers/memories_delete.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
const MEMORIES_HELPERS_PATH = "src/modules/agent/tools/memories.zig";

/// Read a source file from disk, relative to the project root
/// (the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// =============================================================================
// Shared contract: every handler must acquire the environment from the
// singleton and 500 when it's missing.
// =============================================================================

test "memories_detail handler 500s on missing environment" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DETAIL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "getSingleton") == null) {
        std.debug.print(
            "\n!! {s} does not call getSingleton() !!\n" ++
                "   Without the singleton the handler cannot get the environment\n" ++
                "   and the handler is not a thin wrapper.\n" ++
                "   See docs/plans/2026-06-17-add-memories-settings-menu.md (Chunk 3).\n",
            .{DETAIL_PATH},
        );
        return error.SingletonMissing;
    }
    if (std.mem.indexOf(u8, source, "500") == null) {
        std.debug.print(
            "\n!! {s} does not return a 500 status code !!\n" ++
                "   The missing-environment contract is broken: the handler must\n" ++
                "   return status_code=500 when the environment is not set.\n",
            .{DETAIL_PATH},
        );
        return error.MissingEnvStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "Missing environment") == null) {
        std.debug.print(
            "\n!! {s} does not include the `Missing environment` error !!\n",
            .{DETAIL_PATH},
        );
        return error.MissingEnvMessageMissing;
    }
}

test "memories_create handler 500s on missing environment" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "getSingleton") == null) {
        std.debug.print("\n!! {s} does not call getSingleton() !!\n", .{CREATE_PATH});
        return error.SingletonMissing;
    }
    if (std.mem.indexOf(u8, source, "500") == null) {
        std.debug.print("\n!! {s} does not return 500 on missing env !!\n", .{CREATE_PATH});
        return error.MissingEnvStatusMissing;
    }
}

test "memories_update handler 500s on missing environment" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, UPDATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "getSingleton") == null) {
        std.debug.print("\n!! {s} does not call getSingleton() !!\n", .{UPDATE_PATH});
        return error.SingletonMissing;
    }
    if (std.mem.indexOf(u8, source, "500") == null) {
        std.debug.print("\n!! {s} does not return 500 on missing env !!\n", .{UPDATE_PATH});
        return error.MissingEnvStatusMissing;
    }
}

test "memories_delete handler 500s on missing environment" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "getSingleton") == null) {
        std.debug.print("\n!! {s} does not call getSingleton() !!\n", .{DELETE_PATH});
        return error.SingletonMissing;
    }
    if (std.mem.indexOf(u8, source, "500") == null) {
        std.debug.print("\n!! {s} does not return 500 on missing env !!\n", .{DELETE_PATH});
        return error.MissingEnvStatusMissing;
    }
}

// =============================================================================
// Path-parameter contract: handlers that take `:name` must 400 when it's
// missing.
// =============================================================================

test "memories_detail handler 400s on missing :name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DETAIL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "params.get(\"name\")") == null) {
        std.debug.print(
            "\n!! {s} does not read req.params.get(\"name\") !!\n" ++
                "   The :name path parameter is the only way to identify which\n" ++
                "   memory to load. Without reading it the handler is broken.\n",
            .{DETAIL_PATH},
        );
        return error.PathParamMissing;
    }
    if (std.mem.indexOf(u8, source, "400") == null) {
        std.debug.print(
            "\n!! {s} does not return 400 on missing :name !!\n",
            .{DETAIL_PATH},
        );
        return error.PathParamStatusMissing;
    }
}

test "memories_update handler 400s on missing :name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, UPDATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "params.get(\"name\")") == null) {
        std.debug.print(
            "\n!! {s} does not read req.params.get(\"name\") !!\n",
            .{UPDATE_PATH},
        );
        return error.PathParamMissing;
    }
    if (std.mem.indexOf(u8, source, "400") == null) {
        std.debug.print(
            "\n!! {s} does not return 400 on missing :name !!\n",
            .{UPDATE_PATH},
        );
        return error.PathParamStatusMissing;
    }
}

test "memories_delete handler 400s on missing :name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "params.get(\"name\")") == null) {
        std.debug.print(
            "\n!! {s} does not read req.params.get(\"name\") !!\n",
            .{DELETE_PATH},
        );
        return error.PathParamMissing;
    }
    if (std.mem.indexOf(u8, source, "400") == null) {
        std.debug.print(
            "\n!! {s} does not return 400 on missing :name !!\n",
            .{DELETE_PATH},
        );
        return error.PathParamStatusMissing;
    }
}

// =============================================================================
// Helper-call contract: each handler delegates to the right helper in
// memories.zig with the right argument order. If the call disappears, the
// thin-wrapper shape is gone — restore it.
// =============================================================================

test "memories_detail handler calls readMemoryFile with 4 args" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DETAIL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "readMemoryFile") == null) {
        std.debug.print(
            "\n!! {s} does not call memories.readMemoryFile !!\n" ++
                "   The handler is a thin wrapper: the read path must go through\n" ++
                "   the helper in src/modules/agent/tools/memories.zig.\n" ++
                "   Restore `memories_mod.readMemoryFile(allocator, ctx.io, environment, name)`.\n",
            .{DETAIL_PATH},
        );
        return error.ReadMemoryFileCallMissing;
    }
    // Must also re-list to get title/path/size; the file content alone
    // doesn't carry that metadata.
    if (std.mem.indexOf(u8, source, "listAllMemories") == null) {
        std.debug.print(
            "\n!! {s} does not call listAllMemories !!\n" ++
                "   The detail response must include `title`, `path`, and `size`\n" ++
                "   which require a re-list (readMemoryFile only returns content).\n",
            .{DETAIL_PATH},
        );
        return error.ListAllMemoriesCallMissing;
    }
}

test "memories_create handler calls memoryExists and writeMemoryFile" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "memoryExists") == null) {
        std.debug.print(
            "\n!! {s} does not call memories.memoryExists !!\n" ++
                "   The 409-on-duplicate contract requires the pre-write check.\n" ++
                "   Without it, the create handler would overwrite existing memories.\n",
            .{CREATE_PATH},
        );
        return error.MemoryExistsCallMissing;
    }
    if (std.mem.indexOf(u8, source, "writeMemoryFile") == null) {
        std.debug.print(
            "\n!! {s} does not call memories.writeMemoryFile !!\n",
            .{CREATE_PATH},
        );
        return error.WriteMemoryFileCallMissing;
    }
    // 409 on duplicate.
    if (std.mem.indexOf(u8, source, "409") == null) {
        std.debug.print(
            "\n!! {s} does not return 409 on duplicate !!\n",
            .{CREATE_PATH},
        );
        return error.ConflictStatusMissing;
    }
    // 201 on success (the only POST handler in the CRUD set that
    // creates a new resource).
    if (std.mem.indexOf(u8, source, "201") == null) {
        std.debug.print(
            "\n!! {s} does not return 201 on success !!\n" ++
                "   POST that creates a resource must use 201 Created, not 200.\n",
            .{CREATE_PATH},
        );
        return error.CreatedStatusMissing;
    }
}

test "memories_update handler calls memoryExists before write" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, UPDATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "memoryExists") == null) {
        std.debug.print(
            "\n!! {s} does not call memories.memoryExists !!\n" ++
                "   PUT must 404 on a missing memory, not silently create it.\n",
            .{UPDATE_PATH},
        );
        return error.MemoryExistsCallMissing;
    }
    if (std.mem.indexOf(u8, source, "404") == null) {
        std.debug.print(
            "\n!! {s} does not return 404 on missing memory !!\n",
            .{UPDATE_PATH},
        );
        return error.NotFoundStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "writeMemoryFile") == null) {
        std.debug.print(
            "\n!! {s} does not call memories.writeMemoryFile !!\n",
            .{UPDATE_PATH},
        );
        return error.WriteMemoryFileCallMissing;
    }
}

test "memories_delete handler delegates to deleteMemoryFile" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "deleteMemoryFile") == null) {
        std.debug.print(
            "\n!! {s} does not call memories.deleteMemoryFile !!\n" ++
                "   The delete path must go through the helper (which is the\n" ++
                "   single source of truth for FileNotFound-idempotency).\n",
            .{DELETE_PATH},
        );
        return error.DeleteMemoryFileCallMissing;
    }
    // Idempotent delete: must always return 200 (the helper returns
    // true on both "deleted" and "was already missing").
    if (std.mem.indexOf(u8, source, "200") == null) {
        std.debug.print(
            "\n!! {s} does not return 200 on success !!\n" ++
                "   DELETE must be idempotent: 200 even when the file is missing.\n",
            .{DELETE_PATH},
        );
        return error.SuccessStatusMissing;
    }
}

// =============================================================================
// JSON serialization contract: every response must use valueAlloc, not
// hand-rolled allocPrint. The plan was explicit about this: a memory
// containing a literal `"` would break the hand-rolled approach.
// =============================================================================

test "memories_detail handler uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DETAIL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify.valueAlloc !!\n" ++
                "   The plan's hand-rolled `std.fmt.allocPrint` approach does NOT\n" ++
                "   escape quotes/backslashes in the `content` field. A memory\n" ++
                "   containing `\"` would produce invalid JSON. Use the typed\n" ++
                "   MemoryDetailResponse struct with valueAlloc instead.\n",
            .{DETAIL_PATH},
        );
        return error.ValueAllocMissing;
    }
    // The response struct must carry the `content` field so the
    // typed struct can serialize it.
    if (std.mem.indexOf(u8, source, "content") == null) {
        std.debug.print(
            "\n!! {s} response struct does not carry a `content` field !!\n" ++
                "   The detail response includes the file body, so the typed\n" ++
                "   struct must declare it.\n",
            .{DETAIL_PATH},
        );
        return error.ContentFieldMissing;
    }
}

test "memories_create handler uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify.valueAlloc !!\n",
            .{CREATE_PATH},
        );
        return error.ValueAllocMissing;
    }
}

test "memories_update handler uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, UPDATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify.valueAlloc !!\n",
            .{UPDATE_PATH},
        );
        return error.ValueAllocMissing;
    }
}

test "memories_delete handler uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify.valueAlloc !!\n" ++
                "   The success-and-name response must be produced by valueAlloc\n" ++
                "   to keep escaping consistent with the other CRUD responses.\n",
            .{DELETE_PATH},
        );
        return error.ValueAllocMissing;
    }
}

// =============================================================================
// Validation contract: every handler must call isValidMemoryName before
// touching the filesystem. The helper is the single source of truth for
// what counts as a valid memory name (ends in .md, no /, no ..).
// =============================================================================

test "memories_detail handler validates the :name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DETAIL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "isValidMemoryName") == null) {
        std.debug.print(
            "\n!! {s} does not call isValidMemoryName !!\n" ++
                "   Without validation, a path-traversal payload like `../foo.md`\n" ++
                "   could escape the memories directory. The helper exists\n" ++
                "   precisely for this — use it.\n",
            .{DETAIL_PATH},
        );
        return error.NameValidationMissing;
    }
}

test "memories_create handler validates the name from the body" {
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

test "memories_update handler validates the :name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, UPDATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "isValidMemoryName") == null) {
        std.debug.print(
            "\n!! {s} does not call isValidMemoryName !!\n",
            .{UPDATE_PATH},
        );
        return error.NameValidationMissing;
    }
}

test "memories_delete handler validates the :name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "isValidMemoryName") == null) {
        std.debug.print(
            "\n!! {s} does not call isValidMemoryName !!\n",
            .{DELETE_PATH},
        );
        return error.NameValidationMissing;
    }
}

// =============================================================================
// Body-parsing contract: create/update must read the request body and
// reject bad JSON with 400. parseFromSliceLeaky (not parseFromSlice) is
// the right call for per-request arena allocators — see
// src/ai_workflow/tui/http_handlers/task_create.zig for the precedent.
// =============================================================================

test "memories_create handler parses JSON body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The per-request allocator is an arena; parseFromSlice\n" ++
                "   creates its own internal arena that requires an explicit\n" ++
                "   deinit, which is wrong for this codebase. The Leaky variant\n" ++
                "   lets the per-request arena own the parsed value's allocations.\n" ++
                "   See task_create.zig:44 for the precedent.\n",
            .{CREATE_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
    if (std.mem.indexOf(u8, source, "Invalid JSON body") == null) {
        std.debug.print(
            "\n!! {s} does not return 400 on bad JSON !!\n",
            .{CREATE_PATH},
        );
        return error.BadJsonStatusMissing;
    }
}

test "memories_update handler parses JSON body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, UPDATE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The per-request allocator is an arena; parseFromSlice creates\n" ++
                "   its own internal arena that requires explicit deinit. Use the\n" ++
                "   Leaky variant. See task_create.zig:44 for the precedent.\n",
            .{UPDATE_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
    if (std.mem.indexOf(u8, source, "Invalid JSON body") == null) {
        std.debug.print(
            "\n!! {s} does not return 400 on bad JSON !!\n",
            .{UPDATE_PATH},
        );
        return error.BadJsonStatusMissing;
    }
}

// =============================================================================
// Re-export and route-registration contracts: the new handlers must be
// exported from mod.zig AND registered in main.zig. If either side is
// missing, the server compiles but the routes return 404.
// =============================================================================

test "memories_crud handlers are re-exported from http_handlers/mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    const expected = [_][]const u8{
        "memoryDetailHandler",
        "memoryCreateHandler",
        "memoryUpdateHandler",
        "memoryDeleteHandler",
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

test "memories_crud routes are registered in main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    const expected = [_][]const u8{
        "memoryDetailHandler",
        "memoryCreateHandler",
        "memoryUpdateHandler",
        "memoryDeleteHandler",
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

    // The 4 expected routes.
    const routes = [_][]const u8{
        "gs.router.get(\"/api/memories/:name\"",
        "gs.router.post(\"/api/memories\"",
        "gs.router.put(\"/api/memories/:name\"",
        "gs.router.delete(\"/api/memories/:name\"",
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
// Helper-availability contract: the helpers used by the handlers must
// remain pub in memories.zig. This catches a future refactor that
// accidentally tightens the visibility (e.g. changing `pub fn` to
// `fn`) and breaks all four handlers at once.
// =============================================================================

test "memories.zig keeps the helpers pub" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MEMORIES_HELPERS_PATH);
    defer allocator.free(source);

    const expected = [_][]const u8{
        "pub fn readMemoryFile",
        "pub fn writeMemoryFile",
        "pub fn deleteMemoryFile",
        "pub fn memoryExists",
        "pub fn isValidMemoryName",
        "pub fn listAllMemories",
        "pub fn freeMemoriesList",
    };
    for (expected) |name| {
        if (std.mem.indexOf(u8, source, name) == null) {
            std.debug.print(
                "\n!! {s} does not contain `{s}` !!\n" ++
                    "   The four CRUD handlers depend on this helper being public.\n" ++
                    "   Re-add the `pub` modifier.\n",
                .{ MEMORIES_HELPERS_PATH, name },
            );
            return error.HelperNotPub;
        }
    }
}
