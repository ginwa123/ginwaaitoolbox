//! Static regression checks for the `DELETE /design/pages/:page_id` handler.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.6).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_pages_delete.zig";

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

test "design_pages_delete handler does not parse a request body" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "req.body") != null) {
        std.debug.print("!! {s} should NOT read req.body (DELETE has no body) !!\n", .{HANDLER_PATH});
        return error.BodyShouldNotBeParsed;
    }
}

test "design_pages_delete handler calls design_model.deletePage" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "design_model.deletePage") == null) {
        std.debug.print("!! {s} does not call design_model.deletePage !!\n", .{HANDLER_PATH});
        return error.ModelCallMissing;
    }
}

test "design_pages_delete handler emits design_page_deleted SSE event" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "onEventSendDesignPageDeleted") == null) {
        std.debug.print("!! {s} does not call onEventSendDesignPageDeleted !!\n", .{HANDLER_PATH});
        return error.SseEmitMissing;
    }
}

test "design_pages_delete handler returns 200 with deleted=true on success" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "status_code = 200") == null or
        std.mem.indexOf(u8, source, "deleted: bool = true") == null)
    {
        std.debug.print("!! {s} does not return 200 with deleted=true !!\n", .{HANDLER_PATH});
        return error.SuccessResponseMissing;
    }
}

test "design_pages_delete handler validates page_id + item_id + workspace_id" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "page_id") == null or
        std.mem.indexOf(u8, source, "item_id") == null or
        std.mem.indexOf(u8, source, "workspace_id") == null)
    {
        std.debug.print("!! {s} does not validate page_id + item_id + workspace_id !!\n", .{HANDLER_PATH});
        return error.ParamValidationMissing;
    }
}