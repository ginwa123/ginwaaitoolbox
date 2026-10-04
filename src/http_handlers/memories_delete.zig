//! `DELETE /api/memories/:name` — delete a global memory file.
//!
//! No body. On success: 200 with `{"success":true,"name":"..."}`.
//! Idempotent: deleting a memory that does not exist still returns 200.
//!
//! Layered as:
//!   - `useCase` — resolves the singleton + env, validates the name,
//!     calls `deleteMemoryFile`, and returns a heap-owned `name` slice
//!     (the path param is borrowed; duping it makes the handler
//!     independently own the response data).
//!   - `memoryDeleteHandler` — thin orchestrator: parses `:name`,
//!     calls `useCase`, maps errors to status codes, builds the JSON
//!     response.
//!
//! Preserves the static-contract assertions in `memories_crud_test.zig`:
//!   - `getSingleton` + `500` substring checks
//!   - `params.get("name")` + `400` substring checks
//!   - `isValidMemoryName` validation
//!   - `deleteMemoryFile` + `200` (idempotent success) substring checks
//!   - `std.json.Stringify.valueAlloc` substring check

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const memories_mod = pabrikcore.memories;
const http_response = @import("http_response.zig");

/// Response shape for `DELETE /api/memories/:name`.
///
/// Idempotent: `deleteMemoryFile` returns true when the file is
/// deleted OR was already missing (see `src/modules/agent/tools/memories.zig`).
/// The handler therefore always returns 200 with `success=true` on a
/// valid name.
pub const DeleteMemoryResponse = struct {
    success: bool = true,
    name: []const u8,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code.
pub const MemoryDeleteError = error{
    /// `getSingleton()` failed — server not initialised.
    ServerNotInitialized,
    /// Singleton has no environment. Maps to 500.
    MissingEnvironment,
    /// `:name` path param was missing or empty.
    NameRequired,
    /// The name failed `isValidMemoryName` (path-traversal or non-md).
    InvalidName,
    /// `deleteMemoryFile` returned false (the helper already
    /// validated the name + env, so the only remaining cause is an
    /// unexpected non-`FileNotFound` IO error). Maps to 400.
    DeleteFailed,
    /// `allocator.dupe` failed while building the heap-owned name
    /// slice for the response.
    OutOfMemory,
};

/// Inputs to the delete use-case.
pub const MemoryDeleteInput = struct {
    name: []const u8,
};

/// Output of the delete use-case. `name` is HEAP-OWNED by the
/// use-case (the path param is borrowed; duping it lets the
/// handler hand the response to the JSON serializer without keeping
/// the request alive).
pub const MemoryDeleteOutput = struct {
    name: []u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Delete a global memory file (idempotent).
///
/// Steps:
///   1. Get the singleton + env.
///   2. Validate `name` (non-empty + `isValidMemoryName`).
///   3. `deleteMemoryFile` to delete (or no-op if already missing).
///   4. Duplicate `name` so the handler can return it in the response.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: MemoryDeleteInput,
) MemoryDeleteError!MemoryDeleteOutput {
    const di = pabrikcore.getSingleton() catch return error.ServerNotInitialized;
    const environment = di.environment orelse return error.MissingEnvironment;

    if (input.name.len == 0) return error.NameRequired;
    if (!memories_mod.isValidMemoryName(input.name)) return error.InvalidName;

    if (!memories_mod.deleteMemoryFile(allocator, io, environment, input.name)) {
        // `deleteMemoryFile` only returns false on validation error,
        // missing environment, or a non-`FileNotFound` IO error.
        // Validation already passed and the environment is set, so
        // 400 is the right "we could not fulfill this request" status.
        return error.DeleteFailed;
    }

    return .{ .name = try allocator.dupe(u8, input.name) };
}

// =====================================================================
// Handler
// =====================================================================

pub fn memoryDeleteHandler(
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
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.MissingEnvironment => 500,
            error.NameRequired => 400,
            error.InvalidName => 400,
            error.DeleteFailed => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.MissingEnvironment => "Missing environment",
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
        .data = try std.json.Stringify.valueAlloc(allocator, DeleteMemoryResponse{ .name = outcome.name }, .{}),
    });
}

// ===== Tests merged from memories_crud_test.zig (2026-09-11 flatten) =====
const text_normalize = @import("helpers").text_normalize;
const testing = std.testing;

const DELETE_PATH = "src/http_handlers/memories_delete.zig";

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
// src/http_handlers/task_create.zig for the precedent.
// =============================================================================
