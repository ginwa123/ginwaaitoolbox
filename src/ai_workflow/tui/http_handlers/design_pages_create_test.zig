//! Static regression checks for the `POST /design/pages` handler.
//!
//! Why this file exists
//! ────────────────────
//! The page-create endpoint upserts a design page for a workspace
//! item of `item_type='design'`. The handler must:
//!   1. Parse `{name, width?, height?}` via `parseFromSliceLeaky`
//!      (defaulting `width`/`height` to 1440×1024).
//!   2. Call `design_model.setDesignPage(...)`.
//!   3. Return 201 with the page as a `DesignPageResponse`.
//!
//! These contracts are enforced by static substring checks, matching
//! the project's `kanban_columns_create_test.zig` pattern.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_pages_create.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true. The
/// returned buffer is owned by the caller.
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

// ─── Contract 1: handler uses parseFromSliceLeaky ────────────────────────

test "design_pages_create handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The create-body contract is broken. Switch from `parseFromSlice`\n" ++
                "   to `parseFromSliceLeaky`.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }

    if (std.mem.indexOf(u8, source, "parsed.name") == null) {
        std.debug.print(
            "\n!! {s} does not extract .name from the parsed body !!\n" ++
                "   The handler must reference `parsed.name` for the new page.\n",
            .{HANDLER_PATH},
        );
        return error.NameExtractionMissing;
    }
}

// ─── Contract 2: handler calls design_model.setDesignPage ────────────────

test "design_pages_create handler calls design_model.setDesignPage" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.setDesignPage") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.setDesignPage !!\n" ++
                "   The POST contract is broken: the handler must delegate to\n" ++
                "   `design_model.setDesignPage(...)` (NOT raw SQL).\n",
            .{HANDLER_PATH},
        );
        return error.SetDesignPageCallMissing;
    }
}

// ─── Contract 3: handler returns 201 on success ──────────────────────────

test "design_pages_create handler returns 201 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 201") == null) {
        std.debug.print(
            "\n!! {s} does not return a 201 status code !!\n" ++
                "   Use `.status_code = 201` on the success branch.\n",
            .{HANDLER_PATH},
        );
        return error.Status201Missing;
    }
}

// ─── Contract 4: handler emits ItemPathMissing as 400 with right message ─

test "design_pages_create handler maps ItemPathMissing to 400 + correct message" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design item must have a path") == null) {
        std.debug.print(
            "\n!! {s} does not contain the 'design item must have a path' message !!\n" ++
                "   The handler must map `ItemPathMissing` to a 400 with the message\n" ++
                "   'design item must have a path' so the frontend can surface it.\n",
            .{HANDLER_PATH},
        );
        return error.ItemPathMissingMessageMissing;
    }
}

// ─── Contract 5: handler uses std.json.Stringify.valueAlloc ──────────────

test "design_pages_create handler uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify.valueAlloc !!\n" ++
                "   The response-shape contract is broken: the handler must use\n" ++
                "   `std.json.Stringify.valueAlloc` for the 201 response body.\n",
            .{HANDLER_PATH},
        );
        return error.ValueAllocMissing;
    }
}

// ─── Contract 6: response includes workspace_item_task_id FK field ───────

const RESPONSE_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

test "design_pages_create response includes workspace_item_task_id field" {
    const allocator = testing.allocator;

    // The handler delegates to `makeDesignPageResponse` in
    // `http_response.zig`, so the field-name assertion lives there.
    // We check BOTH files: the handler file (in case the field is
    // referenced inline) and the response file (where the struct
    // field is declared).
    const handler_src = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(handler_src);
    const response_src = try readSource(allocator, RESPONSE_PATH);
    defer allocator.free(response_src);

    if (std.mem.indexOf(u8, handler_src, "workspace_item_task_id") == null and
        std.mem.indexOf(u8, response_src, "workspace_item_task_id") == null)
    {
        std.debug.print(
            "\n!! Neither {s} nor {s} references workspace_item_task_id !!\n" ++
                "   The wire contract requires the FK on every page create response\n" ++
                "   so the frontend can resolve the chat task via the FK directly\n" ++
                "   (no name matching, no legacy migration).\n",
            .{ HANDLER_PATH, RESPONSE_PATH },
        );
        return error.WorkspaceItemTaskIdFieldMissing;
    }
}