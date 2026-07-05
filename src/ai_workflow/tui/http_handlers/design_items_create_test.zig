//! Static regression checks for the `POST /items/design` handler.
//!
//! Why this file exists
//! ────────────────────
//! The Design Mode feature (plan: `2026-07-05-design-mode.md`)
//! introduces a new `item_type='design'` workspace item. The create
//! handler must:
//!   1. Parse `{name}` via `parseFromSliceLeaky` (per-request arena).
//!   2. INSERT a `workspace_items` row with `item_type='design'`.
//!   3. Return 201 with `{id, workspace_id, item_type:"design", name,
//!      position, pages:[]}`.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_items_create.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
/// The returned buffer is owned by the caller (freed with `allocator.free`).
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

test "design_items_create handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must use `parseFromSliceLeaky` (per-request arena
    // owns the memory — no explicit deinit needed). See project
    // memory `nalar-http-handler-thin-wrapper-pattern`.
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The create-body contract is broken. Switch from `parseFromSlice`\n" ++
                "   to `parseFromSliceLeaky`.\n" ++
                "   See docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2).\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
    // The handler must extract the `name` field from the parsed body
    // and pass it to the useCase. The useCase is responsible for
    // validating non-empty and forwarding to the INSERT. Two
    // substrings cover both the pre- and post-`useCase`-split shapes:
    //   - `parsed.name` (pre-split: handler reads .name directly)
    //   - `input.body.name` (post-split: useCase reads via the input)
    if (std.mem.indexOf(u8, source, "parsed.name") == null and
        std.mem.indexOf(u8, source, "input.body.name") == null)
    {
        std.debug.print(
            "\n!! {s} does not extract .name from the parsed body !!\n" ++
                "   The handler/useCase must reference either `parsed.name`\n" ++
                "   or `input.body.name` for the new design item.\n",
            .{HANDLER_PATH},
        );
        return error.NameExtractionMissing;
    }
}

test "design_items_create handler hard-codes item_type='design'" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must INSERT with `item_type='design'` (the column is
    // a free-form TEXT, so the handler writes the literal at INSERT
    // time rather than reading from the request body).
    if (std.mem.indexOf(u8, source, "'design'") == null) {
        std.debug.print(
            "\n!! {s} does not hard-code 'design' !!\n" ++
                "   The item_type contract is broken: the INSERT must write\n" ++
                "   the literal `'design'` to the `item_type` column.\n",
            .{HANDLER_PATH},
        );
        return error.ItemTypeDesignMissing;
    }
}

test "design_items_create handler returns 201 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // POST that creates a resource → 201 Created.
    if (std.mem.indexOf(u8, source, ".status_code = 201") == null) {
        std.debug.print(
            "\n!! {s} does not return a 201 status code !!\n" ++
                "   Use `.status_code = 201` on the success branch.\n",
            .{HANDLER_PATH},
        );
        return error.Status201Missing;
    }
}

test "design_items_create handler uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The response must use the typed `std.json.Stringify.valueAlloc`
    // pattern (NOT hand-rolled `std.fmt.allocPrint`) so JSON escaping
    // works correctly for user-provided names. See project memory
    // `nalar-http-handler-thin-wrapper-pattern.md`.
    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify.valueAlloc !!\n" ++
                "   The response-shape contract is broken: handlers must use the\n" ++
                "   typed `valueAlloc` helper (NOT hand-rolled allocPrint) for\n" ++
                "   JSON responses that include user-provided text.\n",
            .{HANDLER_PATH},
        );
        return error.StringifyValueAllocMissing;
    }
}