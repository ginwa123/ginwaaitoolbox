//! Static-contract tests for `frontend_log_post`
//! (POST /api/logs, Chunk 2 of
//! `docs/superpowers/plans/2026-07-17-frontend-error-logs.md`).
//!
//! Why this file exists
//! ────────────────────
//! The handler is a thin wrapper over the SQL insert + dedup-update
//! in `src/migrations/migration.zig`'s `logs` table (Migration 063).
//! Standing up a real `GinwaServer` + nalarcore singleton + Io +
//! SQLite + env to exercise the HTTP path is the same burden as the
//! memories / routines test files documented — too much integration
//! infra for a single endpoint. We follow the project's
//! static-contract pattern: these 10 tests grep the handler for the
//! contract substrings a future refactor must preserve
//! (parseFromSliceLeaky, validation messages, status codes).
//!
//! The 3 behavioural SQL tests (dedup logic) live in the same file
//! and were appended in Task 2.3 of the same chunk.
//!
//! Plan: docs/plans/2026-07-17-frontend-error-logs-design.md
//!       docs/superpowers/plans/2026-07-17-frontend-error-logs.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/frontend_log_post.zig";

/// Read a source file from disk, normalize CRLF→LF, free raw.
/// Same shape as `memories_crud_test.zig::readSource` and
/// `routines_run_test.zig` test patterns.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

// =============================================================================
// Static-contract tests
// =============================================================================

test "frontend_log_post handler uses parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The per-request arena owns the parsed value's allocations.\n" ++
                "   Using parseFromSlice would create an internal arena that\n" ++
                "   requires explicit deinit — wrong for this codebase.\n" ++
                "   See memories_create.zig:181 for the precedent.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
}

test "frontend_log_post handler validates the level field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The validation error message must include the literal
    // substring "missing required field: level" so the static test
    // (and a future logger UI) can grep for it consistently.
    if (std.mem.indexOf(u8, source, "missing required field: level") == null) {
        std.debug.print(
            "\n!! {s} does not validate the level field !!\n" ++
                "   The handler must surface a 400 with the substring\n" ++
                "`missing required field: level` when level is missing.\n",
            .{HANDLER_PATH},
        );
        return error.LevelValidationMissing;
    }
}

test "frontend_log_post handler validates the kind field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "missing required field: kind") == null) {
        std.debug.print(
            "\n!! {s} does not validate the kind field !!\n" ++
                "   The handler must surface a 400 with the substring\n" ++
                "`missing required field: kind` when kind is missing.\n",
            .{HANDLER_PATH},
        );
        return error.KindValidationMissing;
    }
}

test "frontend_log_post handler validates the message field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "missing required field: message") == null) {
        std.debug.print(
            "\n!! {s} does not validate the message field !!\n" ++
                "   The handler must surface a 400 with the substring\n" ++
                "`missing required field: message` when message is missing.\n",
            .{HANDLER_PATH},
        );
        return error.MessageValidationMissing;
    }
}

test "frontend_log_post handler validates level value" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The enum-value rejection message must include the substring
    // "level must be one of" so the LLM sees a self-correcting hint.
    if (std.mem.indexOf(u8, source, "level must be one of") == null) {
        std.debug.print(
            "\n!! {s} does not validate the level enum value !!\n" ++
                "   The handler must reject unknown level values with\n" ++
                "   the substring `level must be one of ...`.\n",
            .{HANDLER_PATH},
        );
        return error.LevelValueValidationMissing;
    }
}

test "frontend_log_post handler validates kind value" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "kind must be one of") == null) {
        std.debug.print(
            "\n!! {s} does not validate the kind enum value !!\n" ++
                "   The handler must reject unknown kind values with\n" ++
                "   the substring `kind must be one of ...`.\n",
            .{HANDLER_PATH},
        );
        return error.KindValueValidationMissing;
    }
}

test "frontend_log_post handler uses makeErrorResponse for error responses" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // All error responses must use the typed `makeErrorResponse`
    // helper so the wire shape (`{"error": "..."}`) is consistent.
    if (std.mem.indexOf(u8, source, "makeErrorResponse") == null) {
        std.debug.print(
            "\n!! {s} does not use http_response.makeErrorResponse !!\n" ++
                "   Hand-rolled allocPrint would drift from the project\n" ++
                "   standard error shape and break LLM-side parsing.\n",
            .{HANDLER_PATH},
        );
        return error.MakeErrorResponseMissing;
    }
}

test "frontend_log_post handler returns 204 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // 204 No Content is the documented success status.
    if (std.mem.indexOf(u8, source, "status_code = 204") == null) {
        std.debug.print(
            "\n!! {s} does not return 204 on success !!\n" ++
                "   The design doc says POST /api/logs returns 204 No Content\n" ++
                "   with an empty body. Use `res.rawResponse` for that — see\n" ++
                "   `cors.zig:8` for the precedent.\n",
            .{HANDLER_PATH},
        );
        return error.NoContentStatusMissing;
    }
}

test "frontend_log_post handler returns 400 on missing field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // 400 is the documented status for validation failures.
    if (std.mem.indexOf(u8, source, "status_code = 400") == null) {
        std.debug.print(
            "\n!! {s} does not return 400 on validation failure !!\n",
            .{HANDLER_PATH},
        );
        return error.BadRequestStatusMissing;
    }
}

test "frontend_log_post handler returns 500 on db error" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // 500 is the documented status for DB persistence failures
    // (locked, full disk, ...).
    if (std.mem.indexOf(u8, source, "status_code = 500") == null) {
        std.debug.print(
            "\n!! {s} does not return 500 on DB failure !!\n" ++
                "   The handler must distinguish persisted-row success (204)\n" ++
                "   from DB-side failure (500). The dedup SELECT and the\n" ++
                "   INSERT/UPDATE both need 500 mappings.\n",
            .{HANDLER_PATH},
        );
        return error.InternalErrorStatusMissing;
    }
}
