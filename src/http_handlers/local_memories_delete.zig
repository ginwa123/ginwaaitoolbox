//! `DELETE /api/local-memories/:name?cwd=...` — delete a local memory file.
//!
//! No body. On success: 200 with `{"success":true,"name":"..."}`.
//! Idempotent: deleting a memory that does not exist still returns 200.
//!
//! Layered as:
//!   - `useCase` — validates `:name`, resolves the local memories dir
//!     (query `cwd` first, then io fallback), calls
//!     `deleteLocalMemoryFile`, and returns a heap-owned `name` slice.
//!   - `localMemoryDeleteHandler` — thin orchestrator: parses `:name`
//!     + `?cwd=` query, calls `useCase`, maps errors to status codes,
//!     builds the JSON response.
//!
//! Preserves the static-contract assertions in `local_memories_crud_test.zig`:
//!   - `get_local_memories_path_for_dir` + `get_local_memories_path_from_io`
//!     substring checks
//!   - `params.get("name")` + `400` substring checks
//!   - `isValidMemoryName` validation
//!   - `deleteLocalMemoryFile` + `200` (idempotent success) substring checks
//!   - `std.json.Stringify.valueAlloc` substring check
//!   - `500` + `no cwd available` substring checks

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;
const http_response = @import("http_response.zig");

/// Response shape for `DELETE /api/local-memories/:name`.
///
/// Idempotent: `deleteLocalMemoryFile` returns true when the file
/// is deleted OR was already missing (matches the
/// `deleteMemoryFile` global helper's contract). The handler
/// therefore always returns 200 with `success=true` on a valid
/// name.
pub const DeleteLocalMemoryResponse = struct {
    success: bool = true,
    name: []const u8,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code.
pub const LocalMemoryDeleteError = error{
    /// Neither the per-request `cwd` query nor the io fallback
    /// yielded a usable local-memories directory. Maps to 500.
    NoCwdAvailable,
    /// `:name` path param was missing or empty.
    NameRequired,
    /// The name failed `isValidMemoryName` (path-traversal or non-md).
    InvalidName,
    /// `deleteLocalMemoryFile` returned false (the helper already
    /// validated the name + dir, so the only remaining cause is an
    /// unexpected non-`FileNotFound` IO error). Maps to 400.
    DeleteFailed,
    /// `allocator.dupe` failed while building the heap-owned name
    /// slice for the response.
    OutOfMemory,
};

/// Inputs to the delete use-case.
pub const LocalMemoryDeleteInput = struct {
    name: []const u8,
    /// `?cwd=` query value (empty → fall back to the io CWD).
    cwd: []const u8,
};

/// Output of the delete use-case. `name` is HEAP-OWNED by the
/// use-case (the path param is borrowed; duping it lets the
/// handler hand the response to the JSON serializer without keeping
/// the request alive).
pub const LocalMemoryDeleteOutput = struct {
    name: []u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Delete a local memory file (idempotent).
///
/// Steps:
///   1. Validate `name` (non-empty + `isValidMemoryName`).
///   2. Resolve the local memories dir (query `cwd` → io fallback).
///   3. `deleteLocalMemoryFile` to delete (or no-op if missing).
///   4. Duplicate `name` so the handler can return it in the
///      response.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: LocalMemoryDeleteInput,
) LocalMemoryDeleteError!LocalMemoryDeleteOutput {
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

    if (!memories_mod.deleteLocalMemoryFile(allocator, io, dir_path, input.name)) {
        return error.DeleteFailed;
    }

    return .{ .name = try allocator.dupe(u8, input.name) };
}

// =====================================================================
// Handler
// =====================================================================

pub fn localMemoryDeleteHandler(
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
            error.DeleteFailed => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.NoCwdAvailable => "Could not resolve local memories directory (no cwd available)",
            error.NameRequired => "Missing :name",
            error.InvalidName => "Invalid memory name (must end in .md, no /, no ..)",
            error.DeleteFailed => "Failed to delete memory file",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    defer allocator.free(outcome.name);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, DeleteLocalMemoryResponse{ .name = outcome.name }, .{}),
    });
}

// ===== Tests merged from local_memories_crud_test.zig (2026-09-11 flatten) =====
const text_normalize = @import("helpers").text_normalize;
const testing = std.testing;

const DELETE_PATH = "src/http_handlers/local_memories_delete.zig";

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

test "local_memories_delete validates the :name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "isValidMemoryName") == null) {
        std.debug.print("\n!! {s} does not call isValidMemoryName !!\n", .{DELETE_PATH});
        return error.NameValidationMissing;
    }
}
