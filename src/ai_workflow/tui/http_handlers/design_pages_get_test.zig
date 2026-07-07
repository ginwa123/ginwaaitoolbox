//! Static regression checks for the design pages get handler.
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_pages_get.zig";

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

test "design_pages_get handler calls design_model.getPage" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.getPage") == null) {
        std.debug.print("!! {s} does not call design_model.getPage !!\n", .{HANDLER_PATH});
        return error.GetPageCallMissing;
    }
}

test "design_pages_get handler returns 200 + typed page envelope" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print("!! {s} does not return 200 on success !!\n", .{HANDLER_PATH});
        return error.Status200Missing;
    }
    if (std.mem.indexOf(u8, source, "makeDesignPageFullResponse") == null) {
        std.debug.print("!! {s} does not use makeDesignPageFullResponse !!\n", .{HANDLER_PATH});
        return error.TypedEnvelopeMissing;
    }
}

test "design_pages_get handler maps PageNotFound to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.PageNotFound => 404") == null) {
        std.debug.print("!! {s} does not map PageNotFound to 404 !!\n", .{HANDLER_PATH});
        return error.PageNotFoundStatusMissing;
    }
}

test "design_pages_get handler validates page_id path param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"page_id\")") == null) {
        std.debug.print("!! {s} does not read the page_id path param !!\n", .{HANDLER_PATH});
        return error.PageIdParamMissing;
    }
}
