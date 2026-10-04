//! `PUT /api/memories/:name` — replace the body of a global memory file.
//!
//! Body: `{"content":"..."}`.
//! On success: 200 with `{"memory":{name,title,path,size}}`.
//!
//! Layered as:
//!   - `useCase` — resolves the singleton + env, validates the name,
//!     runs the existence check, writes the file, re-lists to derive
//!     metadata, and returns a heap-owned `MemoryInfo`.
//!   - `memoryUpdateHandler` — thin orchestrator: parses `:name`
//!     and the body, calls `useCase`, maps errors to status codes,
//!     builds the JSON response.
//!
//! Preserves the static-contract assertions in `memories_crud_test.zig`:
//!   - `getSingleton` + `500` substring checks
//!   - `params.get("name")` + `400` substring checks
//!   - `isValidMemoryName` validation
//!   - `memoryExists` + `404` (NotFound) + `writeMemoryFile` substring checks
//!   - `parseFromSliceLeaky` + `Invalid JSON body` substring checks
//!   - `std.json.Stringify.valueAlloc` substring check

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const memories_mod = pabrikcore.memories;
const http_response = @import("http_response.zig");

/// JSON request body for `PUT /api/memories/:name`.
///
/// Only the new content is editable; the filename is fixed by the URL
/// path parameter. A separate `POST /api/memories` (with a new name)
/// is the way to create an additional memory.
const UpdateMemoryBody = struct {
    content: []const u8,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code.
pub const MemoryUpdateError = error{
    /// `getSingleton()` failed — server not initialised.
    ServerNotInitialized,
    /// Singleton has no environment. Maps to 500.
    MissingEnvironment,
    /// `:name` path param was missing or empty.
    NameRequired,
    /// The name failed `isValidMemoryName` (path-traversal or non-md).
    InvalidName,
    /// The memory does not exist (cannot edit a non-existent one). Maps to 404.
    NotFound,
    /// `writeMemoryFile` returned false (validation / IO failure).
    WriteFailed,
    /// Update succeeded but the file wasn't visible in the
    /// subsequent `listAllMemories` (consistency violation).
    NotVisible,
    /// `allocator.dupe` failed while building the heap-owned output.
    OutOfMemory,
};

/// Inputs to the update use-case.
pub const MemoryUpdateInput = struct {
    name: []const u8,
    content: []const u8,
};

/// Output of the update use-case. `memory` is HEAP-OWNED by the
/// use-case. The handler is responsible for freeing each slice.
pub const MemoryUpdateOutput = struct {
    memory: memories_mod.MemoryInfo,
};

// =====================================================================
// Use case
// =====================================================================

/// Replace the body of an existing global memory file.
///
/// Steps:
///   1. Get the singleton + env.
///   2. Validate `name` (non-empty + `isValidMemoryName`).
///   3. 404 if the memory does not exist (via `memoryExists`).
///   4. `writeMemoryFile` to overwrite the file.
///   5. Re-list via `listAllMemories` to derive `title/path/size`.
///   6. Locate the entry by name. Missing → 500 (consistency).
///   7. Duplicate the matched slices for the response.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: MemoryUpdateInput,
) MemoryUpdateError!MemoryUpdateOutput {
    const di = pabrikcore.getSingleton() catch return error.ServerNotInitialized;
    const environment = di.environment orelse return error.MissingEnvironment;

    if (input.name.len == 0) return error.NameRequired;
    if (!memories_mod.isValidMemoryName(input.name)) return error.InvalidName;

    // Update only succeeds for existing memories. 404 (not 400) so
    // the UI can distinguish "edit non-existent" from "bad input".
    if (!memories_mod.memoryExists(allocator, io, environment, input.name)) {
        return error.NotFound;
    }

    if (!memories_mod.writeMemoryFile(allocator, io, environment, input.name, input.content)) {
        return error.WriteFailed;
    }

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
        return error.NotVisible;
    };

    var duped_name: ?[]u8 = null;
    var duped_title: ?[]u8 = null;
    var duped_path: ?[]u8 = null;
    errdefer {
        if (duped_name) |v| allocator.free(v);
        if (duped_title) |v| allocator.free(v);
        if (duped_path) |v| allocator.free(v);
    }
    duped_name = try allocator.dupe(u8, m.name);
    duped_title = try allocator.dupe(u8, m.title);
    duped_path = try allocator.dupe(u8, m.path);

    return .{ .memory = .{
        .name = duped_name.?,
        .title = duped_title.?,
        .path = duped_path.?,
        .size = m.size,
    } };
}

// =====================================================================
// Handler
// =====================================================================

const UpdateMemoryResponse = struct {
    memory: ?memories_mod.MemoryInfo = null,
    error_message: ?[]const u8 = null,
};

pub fn memoryUpdateHandler(
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

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateMemoryBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const outcome = useCase(allocator, ctx.io, .{
        .name = name,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.MissingEnvironment => 500,
            error.NameRequired => 400,
            error.InvalidName => 400,
            error.NotFound => 404,
            error.WriteFailed => 400,
            error.NotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.MissingEnvironment => "Missing environment",
            error.NameRequired => "Missing :name",
            error.InvalidName => "Invalid memory name (must end in .md, no /, no ..)",
            error.NotFound => "Memory not found",
            error.WriteFailed => "Failed to write memory file",
            error.NotVisible => "Memory updated but not visible in directory listing",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    defer {
        allocator.free(outcome.memory.name);
        allocator.free(outcome.memory.title);
        allocator.free(outcome.memory.path);
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, UpdateMemoryResponse{ .memory = outcome.memory }, .{}),
    });
}

// ===== Tests merged from memories_crud_test.zig (2026-09-11 flatten) =====
const text_normalize = @import("helpers").text_normalize;
const testing = std.testing;

const UPDATE_PATH = "src/http_handlers/memories_update.zig";

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
