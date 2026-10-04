const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

/// Process-local monotonic counter for workspace_item id generation.
/// Nanosecond-precision timestamps used previously COULD theoretically
/// collide if the host clock had sub-ns request throughput (macOS
/// fast-path under `test_add_twelve_tasks_across_four_columns`-style
/// tight loops). The counter suffix guarantees uniqueness.
var workspace_item_id_counter: std.atomic.Value(u64) = .init(0);

pub const WorkspaceItemsCreateError = error{
    OutOfMemory,
    InvalidJson,
    MissingBody,
    MissingName,
    NameNotString,
    /// The `name` field is present and a string but, after trimming
    /// leading/trailing ASCII whitespace, is empty. Distinct from
    /// `MissingName` (which fires when the field is absent or
    /// `null`) so the frontend can show a specific error message
    /// ("Name is required") instead of a generic 400. Also distinct
    /// from `NameNotString` so a JSON type mismatch stays
    /// diagnosable. Plan: docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.
    EmptyName,
    MissingPath,
    PathNotString,
    DatabaseError,
};

/// Generate a unique item ID
fn generateItemId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const timestamp_ns = ts.toNanoseconds();
    const counter = workspace_item_id_counter.fetchAdd(1, .seq_cst);
    return std.fmt.allocPrint(allocator, "item_{d}_{d}", .{ timestamp_ns, counter });
}

const WorkspaceItemsCreateResult = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: []const u8,
    path: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    sqlite_db: *pabrikcore.sqlite.SqliteBackend,
    io: std.Io,
    workspace_id: []const u8,
    body: []const u8,
) WorkspaceItemsCreateError!WorkspaceItemsCreateResult {
    if (body.len == 0) return error.MissingBody;

    // Per pabrik-http-handler-thin-wrapper-pattern.md: parseFromSliceLeaky
    // is the correct API for per-request arena allocators.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return error.InvalidJson;
    };
    const root = parsed.object;

    const name_val = root.get("name") orelse return error.MissingName;
    if (name_val != .string) return error.NameNotString;
    // Trim leading/trailing ASCII whitespace and reject empty
    // names. The trim returns a slice into the same backing JSON
    // memory owned by the per-request arena, so no allocation
    // needed. Plan: docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.
    const trimmed_name = std.mem.trim(u8, name_val.string, " \t\n\r");
    if (trimmed_name.len == 0) return error.EmptyName;
    const name = trimmed_name;

    const path_val = root.get("path") orelse return error.MissingPath;
    if (path_val != .string) return error.PathNotString;
    const path = path_val.string;

    var item_type: []const u8 = "folder";
    if (root.get("item_type")) |type_val| {
        if (type_val == .string) {
            item_type = type_val.string;
        }
    }

    const item_id = generateItemId(allocator, io) catch return error.OutOfMemory;

    // Insert with timestamps, item_type, name, path, AND a fresh
    // `position` value. The position is computed as
    // `COALESCE(MAX(position), -1) + 1` scoped to the workspace —
    // the COALESCE handles the empty-workspace case (no rows →
    // MAX is NULL → -1 → position 0). The new item appears at the
    // top of the expanded workspace (ORDER BY position DESC puts
    // the highest position first). The drag-reorder endpoint can
    // later reassign these values. `workspace_id` is bound twice
    // in the args tuple: once for the column, once for the
    // correlated subquery.
    sqlite_db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &[_][]const u8{ item_id, workspace_id, item_type, name, path, workspace_id },
    ) catch return error.DatabaseError;

    return .{
        .id = item_id,
        .workspace_id = workspace_id,
        .item_type = item_type,
        .name = name,
        .path = path,
    };
}

/// POST /api/workspaces/:workspace_id/items - Create a new workspace item
pub fn workspaceItemsCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"workspace_id required\"" });
    }

    const result = useCase(allocator, sqlite_db, ctx.io, workspace_id, req.body) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidJson, error.MissingBody,
            error.MissingName, error.NameNotString,
            error.EmptyName,
            error.MissingPath, error.PathNotString => 400,
            error.DatabaseError, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidJson => "Invalid JSON",
            error.MissingBody => "request body required",
            error.MissingName => "name required",
            error.NameNotString => "name must be a string",
            error.EmptyName => "name required",
            error.MissingPath => "path required",
            error.PathNotString => "path must be a string",
            error.DatabaseError => "Failed to create workspace item",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message}),
        });
    };

    const json_data = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = json_data });
}

// ===== Tests merged from workspace_items_create_empty_name_test.zig (2026-09-11 flatten) =====
// Static regression checks for the empty-name validation in both
// `POST /api/workspaces/:wsId/items` (folder create) and
// `POST /api/workspaces/:wsId/items/kanban` (kanban create).
// 
// Why this file exists
// ────────────────────
// User reported an "empty workspace item with a red border" in the
// sidebar after attempting to create a workspace item. Reproduced:
// a `POST` with `{"name":""}` was accepted with HTTP 201 and an empty
// `name` field persisted. The frontend AddItemDialog disabled the
// submit button when `name.trim()` was empty, so the bug was
// reachable only via non-UI paths (scripts, agent runs, future
// code that forgets the frontend trim) — but the persistence of the
// empty row rendered as a name-less, focused-looking row.
// 
// Three contracts are asserted here via static substring checks
// (matching `workspace_items_create_kanban_test.zig`'s pattern):
// 
//   1. `workspace_items_create.zig` declares an `EmptyName` error
//      variant (so a whitespace-only name can be distinguished from
//      a missing-field name without text-matching the body).
//   2. Both handlers trim leading/trailing ASCII whitespace from the
//      `name` field before INSERTing, so `"  My Project  "` stores
//      `"My Project"` (no surrounding whitespace).
//   3. Both handlers reject empty-after-trim names. The folder
//      handler maps the rejection to a 400 with body `{"error":"name required"}`;
//      the kanban handler maps to its own 400 with the same body
//      string ("name is required").
// 
// Plan: docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const FOLDER_HANDLER_PATH = "src/http_handlers/workspace_items_create.zig";
const KANBAN_HANDLER_PATH = "src/http_handlers/workspace_items_create_kanban.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test` runs). Mirrors
/// `workspace_items_create_kanban_test.zig:readSource`.
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

// ─── Contract 1: folder handler declares `EmptyName` error variant ────────

test "folder create handler declares EmptyName error variant" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FOLDER_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must declare a distinct `EmptyName` variant in its
    // error set so the trimmed-empty case is identifiable (the
    // frontend distinguishes it from a missing field by checking
    // the response body's `error` string).
    if (std.mem.indexOf(u8, source, "EmptyName") == null) {
        std.debug.print(
            "\n!! {s} does not declare EmptyName error variant !!\n" ++
                "   The folder-create handler must distinguish 'name field missing'\n" ++
                "   (MissingName) from 'name present but empty after trim' (EmptyName)\n" ++
                "   so the 400 response surfaces the correct diagnostic. Add\n" ++
                "   `EmptyName,` to the WorkspaceItemsCreateError error set.\n" ++
                "   See docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.\n",
            .{FOLDER_HANDLER_PATH},
        );
        return error.EmptyNameVariantMissing;
    }
}

// ─── Contract 2: folder handler trims the name before INSERT ──────────────

test "folder create handler trims leading/trailing whitespace from name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FOLDER_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `std.mem.trim` on the parsed name slice
    // before INSERTing. Without this, leading/trailing whitespace
    // round-trips through the DB and breaks the sidebar's
    // `.truncate` rendering (a 0-visible-character row followed by
    // a long whitespace gap looks empty in the screenshot even
    // after Task 4's fallback rendering kicks in).
    if (std.mem.indexOf(u8, source, "std.mem.trim") == null) {
        std.debug.print(
            "\n!! {s} does not call std.mem.trim on the name !!\n" ++
                "   The folder-create handler must call `std.mem.trim(u8, name, ...)`\n" ++
                "   (or equivalent) before the INSERT to strip leading/trailing\n" ++
                "   whitespace. Without trimming, '  My Project  ' stores as\n" ++
                "   '  My Project  ' in the DB and renders oddly in the sidebar.\n" ++
                "   See docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.\n",
            .{FOLDER_HANDLER_PATH},
        );
        return error.TrimCallMissing;
    }
}

// ─── Contract 3: folder handler returns 400 + "name required" for EmptyName ─

test "folder create handler maps EmptyName to 400 with 'name required' body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FOLDER_HANDLER_PATH);
    defer allocator.free(source);

    // The handler's error switch must handle EmptyName with status
    // 400 and message "name required". Without this arm, the
    // useCase's EmptyName error would fall through to the generic
    // catch and be serialized as the default error name (e.g.
    // `"error":"EmptyName"`) which the frontend can't render as a
    // user-friendly message.
    const has_status_arm = std.mem.indexOf(u8, source, "error.EmptyName") != null;
    const has_message_arm = std.mem.indexOf(u8, source, "=> \"name required\"") != null;
    if (!has_status_arm or !has_message_arm) {
        std.debug.print(
            "\n!! {s} does not map EmptyName to 400 / 'name required' !!\n" ++
                "   The folder-create handler's catch block must include both:\n" ++
                "     - error.EmptyName  in the status switch (-> 400)\n" ++
                "     - error.EmptyName => \"name required\"  in the message switch\n" ++
                "   Without these, the frontend shows the raw error name (e.g.\n" ++
                "   'EmptyName') instead of a user-friendly message.\n" ++
                "   See docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.\n",
            .{FOLDER_HANDLER_PATH},
        );
        return error.EmptyNameMappingMissing;
    }
}

// ─── Contract 4: kanban handler trims + rejects whitespace-only names ─────

test "kanban create handler trims whitespace and rejects empty-after-trim" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, KANBAN_HANDLER_PATH);
    defer allocator.free(source);

    // The kanban handler must call std.mem.trim AND check the
    // trimmed length. Without the trim, a request of `{"name":"   "}`
    // would create a kanban named `   ` (and the 3 default columns),
    // which would render as an empty row in the sidebar — the same
    // bug class as the folder handler.
    const has_trim = std.mem.indexOf(u8, source, "std.mem.trim") != null;
    const has_len_zero_check_after_trim = std.mem.indexOf(u8, source, ".len == 0") != null;
    if (!has_trim or !has_len_zero_check_after_trim) {
        std.debug.print(
            "\n!! {s} does not trim+reject whitespace-only names !!\n" ++
                "   The kanban-create handler must call `std.mem.trim` on the name\n" ++
                "   and reject whitespace-only names with a 400. This mirrors the\n" ++
                "   folder handler's EmptyName contract. Look for the substring\n" ++
                "   `std.mem.trim(...)` AND `.len == 0`.\n" ++
                "   See docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.\n",
            .{KANBAN_HANDLER_PATH},
        );
        return error.KanbanTrimMissing;
    }
}

// ─── Contract 5: folder handler ref-free — no `allocator.free(trimmed_name)` ─

test "folder create handler does NOT free the trimmed name slice" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FOLDER_HANDLER_PATH);
    defer allocator.free(source);

    // Scope to the impl section only (truncate at the merged-tests
    // banner) so the absence check below doesn't self-match its own
    // comment text in the merged-tests section.
    const impl_end = std.mem.indexOf(u8, source, "// ===== Tests merged from") orelse source.len;
    const impl_source = source[0..impl_end];

    // Defensive assertion: `std.mem.trim` returns a slice into the
    // same backing memory as the input (no allocation), so the
    // handler must NOT call `allocator.free` on the trimmed slice
    // (it'd be a use-after-free since the memory is owned by the
    // per-request arena that the request handler reaps at the
    // end). This regression locks that invariant in.
    //
    // We tolerate any free-pattern that does NOT include the literal
    // substring `allocator.free(trimmed_name` or
    // `allocator.free(trimmed` (which would catch the typo too).
    if (std.mem.indexOf(u8, impl_source, "allocator.free(trimmed_name") != null or
        std.mem.indexOf(u8, impl_source, "allocator.free(trimmed ") != null)
    {
        std.debug.print(
            "\n!! {s} frees the trimmed-name slice — that's a use-after-free !!\n" ++
                "   std.mem.trim returns a slice into the JSON-input backing memory\n" ++
                "   (owned by the per-request arena, reaped by GinwaServer.handle).\n" ++
                "   Calling allocator.free on it would crash in debug builds.\n" ++
                "   Remove the offending `allocator.free(trimmed*)` call.\n" ++
                "   See docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.\n",
            .{FOLDER_HANDLER_PATH},
        );
        return error.TrimmedNameDoubleFree;
    }
}
