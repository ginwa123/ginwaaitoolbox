//! Static regression checks for `workspaceItemsCreateDesignHandler`.
//! Follows the project convention (per memory
//! `nalar-http-handler-thin-wrapper-pattern.md`): for HTTP handlers,
//! static-contract tests verify the file's shape — function name,
//! required parsing/serialization helpers, status codes, error
//! mapping — without standing up a real GinwaServer. Behavioral
//! coverage lives in `migration_055_test.zig` +
//! `design_model_test.zig` (the model-layer functions that the
//! handler delegates to).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH =
    "src/http_handlers/design_items_create.zig";
const MAIN_PATH = "src/main.zig";
const MOD_PATH = "src/http_handlers/mod.zig";

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

// ─── Contract 1: handler function exists ─────────────────────────────────

test "design_items_create.zig defines pub fn workspaceItemsCreateDesignHandler" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub fn workspaceItemsCreateDesignHandler") == null) {
        std.debug.print(
            "\n!! {s} does not define pub fn workspaceItemsCreateDesignHandler !!\n",
            .{HANDLER_PATH},
        );
        return error.HandlerFunctionMissing;
    }
}

// ─── Contract 2: handler uses parseFromSliceLeaky + valueAlloc ───────────

test "design_items_create.zig uses parseFromSliceLeaky + valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("\n!! {s} does not use parseFromSliceLeaky !!\n", .{HANDLER_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
    // valueAlloc is required because we return the FULL
    // CreateDesignResponse (id, workspace_id, item_type, name, path,
    // position) — not the simpler WorkspaceItemResponse `{id,
    // success}` shape. The frontend pushes the response into the
    // local store entry; without `name` in the response, the
    // sidebar falls back to "Untitled project" (the bug reported on
    // 2026-07-14). Using makeWorkspaceItemResponse (which only
    // returns id+success) is therefore a regression of that fix.
    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print("\n!! {s} does not use std.json.Stringify.valueAlloc !!\n", .{HANDLER_PATH});
        return error.ValueAllocMissing;
    }
    if (std.mem.indexOf(u8, source, "CreateDesignResponse") == null) {
        std.debug.print("\n!! {s} does not define CreateDesignResponse !!\n", .{HANDLER_PATH});
        return error.CreateDesignResponseMissing;
    }
}

// ─── Contract 3: error mapping includes PathRequired ─────────────────────

test "design_items_create.zig maps PathRequired + NameRequired to 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "PathRequired") == null) {
        std.debug.print("\n!! {s} does not define PathRequired error !!\n", .{HANDLER_PATH});
        return error.PathRequiredMissing;
    }
    if (std.mem.indexOf(u8, source, "NameRequired") == null) {
        std.debug.print("\n!! {s} does not define NameRequired error !!\n", .{HANDLER_PATH});
        return error.NameRequiredMissing;
    }
}

// ─── Contract 4: route is registered in main.zig ─────────────────────────

test "POST /api/workspaces/:workspace_id/items/design is registered in src/main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    const route_pattern = "/api/workspaces/:workspace_id/items/design";
    if (std.mem.indexOf(u8, source, route_pattern) == null) {
        std.debug.print(
            "\n!! {s} does not register the {s} route !!\n",
            .{ MAIN_PATH, route_pattern },
        );
        return error.RouteRegistrationMissing;
    }
}

// ─── Contract 5: handler is re-exported in mod.zig ───────────────────────

test "workspaceItemsCreateDesignHandler is re-exported in http_handlers/mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "workspaceItemsCreateDesignHandler") == null) {
        std.debug.print(
            "\n!! {s} does not re-export workspaceItemsCreateDesignHandler !!\n",
            .{MOD_PATH},
        );
        return error.HandlerReExportMissing;
    }
}

// ─── Contract 6: response includes name + workspace_id + path ────────────
//
// The frontend (workspacesStore.addDesignItem) does:
//   const item = await api.createDesign(workspaceId, name, path)
//   ws.items.push({ ...item, tasks: [], design_elements: [] })
//
// For the sidebar to render the right name (not fall back to
// "Untitled project"), the response MUST carry `name`. Same
// requirement for `workspace_id`, `item_type`, `path` so the
// item integrates with the rest of the WorkspaceItem interface.
// Regression test for the 2026-07-14 "Untitled project" bug.

test "CreateDesignResponse fields include name, workspace_id, path, item_type" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Find the struct definition block.
    const struct_start = std.mem.indexOf(u8, source, "pub const CreateDesignResponse = struct") orelse {
        std.debug.print("\n!! {s} does not define CreateDesignResponse !!\n", .{HANDLER_PATH});
        return error.CreateDesignResponseMissing;
    };
    const struct_end = std.mem.indexOfPos(u8, source, struct_start, "};") orelse {
        return error.StructEndMissing;
    };
    const block = source[struct_start..struct_end];

    // Comptime-known field list + patterns. The `:` suffix is
    // appended at comptime (the `++` operator on string literals
    // requires comptime operands) so Zig accepts the call.
    const fields = [_][]const u8{ "name", "workspace_id", "item_type", "path", "id" };
    inline for (fields) |field| {
        const pattern = field ++ ":";
        if (std.mem.indexOf(u8, block, pattern) == null) {
            std.debug.print(
                "\n!! CreateDesignResponse is missing the `{s}:` field !!\n",
                .{field},
            );
            return error.ResponseFieldMissing;
        }
    }
}
