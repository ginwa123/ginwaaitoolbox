//! Static-contract + behavioural tests for the `POST .../elements/group`
//! HTTP handler (2026-07-28-grouped-layers Chunk 3).
//!
//! What this file locks in
//! ───────────────────────
//!   1. Handler parses body with `parseFromSliceLeaky`.
//!   2. useCase requires `child_ids.length >= 2` (BEHAVIOURAL — calls
//!      useCase with crafted inputs, asserts error.TooFewChildren).
//!   3. Handler defaults `name` to "Group" when null.
//!   4. Handler defaults `type` to "group" when null.
//!   5. Handler validates the `type` enum ("group" or "frame" only).
//!   6. Handler calls `design_model.groupElements`.
//!   7. Handler returns 201 with `{parent, children}` envelope.
//!   8. Handler maps `ChildAlreadyParented` to 409.
//!   9. Handler maps `PageNotFound` to 404.
//!  10. Handler maps `BadChildId` to 400.
//!  11. main.zig registers the POST route.
//!  12. mod.zig re-exports `design_elements_group`.
//!
//! Per PR #136 review feedback, contract 2 was rewritten as a behavioural
//! unit test that calls `useCase` directly. The static-grep approach was
//! redundant + brittle (it grepped the source for the substring
//! `child_ids.len < 2` instead of exercising the actual logic). Tests
//! of pure validation paths should CALL the function, not grep for
//! its source. Behavioural coverage of the model side-effects lives
//! in `design_model_group_test.zig`.

const std = @import("std");
const testing = std.testing;
const design_elements_group = @import("design_elements_group.zig");

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_elements_group.zig";
const MAIN_PATH = "src/main.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── Contract 1: handler uses parseFromSliceLeaky ─────────────────────────

test "design_elements_group handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The group-body contract is broken. Switch from `parseFromSlice`\n" ++
                "   to `parseFromSliceLeaky` (the per-request arena reaps strings).\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
}

// ─── Contract 2: requires child_ids.length >= 2 (BEHAVIOURAL) ────────────

test "useCase rejects empty child_ids with TooFewChildren" {
    // We pass `undefined` for the db pointer because the validation
    // runs BEFORE any DB access. If the validation regresses and
    // falls through to `design_model.groupElements`, the undefined
    // pointer deref will crash loudly in debug builds — pointing
    // directly at the regression site.
    const result = design_elements_group.useCase(testing.allocator, undefined, .{
        .page_id = "page_test",
        .workspace_id = "ws_test",
        .child_ids = &.{},
        .name = "My Group",
        .elem_type = .group,
    });
    try testing.expectError(error.TooFewChildren, result);
}

test "useCase rejects single-element child_ids with TooFewChildren" {
    const result = design_elements_group.useCase(testing.allocator, undefined, .{
        .page_id = "page_test",
        .workspace_id = "ws_test",
        .child_ids = &.{"elem_1"},
        .name = "My Group",
        .elem_type = .group,
    });
    try testing.expectError(error.TooFewChildren, result);
}

// ─── Contract 3: defaults name to "Group" ─────────────────────────────────

test "design_elements_group handler defaults name to 'Group' when null" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "\"Group\"") == null) {
        std.debug.print(
            "\n!! {s} does not default name to \"Group\" !!\n" ++
                "   When parsed.name is null, the handler must fall back to\n" ++
                "   the Figma-style canonical name \"Group\".\n",
            .{HANDLER_PATH},
        );
        return error.GroupNameDefaultMissing;
    }
}

// ─── Contract 4: defaults type to "group" ────────────────────────────────

test "design_elements_group handler defaults type to 'group' when null" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "\"group\"") == null) {
        std.debug.print(
            "\n!! {s} does not default type to \"group\" !!\n" ++
                "   When parsed.type is null, the handler must fall back to\n" ++
                "   the non-clipping default (group, not frame).\n",
            .{HANDLER_PATH},
        );
        return error.GroupTypeDefaultMissing;
    }
}

// ─── Contract 5: validates type ("group" or "frame") ──────────────────────

test "design_elements_group handler validates type (group or frame only)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call std.meta.stringToEnum or otherwise reject
    // invalid type strings.
    if (std.mem.indexOf(u8, source, "stringToEnum") == null and
        std.mem.indexOf(u8, source, "InvalidType") == null)
    {
        std.debug.print(
            "\n!! {s} does not validate the type field !!\n" ++
                "   Acceptable values: \"group\" | \"frame\". Invalid → 400.\n",
            .{HANDLER_PATH},
        );
        return error.TypeValidationMissing;
    }
}

// ─── Contract 6: handler calls design_model.groupElements ────────────────

test "design_elements_group handler calls design_model.groupElements" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.groupElements") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.groupElements !!\n" ++
                "   The handler must delegate the actual work to the model.\n",
            .{HANDLER_PATH},
        );
        return error.GroupElementsCallMissing;
    }
}

// ─── Contract 7: returns 201 with {parent, children} envelope ────────────

test "design_elements_group handler returns 201 with parent + children envelope" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    const has_201 = std.mem.indexOf(u8, source, ".status_code = 201") != null;
    const has_parent = std.mem.indexOf(u8, source, "parent") != null;
    const has_children = std.mem.indexOf(u8, source, "children") != null;

    if (!has_201 or !has_parent or !has_children) {
        std.debug.print(
            "\n!! {s} does not return the expected 201 envelope !!\n" ++
                "   Expected: status_code=201, body contains `parent` and `children` keys.\n" ++
                "   Found: 201={}, parent={}, children={}\n",
            .{ HANDLER_PATH, has_201, has_parent, has_children },
        );
        return error.EnvelopeMissing;
    }
}

// ─── Contract 8: maps ChildAlreadyParented to 409 ────────────────────────

test "design_elements_group handler maps ChildAlreadyParented to 409" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.ChildAlreadyParented => 409") == null) {
        std.debug.print(
            "\n!! {s} does not map ChildAlreadyParented to 409 !!\n" ++
                "   Conflict on already-parented children must be 409 (not 400).\n",
            .{HANDLER_PATH},
        );
        return error.AlreadyParentedStatusMissing;
    }
}

// ─── Contract 9: maps PageNotFound to 404 ─────────────────────────────────

test "design_elements_group handler maps PageNotFound to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.PageNotFound => 404") == null) {
        std.debug.print(
            "\n!! {s} does not map PageNotFound to 404 !!\n",
            .{HANDLER_PATH},
        );
        return error.PageNotFoundStatusMissing;
    }
}

// ─── Contract 10: maps BadChildId to 400 ──────────────────────────────────

test "design_elements_group handler maps BadChildId to 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.BadChildId => 400") == null) {
        std.debug.print(
            "\n!! {s} does not map BadChildId to 400 !!\n",
            .{HANDLER_PATH},
        );
        return error.BadChildIdStatusMissing;
    }
}

// ─── Contract 11: main.zig registers the POST route ──────────────────────

test "main.zig registers POST /elements/group route" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    // Match the route registration pattern.
    const has_post = std.mem.indexOf(u8, source, "post(") != null;
    const has_route_suffix = std.mem.indexOf(u8, source, "/elements/group") != null;
    const has_design_elements_group = std.mem.indexOf(u8, source, "designElementsGroupHandler") != null;

    if (!has_post or !has_route_suffix or !has_design_elements_group) {
        std.debug.print(
            "\n!! {s} does not register POST .../elements/group !!\n" ++
                "   post={}, route_suffix={}, handler={}\n",
            .{ HANDLER_PATH, has_post, has_route_suffix, has_design_elements_group },
        );
        return error.RouteMissing;
    }
}

// ─── Contract 12: mod.zig re-exports design_elements_group ───────────────

test "http_handlers/mod.zig re-exports design_elements_group" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_elements_group") == null) {
        std.debug.print(
            "\n!! {s} does not re-export design_elements_group !!\n" ++
                "   Add `pub const design_elements_group = @import(\"design_elements_group.zig\");`.\n",
            .{MOD_PATH},
        );
        return error.ReExportMissing;
    }
}