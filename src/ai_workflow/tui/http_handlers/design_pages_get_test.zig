//! Static regression checks for the `GET /design/pages/:page_id` handler.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.4).

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

test "design_pages_get handler does not parse a request body" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "req.body") != null) {
        std.debug.print("!! {s} should NOT read req.body (GET has no body) !!\n", .{HANDLER_PATH});
        return error.BodyShouldNotBeParsed;
    }
}

test "design_pages_get handler calls design_model.getPage" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "design_model.getPage") == null) {
        std.debug.print("!! {s} does not call design_model.getPage !!\n", .{HANDLER_PATH});
        return error.ModelCallMissing;
    }
}

test "design_pages_get handler validates page_id + item_id + workspace_id" {
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

test "design_pages_get handler returns 404 on PageNotFound" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "PageNotFound") == null or
        std.mem.indexOf(u8, source, "404") == null)
    {
        std.debug.print("!! {s} does not map PageNotFound to 404 !!\n", .{HANDLER_PATH});
        return error.NotFoundHandlingMissing;
    }
}

test "design_pages_get handler returns 200 on success" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "status_code = 200") == null) {
        std.debug.print("!! {s} does not return 200 on success !!\n", .{HANDLER_PATH});
        return error.StatusCode200Missing;
    }
}