//! Static regression checks for `POST /kanban/copy_spec_from`.
//!
//! Mirrors the pattern from `kanban_columns_create_test.zig`:
//! read the source file, grep for required substrings that prove
//! the contract holds. The endpoint is too thin to warrant a
//! behavioral test (the model helpers in `kanban_model.zig` are
//! already covered by the in-memory `kanban_copy_spec_test.zig`).
//!
//! Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
//!   (Chunk 2, Task 2.2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/kanban_copy_spec.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

test "kanban_copy_spec handler parses body with parseFromSliceLeaky" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, HANDLER_PATH);
    defer alloc.free(source);
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("\n!! {s} does not use parseFromSliceLeaky !!\n", .{HANDLER_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
}

test "kanban_copy_spec handler gates on item_type=kanban" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, HANDLER_PATH);
    defer alloc.free(source);
    // The handler must call getWorkspaceItem + check item_type==kanban
    // (the canonical guard from the kanban endpoint family).
    if (std.mem.indexOf(u8, source, "item_type") == null or
        std.mem.indexOf(u8, source, "\"kanban\"") == null)
    {
        std.debug.print(
            "\n!! {s} does not check item_type='kanban' !!\n",
            .{HANDLER_PATH},
        );
        return error.KanbanTypeGuardMissing;
    }
}

test "kanban_copy_spec handler rejects self-copy" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, HANDLER_PATH);
    defer alloc.free(source);
    // The use-case rejects item_id == source_item_id with
    // error.SourceItemIdRequired. The handler maps that to 400.
    if (std.mem.indexOf(u8, source, "SourceItemIdRequired") == null) {
        std.debug.print(
            "\n!! {s} does not reject self-copy !!\n",
            .{HANDLER_PATH},
        );
        return error.SelfCopyGuardMissing;
    }
}

test "kanban_copy_spec handler emits SSE for created and deleted columns" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, HANDLER_PATH);
    defer alloc.free(source);
    if (std.mem.indexOf(u8, source, "onEventSendKanbanColumn") == null or
        std.mem.indexOf(u8, source, ".action = \"created\"") == null or
        std.mem.indexOf(u8, source, ".action = \"deleted\"") == null)
    {
        std.debug.print(
            "\n!! {s} does not emit kanban_column SSE for both delete + create !!\n",
            .{HANDLER_PATH},
        );
        return error.SseEmitMissing;
    }
}

test "kanban_copy_spec handler returns KanbanColumnResponse envelope" {
    const alloc = testing.allocator;
    const source = try readSource(alloc, HANDLER_PATH);
    defer alloc.free(source);
    if (std.mem.indexOf(u8, source, "makeKanbanColumnResponse") == null or
        std.mem.indexOf(u8, source, "Envelop") == null)
    {
        std.debug.print(
            "\n!! {s} does not return a {{columns, count}} envelope !!\n",
            .{HANDLER_PATH},
        );
        return error.EnvelopeMissing;
    }
}
