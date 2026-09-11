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
const text_normalize = @import("helpers").text_normalize;

const design_model = nalarcore.ai_mod.design_model;
const http_response = @import("http_response.zig");

const HANDLER_PATH = "src/http_handlers/design_pages_create.zig";

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
//
// Behavioural unit test (NOT a static grep — see the project rule in
// `.nalar/memories/static-contract-test-when-to-prefer-behavioural.md`).
//
// The wire contract requires `workspace_item_task_id` to appear on
// every page response. We exercise the actual production code path:
//   `design_model.DesignPage` → `makeDesignPageResponse(page)` (in
//   http_response.zig) → `std.json.Stringify.valueAlloc(...)` (in
//   design_pages_create.zig).
//
// Asserting on the serialized JSON proves that:
//   1. The DesignPage struct has the field (model layer).
//   2. The makeDesignPageResponse helper copies the field (wire layer).
//   3. std.json.Stringify emits it with the expected key (serialization).
// All three are real code paths; a regression in any of them surfaces.
//
// A static grep would only prove that the source mentions the field
// name — which is true even if the field is dead code or shadowed by
// a different field at runtime. This test fails if the field goes
// missing at any layer.
test "makeDesignPageResponse serializes workspace_item_task_id on the wire" {
    const allocator = testing.allocator;

    // Build the canonical page row that setDesignPage produces. The
    // `workspace_item_task_id` is the FK we care about.
    const page = design_model.DesignPage{
        .id = try allocator.dupe(u8, "page_test_abc"),
        .workspace_item_id = try allocator.dupe(u8, "item_test_xyz"),
        .name = try allocator.dupe(u8, "Login"),
        .workspace_item_task_id = try allocator.dupe(u8, "task_test_123"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try allocator.dupe(u8, ""),
        .updated_at = try allocator.dupe(u8, ""),
    };
    defer {
        allocator.free(page.id);
        allocator.free(page.workspace_item_id);
        allocator.free(page.name);
        allocator.free(page.workspace_item_task_id);
        allocator.free(page.created_at);
        allocator.free(page.updated_at);
    }

    // Map the model struct into the wire response struct (the same
    // helper the handler calls).
    const response = http_response.makeDesignPageResponse(page);

    // Serialize via std.json.Stringify.valueAlloc — the exact code
    // path design_pages_create.zig uses for the 201 response body.
    const json = try std.json.Stringify.valueAlloc(allocator, response, .{});
    defer allocator.free(json);

    // The FK MUST be present in the wire payload (the whole point of
    // the design-page-task-fk migration). Assert the JSON key +
    // value round-trip cleanly. A static grep can't catch a regression
    // where the field is declared but dropped by the serializer or
    // shadowed by a different name.
    const expected_key_value =
        "\"workspace_item_task_id\":\"task_test_123\"";
    if (std.mem.indexOf(u8, json, expected_key_value) == null) {
        std.debug.print(
            "\n!! Wire payload missing workspace_item_task_id !!\n" ++
                "   JSON body did not contain the expected FK key/value pair.\n" ++
                "   Actual body:\n{s}\n" ++
                "   Expected substring: {s}\n",
            .{ json, expected_key_value },
        );
        return error.WorkspaceItemTaskIdWireFieldMissing;
    }
}