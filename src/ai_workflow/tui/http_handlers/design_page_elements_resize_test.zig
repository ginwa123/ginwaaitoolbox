//! Static regression checks for the design elements resize handler.
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.12)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_page_elements_resize.zig";

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

test "design_page_elements_resize handler calls design_model.resizeElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.resizeElement") == null) {
        std.debug.print("!! {s} does not call design_model.resizeElement !!\n", .{HANDLER_PATH});
        return error.ResizeElementCallMissing;
    }
}

test "design_page_elements_resize handler requires width and height" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "width is required") == null) {
        std.debug.print("!! {s} does not require width !!\n", .{HANDLER_PATH});
        return error.WidthRequiredMissing;
    }
    if (std.mem.indexOf(u8, source, "height is required") == null) {
        std.debug.print("!! {s} does not require height !!\n", .{HANDLER_PATH});
        return error.HeightRequiredMissing;
    }
}

test "design_page_elements_resize handler emits SSE on update" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "onEventSendDesignElementUpdated") == null) {
        std.debug.print("!! {s} does not emit design_element_updated SSE event !!\n", .{HANDLER_PATH});
        return error.SseEmitMissing;
    }
}
