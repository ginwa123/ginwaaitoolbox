//! Static regression checks for the design elements delete handler.
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.10)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_page_elements_delete.zig";

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

test "design_page_elements_delete handler calls design_model.deleteElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.deleteElement") == null) {
        std.debug.print("!! {s} does not call design_model.deleteElement !!\n", .{HANDLER_PATH});
        return error.DeleteElementCallMissing;
    }
}

test "design_page_elements_delete handler returns 200 + deleted flag" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print("!! {s} does not return 200 on success !!\n", .{HANDLER_PATH});
        return error.Status200Missing;
    }
    if (std.mem.indexOf(u8, source, ".deleted = deleted") == null) {
        std.debug.print("!! {s} does not include deleted flag in response !!\n", .{HANDLER_PATH});
        return error.DeletedFlagMissing;
    }
}

test "design_page_elements_delete handler emits SSE on actually-deleted" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "onEventSendDesignElementDeleted") == null) {
        std.debug.print("!! {s} does not emit design_element_deleted SSE event !!\n", .{HANDLER_PATH});
        return error.SseEmitMissing;
    }
}
