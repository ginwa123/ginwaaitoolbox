//! Static regression checks for the design elements update handler.
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.9)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_page_elements_update.zig";

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

test "design_page_elements_update handler parses body + calls updateElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("!! {s} does not use parseFromSliceLeaky !!\n", .{HANDLER_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
    if (std.mem.indexOf(u8, source, "design_model.updateElement") == null) {
        std.debug.print("!! {s} does not call design_model.updateElement !!\n", .{HANDLER_PATH});
        return error.UpdateElementCallMissing;
    }
}

test "design_page_elements_update handler returns 200 + NothingToUpdate to 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print("!! {s} does not return 200 on success !!\n", .{HANDLER_PATH});
        return error.Status200Missing;
    }
    if (std.mem.indexOf(u8, source, "error.NothingToUpdate => 400") == null) {
        std.debug.print("!! {s} does not map NothingToUpdate to 400 !!\n", .{HANDLER_PATH});
        return error.NothingToUpdateStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "error.ElementNotFound => 404") == null) {
        std.debug.print("!! {s} does not map ElementNotFound to 404 !!\n", .{HANDLER_PATH});
        return error.ElementNotFoundStatusMissing;
    }
}

test "design_page_elements_update handler emits SSE on update" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "onEventSendDesignElementUpdated") == null) {
        std.debug.print("!! {s} does not emit design_element_updated SSE event !!\n", .{HANDLER_PATH});
        return error.SseEmitMissing;
    }
}
