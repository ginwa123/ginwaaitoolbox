//! Static regression checks for the design pages update handler.
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.4)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_pages_update.zig";

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

test "design_pages_update handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("!! {s} does not use parseFromSliceLeaky !!\n", .{HANDLER_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
}

test "design_pages_update handler calls design_model.updatePageGeometry" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.updatePageGeometry") == null) {
        std.debug.print("!! {s} does not call design_model.updatePageGeometry !!\n", .{HANDLER_PATH});
        return error.UpdatePageGeometryCallMissing;
    }
}

test "design_pages_update handler returns 200 + typed page envelope" {
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

test "design_pages_update handler emits SSE on update" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "onEventSendDesignPageUpdated") == null) {
        std.debug.print("!! {s} does not emit design SSE event !!\n", .{HANDLER_PATH});
        return error.SseEmitMissing;
    }
}

test "design_pages_update handler maps PageNotFound to 404 + NothingToUpdate to 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.PageNotFound => 404") == null) {
        std.debug.print("!! {s} does not map PageNotFound to 404 !!\n", .{HANDLER_PATH});
        return error.PageNotFoundStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "error.NothingToUpdate => 400") == null) {
        std.debug.print("!! {s} does not map NothingToUpdate to 400 !!\n", .{HANDLER_PATH});
        return error.NothingToUpdateStatusMissing;
    }
}
