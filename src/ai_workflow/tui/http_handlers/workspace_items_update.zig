const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;

/// PUT /api/workspaces/:workspace_id/items/:item_id - Update a workspace item
///
/// Accepts an optional `path` field. When present, the kanban's
/// `workspace_items.path` is updated to the supplied value (or
/// cleared to NULL when the caller sends an empty string). Used
/// by the kanban "Set project root" banner to backfill the path
/// on existing kanbans that were created before the path field
/// existed on the create endpoint.
pub fn workspaceItemsUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }) });
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Get item_type (required in update)
    const item_type_val = root.get("item_type") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_type required" }) });
    };
    if (item_type_val != .string) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_type must be a string" }) });
    }

    // Optional path. When the key is ABSENT from the body we leave the
    // existing path unchanged (preserves the original updateItemType
    // contract — `PUT /items/:id {item_type: 'kanban'}` still works
    // for callers that don't know about path). When the key is
    // PRESENT:
    //   - non-empty string → UPDATE the path
    //   - empty string      → CLEAR the path (set to NULL)
    //   - null              → CLEAR the path
    // The presence vs absence check is intentional so existing
    // API consumers that send only `item_type` keep working.
    const path_present = root.get("path") != null;
    const path_clear: bool = blk: {
        const v = root.get("path") orelse break :blk false;
        break :blk v == .null or (v == .string and v.string.len == 0);
    };
    const path_value: ?[]const u8 = blk: {
        const v = root.get("path") orelse break :blk null;
        if (v == .null) break :blk null;
        if (v == .string and v.string.len == 0) break :blk null;
        if (v == .string) break :blk v.string;
        break :blk null;
    };

    // Optional name. Mirror the path branch's presence vs absence
    // semantics: when the key is ABSENT we leave the existing name
    // unchanged; when PRESENT:
    //   - non-empty string → UPDATE the name
    //   - empty string      → 400 (the model's column is nullable but
    //                         we treat empty as "you forgot to enter
    //                         anything" — the user retried the rename
    //                         dialog and blanked it; refuse instead of
    //                         writing NULL which breaks KanbanView's
    //                         `{{ item.name }}` rendering).
    //   - null              → 400 (same reason).
    // This makes the contract strict: if you PUT the field, it must be
    // a non-empty string.
    const name_present = root.get("name") != null;
    const name_value: ?[]const u8 = blk: {
        const v = root.get("name") orelse break :blk null;
        if (v == .null) break :blk null;
        if (v == .string and v.string.len == 0) break :blk null;
        if (v == .string) break :blk v.string;
        break :blk null;
    };
    // `name_valid` is true when name is present AND non-empty; the
    // handler uses this to decide whether to UPDATE or 400.
    const name_valid: bool = name_present and name_value != null;

    // Check if item exists first
    const existing = ai_mod.workspace_items.getWorkspaceItem(allocator, sqlite_db, item_id) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch workspace item" }) });
    };

    if (existing == null) {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Workspace item not found" }) });
    }
    defer existing.?.deinit(allocator);

    // If the caller sent `name` but it was null or empty, reject
    // before hitting the DB. Empty names break the UI rendering
    // (`{{ item.name }}` shows nothing).
    if (name_present and !name_valid) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(
                allocator,
                .{ .@"error" = "name must be a non-empty string when present" },
            ),
        });
    }

    // Get the current workspace_id for the update
    const current_workspace_id = existing.?.workspace_id;

    // Update the item — if path is present in the body, run the
    // dedicated path-update SQL (preserves `path` semantics from
    // the create endpoint: NULL for empty / null, the string for
    // a non-empty value). Otherwise the legacy item_type-only
    // update path keeps the existing path column untouched.
    if (path_present and name_valid) {
        // Caller wants BOTH path + name updated. We update name first
        // (separate SQL) then path (separate SQL). Two cheap UPDATEs on
        // an indexed primary-key lookup are cheaper than a JOINed CTE;
        // the model layer keeps the single-column setter shape (see
        // updateWorkspaceItemName's docstring).
        ai_mod.workspace_items.updateWorkspaceItemName(
            allocator, sqlite_db, item_id, name_value.?,
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(
                    allocator,
                    .{ .@"error" = "Failed to update workspace item name" },
                ),
            });
        };
        if (path_clear or path_value == null) {
            ai_mod.workspace_items.updateWorkspaceItemPath(
                allocator, sqlite_db, item_id, null,
            ) catch {
                return res.jsonResponse(.{
                    .status_code = 500,
                    .data = try http_response.makeErrorResponse(
                        allocator,
                        .{ .@"error" = "Failed to clear workspace item path" },
                    ),
                });
            };
        } else {
            ai_mod.workspace_items.updateWorkspaceItemPath(
                allocator, sqlite_db, item_id, path_value.?,
            ) catch {
                return res.jsonResponse(.{
                    .status_code = 500,
                    .data = try http_response.makeErrorResponse(
                        allocator,
                        .{ .@"error" = "Failed to update workspace item path" },
                    ),
                });
            };
        }
    } else if (name_valid) {
        // Name-only update (the rename path). Common case for the
        // KanbanSettingsDialog and KanbanView pencil.
        ai_mod.workspace_items.updateWorkspaceItemName(
            allocator, sqlite_db, item_id, name_value.?,
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(
                    allocator,
                    .{ .@"error" = "Failed to update workspace item name" },
                ),
            });
        };
    } else if (path_present) {
        // Path-only update (preserves the original
        // "PUT /items/:id {item_type: 'kanban'}" path-set behavior).
        // The branch is the same as the old code, but renamed for
        // readability and inlined.
        if (path_clear or path_value == null) {
            ai_mod.workspace_items.updateWorkspaceItemPath(
                allocator, sqlite_db, item_id, null,
            ) catch {
                return res.jsonResponse(.{
                    .status_code = 500,
                    .data = try http_response.makeErrorResponse(
                        allocator,
                        .{ .@"error" = "Failed to clear workspace item path" },
                    ),
                });
            };
        } else {
            ai_mod.workspace_items.updateWorkspaceItemPath(
                allocator, sqlite_db, item_id, path_value.?,
            ) catch {
                return res.jsonResponse(.{
                    .status_code = 500,
                    .data = try http_response.makeErrorResponse(
                        allocator,
                        .{ .@"error" = "Failed to update workspace item path" },
                    ),
                });
            };
        }
    } else {
        // Neither name nor path in body → legacy item_type-only update
        // path keeps the existing columns untouched.
        ai_mod.workspace_items.updateWorkspaceItem(
            allocator, sqlite_db, item_id, current_workspace_id,
            item_type_val.string,
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(
                    allocator,
                    .{ .@"error" = "Failed to update workspace item" },
                ),
            });
        };
    }

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemGetResponse(allocator, .{
        .id = item_id,
        .workspace_id = current_workspace_id,
        .item_type = item_type_val.string,
        // When the body didn't mention path, leave the response
        // field as `null` so callers can distinguish "field not in
        // body" from "field cleared to NULL". The frontend's
        // `WorkspaceItem.path` is a separate concern (it reads the
        // freshly-updated DB row via the GET endpoint, not this
        // PUT response).
        .path = null,
        .created_at = null,
        .updated_at = null,
    }) });
}

