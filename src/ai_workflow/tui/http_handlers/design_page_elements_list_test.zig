//! Static regression checks for the design elements list handler.
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.6)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_page_elements_list.zig";

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

test "design_page_elements_list handler calls design_model.listElements" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.listElements") == null) {
        std.debug.print("!! {s} does not call design_model.listElements !!\n", .{HANDLER_PATH});
        return error.ListElementsCallMissing;
    }
}

test "design_page_elements_list handler returns 200 + typed elements envelope" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print("!! {s} does not return 200 on success !!\n", .{HANDLER_PATH});
        return error.Status200Missing;
    }
    if (std.mem.indexOf(u8, source, "makeDesignElementListResponse") == null) {
        std.debug.print("!! {s} does not use makeDesignElementListResponse !!\n", .{HANDLER_PATH});
        return error.TypedEnvelopeMissing;
    }
}

test "design_page_elements_list handler validates page_id path param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"page_id\")") == null) {
        std.debug.print("!! {s} does not read the page_id path param !!\n", .{HANDLER_PATH});
        return error.PageIdParamMissing;
    }
}
