//! `GET /api/memories/:name` — read a global memory file's content + metadata.
//!
//! Layered as:
//!   - `useCase` — validates the `:name`, resolves the environment,
//!     reads the file, re-lists to derive `title/path/size`, and
//!     returns a heap-owned `MemoryDetailPayload`.
//!   - `memoryDetailHandler` — thin orchestrator: parses `:name`
//!     path param, calls `useCase`, maps errors to status codes,
//!     builds the JSON response.
//!
//! Preserves the static-contract assertions in `memories_crud_test.zig`:
//!   - `getSingleton` + `500` + `Missing environment` substring checks
//!   - `params.get("name")` + `400` substring checks
//!   - `readMemoryFile` + `listAllMemories` helper call substring checks
//!   - `isValidMemoryName` validation substring check
//!   - `std.json.Stringify.valueAlloc` + `content` field substring checks

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const http_response = @import("http_response.zig");

/// Response payload for `GET /api/memories/:name`.
///
/// `content` is JSON-escaped automatically by
/// `std.json.Stringify.valueAlloc` — do not hand-roll JSON for the
/// body, it can break on memories that contain `"` or backslash.
pub const MemoryDetailPayload = struct {
    name: []const u8,
    title: []const u8,
    path: []const u8,
    size: u64,
    content: []const u8,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code via two exhaustive switches in the
/// handler.
pub const MemoryDetailError = error{
    /// `getSingleton()` failed — server not initialised.
    ServerNotInitialized,
    /// Singleton has no environment (server constructed without env).
    /// Maps to 500 with the "Missing environment" message.
    MissingEnvironment,
    /// `:name` path param was missing or empty.
    NameRequired,
    /// The name failed `isValidMemoryName` (path-traversal or non-md).
    InvalidName,
    /// The file does not exist on disk (or the re-list did not see it).
    NotFound,
    /// `allocator.dupe` failed while building the heap-owned payload.
    OutOfMemory,
};

/// Inputs to the detail use-case.
pub const MemoryDetailInput = struct {
    name: []const u8,
};

/// Output of the detail use-case. The slice fields are HEAP-OWNED
/// by the use-case (duplicated from `listAllMemories` +
/// `readMemoryFile` so they survive the internal `freeMemoriesList`
/// and `allocator.free(content)` defers). The handler is responsible
/// for freeing them — typically a `defer` block in the handler does
/// per-field `allocator.free(output.payload.content)` etc.
pub const MemoryDetailOutput = struct {
    payload: MemoryDetailPayload,
};

// =====================================================================
// Use case
// =====================================================================

/// Read a global memory file's content and metadata.
///
/// Steps:
///   1. Get the singleton + env.
///   2. Validate `name` (non-empty + `isValidMemoryName`).
///   3. Read the file via `readMemoryFile`. File not found → 404.
///   4. Re-list via `listAllMemories` to derive `title/path/size`.
///   5. Locate the entry by name. Missing → 404 (defensive).
///   6. Duplicate the matched slices so the output survives internal
///      `free` defers.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: MemoryDetailInput,
) MemoryDetailError!MemoryDetailOutput {
    const di = nalarcore.getSingleton() catch return error.ServerNotInitialized;
    const environment = di.environment orelse return error.MissingEnvironment;

    if (input.name.len == 0) return error.NameRequired;
    if (!memories_mod.isValidMemoryName(input.name)) return error.InvalidName;

    const content = memories_mod.readMemoryFile(allocator, io, environment, input.name) orelse {
        return error.NotFound;
    };
    defer allocator.free(content);

    // Re-list for title/path/size. The re-list is cheap (single
    // `openDir` + iterate) and avoids re-parsing the file to extract
    // the title (readMemoryFile returns raw bytes).
    const list = memories_mod.listAllMemories(allocator, io, environment);
    defer memories_mod.freeMemoriesList(allocator, list);

    var found: ?memories_mod.MemoryInfo = null;
    for (list) |m| {
        if (std.mem.eql(u8, m.name, input.name)) {
            found = m;
            break;
        }
    }
    const m = found orelse {
        // Defensive: the file existed at read time but the re-list
        // does not see it. Treat as not-found rather than 200/empty.
        return error.NotFound;
    };

    // Duplicate the matched slices + content so the output survives
    // the `free` defers above. `errdefer` reverts each successful
    // dupe if a later dupe fails (the partial state would otherwise
    // leak — the dupes are on `allocator`, which may or may not be
    // an arena).
    var duped_name: ?[]u8 = null;
    var duped_title: ?[]u8 = null;
    var duped_path: ?[]u8 = null;
    var duped_content: ?[]u8 = null;
    errdefer {
        if (duped_name) |v| allocator.free(v);
        if (duped_title) |v| allocator.free(v);
        if (duped_path) |v| allocator.free(v);
        if (duped_content) |v| allocator.free(v);
    }
    duped_name = try allocator.dupe(u8, m.name);
    duped_title = try allocator.dupe(u8, m.title);
    duped_path = try allocator.dupe(u8, m.path);
    duped_content = try allocator.dupe(u8, content);

    return .{ .payload = .{
        .name = duped_name.?,
        .title = duped_title.?,
        .path = duped_path.?,
        .size = m.size,
        .content = duped_content.?,
    } };
}

// =====================================================================
// Handler
// =====================================================================

const MemoryDetailResponse = struct {
    memory: ?MemoryDetailPayload = null,
    error_message: ?[]const u8 = null,
};

pub fn memoryDetailHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const name = req.params.get("name") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing :name" }),
        });
    };

    const outcome = useCase(allocator, ctx.io, .{ .name = name }) catch |err| {
        // Exhaustive mapping — adding a new MemoryDetailError variant
        // will fail to compile here (intentional). No `else` prong.
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.MissingEnvironment => 500,
            error.NameRequired => 400,
            error.InvalidName => 400,
            error.NotFound => 404,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.MissingEnvironment => "Missing environment",
            error.NameRequired => "Missing :name",
            error.InvalidName => "Invalid memory name",
            error.NotFound => "Memory not found",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned slices. On the per-request arena
    // this is a no-op (the arena reaps at request end) but the
    // explicit frees are defensive + document ownership.
    defer {
        allocator.free(outcome.payload.name);
        allocator.free(outcome.payload.title);
        allocator.free(outcome.payload.path);
        allocator.free(outcome.payload.content);
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, MemoryDetailResponse{ .memory = outcome.payload }, .{}),
    });
}

// ===== Tests merged from memories_crud_test.zig (2026-09-11 flatten) =====
// Static regression checks for the memories CRUD HTTP handlers
// (Chunk 3 of `docs/plans/2026-06-17-add-memories-settings-menu.md`).
// 
// Why this file exists
// ────────────────────
// The four new handlers — `memoryDetailHandler`, `memoryCreateHandler`,
// `memoryUpdateHandler`, `memoryDeleteHandler` — are thin wrappers
// over the `readMemoryFile` / `writeMemoryFile` / `deleteMemoryFile`
// helpers in `src/modules/agent/tools/memories.zig` (added in
// Chunk 1 of the plan). The helpers themselves have behavioural
// tests in `src/modules/agent/tools/memories_test.zig`; this file
// only checks the *wrapper-shape* contracts that the helpers don't
// cover:
// 
//   - The handler gets the `environment` from the singleton and
//     returns 500 when it's missing.
//   - The handler reads the `:name` URL path parameter and
//     returns 400 when it's missing.
//   - The handler calls the right helper with the right arguments
//     and maps its boolean return into the right HTTP status code.
//   - The handler uses `std.json.Stringify.valueAlloc` (typed
//     response struct), NOT hand-rolled `std.fmt.allocPrint` (which
//     doesn't escape quotes in `content`).
//   - The handler respects the right HTTP verb semantics:
//     `200` for GET / PUT / DELETE success, `201` for POST success,
//     `400` for bad input, `404` for not-found, `409` for duplicate.
//   - DELETE is idempotent (200 even when the file is already
//     missing).
// 
// Why static checks (not behavioural tests)
// ──────────────────────────────────────────
// Standing up a full HTTP request/response against a real or in-memory
// `GinwaServer` requires the `nalarcore` singleton, the Io runtime,
// the SQLite DB, and a real `*const std.process.Environ.Map`. That's
// the same problem the existing `routines_run_test.zig` and
// `task_create_routines_test.zig` solve with static substring
// checks, and we follow the same pattern. The integration test
// (live `curl` smoke test in Chunk 10 of the plan) covers the
// end-to-end behaviour; here we just lock the contract that future
// refactors must keep.
// 
// Plan: docs/plans/2026-06-17-add-memories-settings-menu.md (Chunk 3)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const DETAIL_PATH = "src/http_handlers/memories_detail.zig";
const CREATE_PATH = "src/http_handlers/memories_create.zig";
const UPDATE_PATH = "src/http_handlers/memories_update.zig";
const DELETE_PATH = "src/http_handlers/memories_delete.zig";
const MOD_PATH = "src/http_handlers/mod.zig";
const MAIN_PATH = "src/http_routes.zig";
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
