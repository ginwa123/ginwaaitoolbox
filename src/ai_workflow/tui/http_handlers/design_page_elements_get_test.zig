//! Static regression checks for the design elements get handler.
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.7)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_page_elements_get.zig";

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

test "design_page_elements_get handler calls design_model.getElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.getElement") == null) {
        std.debug.print("!! {s} does not call design_model.getElement !!\n", .{HANDLER_PATH});
        return error.GetElementCallMissing;
    }
}

test "design_page_elements_get handler returns 200 + element envelope + maps 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print("!! {s} does not return 200 on success !!\n", .{HANDLER_PATH});
        return error.Status200Missing;
    }
    if (std.mem.indexOf(u8, source, "makeDesignElementFullResponse") == null) {
        std.debug.print("!! {s} does not use makeDesignElementFullResponse !!\n", .{HANDLER_PATH});
        return error.TypedEnvelopeMissing;
    }
    if (std.mem.indexOf(u8, source, "error.ElementNotFound => 404") == null) {
        std.debug.print("!! {s} does not map ElementNotFound to 404 !!\n", .{HANDLER_PATH});
        return error.NotFound404MappingMissing;
    }
}

test "design_page_elements_get handler requires element_id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"element_id\")") == null) {
        std.debug.print("!! {s} does not read the element_id path param !!\n", .{HANDLER_PATH});
        return error.ElementIdParamMissing;
    }
}
