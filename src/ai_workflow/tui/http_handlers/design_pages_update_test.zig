//! Static regression checks for the `PUT /design/pages/:page_id` handler.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.5).

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

test "design_pages_update handler uses parseFromSliceLeaky" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("!! {s} does not use parseFromSliceLeaky !!\n", .{HANDLER_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
}

test "design_pages_update handler calls design_model.updatePageHtml" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "design_model.updatePageHtml") == null) {
        std.debug.print("!! {s} does not call design_model.updatePageHtml !!\n", .{HANDLER_PATH});
        return error.ModelCallMissing;
    }
}

test "design_pages_update handler emits design_page_updated SSE event" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "onEventSendDesignPageUpdated") == null) {
        std.debug.print("!! {s} does not call onEventSendDesignPageUpdated !!\n", .{HANDLER_PATH});
        return error.SseEmitMissing;
    }
}

test "design_pages_update handler rejects html > 5 MB" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "MAX_HTML_BYTES") == null or
        std.mem.indexOf(u8, source, "413") == null)
    {
        std.debug.print("!! {s} does not enforce 5 MB html limit (413) !!\n", .{HANDLER_PATH});
        return error.SizeLimitMissing;
    }
}

test "design_pages_update handler returns 200 on success" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "status_code = 200") == null) {
        std.debug.print("!! {s} does not return 200 on success !!\n", .{HANDLER_PATH});
        return error.StatusCode200Missing;
    }
}