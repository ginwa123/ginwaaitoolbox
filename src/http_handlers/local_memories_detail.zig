//! `GET /api/local-memories/:name?cwd=...` — read a local memory file's
//! content + metadata.
//!
//! On success: 200 with `{"memory":{"name","title","path","size","content"}}`.
//!
//! Layered as:
//!   - `useCase` — validates `:name`, resolves the local memories dir
//!     (query `cwd` first, then io fallback), reads the file, re-lists
//!     to derive `title/path/size`, returns a heap-owned
//!     `LocalMemoryDetailPayload`.
//!   - `localMemoryDetailHandler` — thin orchestrator: extracts the
//!     `:name` path param + `?cwd=` query, calls `useCase`, maps
//!     errors to status codes, builds the JSON response.
//!
//! Preserves the static-contract assertions in `local_memories_crud_test.zig`:
//!   - `get_local_memories_path_for_dir` + `get_local_memories_path_from_io`
//!     substring checks
//!   - `params.get("name")` + `400` substring checks
//!   - `readLocalMemoryFile` + `listMemoriesInDir` + `404` substring checks
//!   - `isValidMemoryName` validation
//!   - `std.json.Stringify.valueAlloc` + `content` substring checks
//!   - `500` + `no cwd available` substring checks

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const http_response = @import("http_response.zig");

/// Response payload for `GET /api/local-memories/:name`.
///
/// `content` is JSON-escaped automatically by
/// `std.json.Stringify.valueAlloc` — do not hand-roll JSON for the
/// body.
pub const LocalMemoryDetailPayload = struct {
    name: []const u8,
    title: []const u8,
    path: []const u8,
    size: u64,
    content: []const u8,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code.
pub const LocalMemoryDetailError = error{
    /// Neither the per-request `cwd` query nor the io fallback
    /// yielded a usable local-memories directory. Maps to 500.
    NoCwdAvailable,
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
pub const LocalMemoryDetailInput = struct {
    name: []const u8,
    /// `?cwd=` query value (empty → fall back to the io CWD).
    cwd: []const u8,
};

/// Output of the detail use-case. Slice fields are HEAP-OWNED by the
/// use-case (duplicated from `listMemoriesInDir` + `readLocalMemoryFile`
/// so they survive the internal `freeMemoriesList` /
/// `allocator.free(content)` defers).
pub const LocalMemoryDetailOutput = struct {
    payload: LocalMemoryDetailPayload,
};

// =====================================================================
// Use case
// =====================================================================

/// Read a local memory file's content and metadata.
///
/// Steps:
///   1. Validate `name` (non-empty + `isValidMemoryName`).
///   2. Resolve the local memories dir (query `cwd` → io fallback).
///   3. Read the file via `readLocalMemoryFile`. File not found → 404.
///   4. Re-list via `listMemoriesInDir` to derive `title/path/size`.
///   5. Locate the entry by name. Missing → 404 (defensive).
///   6. Duplicate the matched slices so the output survives internal
///      `free` defers.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: LocalMemoryDetailInput,
) LocalMemoryDetailError!LocalMemoryDetailOutput {
    if (input.name.len == 0) return error.NameRequired;
    if (!memories_mod.isValidMemoryName(input.name)) return error.InvalidName;

    // Resolve the local memories dir (query first, then io fallback).
    var dir_path_alloc: ?[]const u8 = null;
    if (input.cwd.len > 0) {
        dir_path_alloc = memories_mod.get_local_memories_path_for_dir(allocator, input.cwd);
    }
    if (dir_path_alloc == null) {
        dir_path_alloc = memories_mod.get_local_memories_path_from_io(allocator, io);
    }
    const dir_path = dir_path_alloc orelse return error.NoCwdAvailable;
    defer allocator.free(dir_path);

    const content = memories_mod.readLocalMemoryFile(allocator, io, dir_path, input.name) orelse {
        return error.NotFound;
    };
    defer allocator.free(content);

    // Re-list for title/path/size. The re-list is cheap (single
    // openDir + iterate).
    const list = memories_mod.listMemoriesInDir(allocator, io, dir_path);
    defer memories_mod.freeMemoriesList(allocator, list);

    var found: ?memories_mod.MemoryInfo = null;
    for (list) |m| {
        if (std.mem.eql(u8, m.name, input.name)) {
            found = m;
            break;
        }
    }
    const m = found orelse {
        return error.NotFound;
    };

    // Duplicate the matched slices + content so the output survives
    // the `free` defers above.
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

const LocalMemoryDetailResponse = struct {
    memory: ?LocalMemoryDetailPayload = null,
    error_message: ?[]const u8 = null,
};

pub fn localMemoryDetailHandler(
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

    const cwd_raw = req.query.get("cwd") orelse "";
    const outcome = useCase(allocator, ctx.io, .{
        .name = name,
        .cwd = cwd_raw,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.NoCwdAvailable => 500,
            error.NameRequired => 400,
            error.InvalidName => 400,
            error.NotFound => 404,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.NoCwdAvailable => "Could not resolve local memories directory (no cwd available)",
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

    defer {
        allocator.free(outcome.payload.name);
        allocator.free(outcome.payload.title);
        allocator.free(outcome.payload.path);
        allocator.free(outcome.payload.content);
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, LocalMemoryDetailResponse{ .memory = outcome.payload }, .{}),
    });
}

// ===== Tests merged from local_memories_crud_test.zig (2026-09-11 flatten) =====
const text_normalize = @import("helpers").text_normalize;
const testing = std.testing;

const DETAIL_PATH = "src/http_handlers/local_memories_detail.zig";

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

test "local_memories_detail validates the :name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DETAIL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "isValidMemoryName") == null) {
        std.debug.print("\n!! {s} does not call isValidMemoryName !!\n", .{DETAIL_PATH});
        return error.NameValidationMissing;
    }
}
