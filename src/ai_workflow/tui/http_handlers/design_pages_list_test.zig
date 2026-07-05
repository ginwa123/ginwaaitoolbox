//! Static regression checks for the `GET /design/pages` handler.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.3).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_pages_list.zig";

/// Read a source file from disk, relative to the project root.
/// Uses `std.Io.Dir.cwd().readFileAlloc` with `std.testing.io` (the
/// Zig 0.16 Io runtime that the test harness provides).
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

test "design_pages_list handler does not parse a request body" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "req.body") != null) {
        std.debug.print("!! {s} should NOT read req.body (GET has no body) !!\n", .{HANDLER_PATH});
        return error.BodyShouldNotBeParsed;
    }
}

test "design_pages_list handler calls design_model.listPages" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "design_model.listPages") == null) {
        std.debug.print("!! {s} does not call design_model.listPages !!\n", .{HANDLER_PATH});
        return error.ModelCallMissing;
    }
}

test "design_pages_list handler validates item_id + workspace_id" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "item_id") == null or
        std.mem.indexOf(u8, source, "workspace_id") == null)
    {
        std.debug.print("!! {s} does not validate item_id + workspace_id !!\n", .{HANDLER_PATH});
        return error.ParamValidationMissing;
    }
}

test "design_pages_list handler returns 200 on success" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "status_code = 200") == null) {
        std.debug.print("!! {s} does not return 200 on success !!\n", .{HANDLER_PATH});
        return error.StatusCode200Missing;
    }
}