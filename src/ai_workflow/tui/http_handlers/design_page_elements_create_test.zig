//! Static regression checks for the design elements create handler.
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.8)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_page_elements_create.zig";

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

test "design_page_elements_create handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("!! {s} does not use parseFromSliceLeaky !!\n", .{HANDLER_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
    if (std.mem.indexOf(u8, source, "parsed.name") == null) {
        std.debug.print("!! {s} does not extract .name from the parsed body !!\n", .{HANDLER_PATH});
        return error.NameExtractionMissing;
    }
    if (std.mem.indexOf(u8, source, "parsed.html") == null) {
        std.debug.print("!! {s} does not extract .html from the parsed body !!\n", .{HANDLER_PATH});
        return error.HtmlExtractionMissing;
    }
}

test "design_page_elements_create handler calls design_model.addElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.addElement") == null) {
        std.debug.print("!! {s} does not call design_model.addElement !!\n", .{HANDLER_PATH});
        return error.AddElementCallMissing;
    }
}

test "design_page_elements_create handler returns 201 + emits SSE" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 201") == null) {
        std.debug.print("!! {s} does not return 201 on success !!\n", .{HANDLER_PATH});
        return error.Status201Missing;
    }
    if (std.mem.indexOf(u8, source, "onEventSendDesignElementCreated") == null) {
        std.debug.print("!! {s} does not emit design_element_created SSE event !!\n", .{HANDLER_PATH});
        return error.SseEmitMissing;
    }
}
