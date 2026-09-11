//! `GET /api/memories` — list all global memory files (markdown) in
//! `$XDG_CONFIG_HOME/nalar/memories/` or `~/.config/nalar/memories/`.
//!
//! Returns JSON: `{"memories":[{"name":"...","title":"...","path":"...","size":N}]}`
//! Empty list when no memories exist or the folder is missing — never throws.
//!
//! Layered as:
//!   - `useCase` — resolves the singleton, looks up the environment,
//!     and lists the memories.
//!   - `memoriesListHandler` — thin orchestrator: delegates to `useCase`,
//!     maps errors to status codes, builds the JSON response.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const list_memory_mod = nalarcore.list_memory_tool;
const http_response = @import("http_response.zig");

/// Domain-level error set for `useCase`. The `getSingleton` call may
/// fail when the singleton has not been initialised yet, and the
/// environment may legitimately be missing on a server without a
/// config dir.
pub const MemoriesListError = error{
    /// `nalarcore.getSingleton()` failed (server has not been
    /// initialised yet). Maps to 500.
    ServerNotInitialized,
    /// The singleton has no `*const std.process.Environ.Map` (the
    /// server was constructed without an env). Maps to 500 with the
    /// "Missing environment" message preserved for the static contract.
    MissingEnvironment,
    /// `list_memory_mod.toJson` returned `error.OutOfMemory`. Maps to 500.
    /// In production this is effectively unreachable (the
    /// per-request arena reaps everything at request end) but the
    /// type system requires the variant so the `try` on the call
    /// propagates a typed error.
    OutOfMemory,
};

/// Inputs to the list-memories use-case. Currently empty — the
/// endpoint takes no path params / body — kept as a struct for
/// forward compatibility (e.g. adding `?cwd=...` filtering later).
pub const MemoriesListInput = struct {};

/// Output of the list-memories use-case: the allocated JSON body to
/// return to the caller, plus the borrowed memory-list backing (the
/// caller does NOT free either — both live in the per-request arena).
pub const MemoriesListOutput = struct {
    json_body: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Resolve the environment and produce the memories list JSON.
///
/// Steps:
///   1. Get the singleton (catches 500 on a server not yet ready).
///   2. Read its environment (catches 500 on missing env).
///   3. List memories and serialize to JSON.
///   4. Return the heap-owned JSON body for the handler to wrap in
///      a 200 response.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: MemoriesListInput,
) MemoriesListError!MemoriesListOutput {
    _ = input;

    const di = nalarcore.getSingleton() catch return error.ServerNotInitialized;
    const environment = di.environment orelse return error.MissingEnvironment;

    const list = memories_mod.listAllMemories(allocator, io, environment);
    defer memories_mod.freeMemoriesList(allocator, list);

    const json_body = try list_memory_mod.toJson(allocator, list);
    return .{ .json_body = json_body };
}

// =====================================================================
// Handler
// =====================================================================

pub fn memoriesListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;

    const outcome = useCase(allocator, ctx.io, .{}) catch |err| {
        // Both switches are exhaustive over the inferred error set —
        // adding a new `MemoriesListError` variant will fail to
        // compile here (intentional, to keep status codes in sync).
        // No `else` prong needed.
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.MissingEnvironment => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.MissingEnvironment => "Missing environment",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = outcome.json_body });
}

// ===== Tests merged from memories_crud_test.zig (2026-09-11 flatten) =====
const text_normalize = @import("helpers").text_normalize;
const testing = std.testing;

const MOD_PATH = "src/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
const MEMORIES_HELPERS_PATH = "src/modules/agent/tools/memories.zig";

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
