// `set_design_page` LLM tool — file-backed rewrite (the legacy
// `set_design_page` from `design_tools.zig` accepted an inline `html`
// blob stored on `design_pages.html`; the v5 file-backed model has
// no html on pages, only on `design_page_elements`).
//
// Tool contract (spec for Chunk 3 of `2026-07-06-design-fs-rewrite.md`):
//
//   - `item_id` (from chat Workspace Context)
//   - `name`     (page name, e.g. "Login")
//   - `width`    (optional, default 1440)
//   - `height`   (optional, default 1024)
//   - `x`        (optional, default 0)
//   - `y`        (optional, default 0)
//
// The backend `design_model.addPage` is idempotent on
// `(workspace_item_id, name)`, so this tool both creates new pages
// and replaces existing ones in place. The returned xml carries
// the page id (so the LLM can chain element-creation calls) and
// the file-system hint pointing the LLM at where the elements
// will live.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const helpers = nalarcore.helpers;

/// Input structure for set_design_page.
///
/// The agent should pass `item_id` from the active chat's
/// workspace context — see "## Workspace Context" in the system
/// prompt (mirrors `kanban_list_mod.KanbanListInput`).
pub const SetDesignPageInput = struct {
    /// The design workspace item id. From the chat context's
    /// Workspace Context listing (item_id, NOT name).
    item_id: []const u8 = "",
    /// Page name (e.g. "Login"). The page is created (or updated
    /// in place — the same id is returned across idempotent
    /// re-issues) at `<workspace_item.path>/.nalar/design/<name>/`.
    name: []const u8 = "",
    /// Canvas width in pixels. Default 1440 (desktop frame size).
    width: ?i64 = null,
    /// Canvas height in pixels. Default 1024.
    height: ?i64 = null,
    /// Page x offset on the design item's parent canvas. Default 0.
    x: ?i64 = null,
    /// Page y offset on the design item's parent canvas. Default 0.
    y: ?i64 = null,
};

/// Top-level tool definition for the LLM. The description is
/// critical — it explains the file-system-backed model so the LLM
/// knows where elements will live.
pub const set_design_page_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_design_page",
        .description =
            \\Create or update a design page (the canvas for one Figma-style frame). Pages are pure metadata containers — no html is stored on the page itself. After calling set_design_page, the element files live at <workspace_item.path>/.nalar/design/<page_name>/<element_name>.html.
            \\
            \\Idempotent: re-issuing with the same (item_id, name) updates the existing row's width/height/x/y in place (same id is returned). Use list_design_elements (after creating elements via set_design_element) to inspect the current state.
            \\
            \\The item_id must come from the chat context — see the "## Workspace Context" section of the system prompt. Each sibling item is rendered as `- **<name>** (id: <id>, item_type: <type>, path: <path>)` where the id is a backtick-quoted id (e.g. item_1782313125507292140). The id is the **canonical** lookup key — do NOT pass the human-readable name.
            \\
            \\After creating the page, call set_design_element with the returned page_id to add positioned html snippets. A page with 0 elements has an empty canvas — add a "Background" element at z_index=-1 to fill it.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The design workspace item id (NOT name). Find it next to the literal text `id: ` followed by a backtick-quoted id (e.g. item_1782313125507292140) in the Workspace Context listing — pass the value between the backticks, not the human-readable item name.",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Page name (e.g. 'Login', 'Dashboard'). Clear short names — used in file paths.",
                },
                .{
                    .name = "width",
                    .type = "integer",
                    .description = "Canvas width in pixels. Default 1440 (desktop).",
                },
                .{
                    .name = "height",
                    .type = "integer",
                    .description = "Canvas height in pixels. Default 1024.",
                },
                .{
                    .name = "x",
                    .type = "integer",
                    .description = "Page x offset on the design item's canvas. Default 0.",
                },
                .{
                    .name = "y",
                    .type = "integer",
                    .description = "Page y offset on the design item's canvas. Default 0.",
                },
            },
            .required = &.{ "item_id", "name" },
        },
    },
};

/// Escape XML special characters. Mirrors the helper in
/// `set_git_worktree.zig`.
fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }
    return try result.toOwnedSlice(allocator);
}

/// Validate the item_id has the expected prefix (it's a
/// workspace_items row id, not a task/col/page/element id).
/// Returns null on shape OK or an owned error XML slice on a
/// shape mistake.
fn validateItemIdShape(
    allocator: std.mem.Allocator,
    item_id: []const u8,
) !?[]u8 {
    if (item_id.len == 0) {
        return try errorXmlOwned(allocator, "item_id required");
    }
    if (std.mem.startsWith(u8, item_id, "task_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a TASK id (starts with 'task_'). Pass the DESIGN item's item_id instead — find it next to the literal text `id: ` in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "page_") or std.mem.startsWith(u8, item_id, "elem_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' starts with a {s} prefix (a design model id). Pass the DESIGN item's WORKSPACE item_id (the one in the Workspace Context listing) which starts with 'item_'.
        , .{ item_id, if (std.mem.startsWith(u8, item_id, "page_")) "page" else "element" }));
    }
    if (!std.mem.startsWith(u8, item_id, "item_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' has an unrecognized prefix (expected 'item_'). Design tools expect a workspace-scoped item_id from the Workspace Context listing, not a free-form string.
        , .{item_id}));
    }
    return null;
}

fn errorXmlOwned(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, message);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<pages><error>{s}</error></pages>",
        .{escaped},
    );
}

fn errorXmlOwnedFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(raw);
    return errorXmlOwned(allocator, raw);
}

/// Execute the set_design_page tool. Returns an XML string for
/// the LLM.
///
/// Response shape (the `data` field inside `<tool>...</tool>`):
///   <pages>
///     <page>
///       <id>...</id>
///       <workspace_item_id>...</id>
///       <name>...</name>
///       <position>...</position>
///       <width>...</width>
///       <height>...</height>
///       <x>...</x>
///       <y>...</y>
///       <created>true|updated</created>
///       <hint>...</hint>   (only when a new page is created — points at the .nalar/design/<name>/ folder)
///     </page>
///   </pages>
///
/// Errors (encoded as XML so the LLM sees a structured failure):
///   - missing item_id / name
///   - item_id is well-formed but no workspace item of type 'design' exists
///   - DB failure (add, list)
///   - empty name is rejected (NOT NULL column)
pub fn executeSetDesignPageToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SetDesignPageInput,
) ![]u8 {
    // 1. Shape validation.
    if (try validateItemIdShape(allocator, input.item_id)) |err_xml| {
        return err_xml;
    }
    if (input.name.len == 0) {
        return try errorXmlOwned(allocator, "name required");
    }

    // Defaults — match `Migration055AddDesignPagesAndElements`.
    const width = input.width orelse 1440;
    const height = input.height orelse 1024;
    const x = input.x orelse 0;
    const y = input.y orelse 0;

    // 2. Snapshot pre-existing for the action discriminator.
    const pre_existed = blk: {
        const lookup = nalarcore.ai_mod.design_model.listPages(allocator, db, input.item_id) catch {
            break :blk false;
        };
        defer nalarcore.ai_mod.design_model.freePageSummaries(allocator, lookup);
        for (lookup) |p| {
            if (std.mem.eql(u8, p.name, input.name)) break :blk true;
        }
        break :blk false;
    };

    // 3. Idempotent add.
    const new_id = nalarcore.ai_mod.design_model.addPage(
        allocator,
        db,
        input.item_id,
        input.name,
        width,
        height,
        x,
        y,
    ) catch |err| {
        return try errorXmlOwnedFmt(allocator, "DB: addPage failed: {s}", .{@errorName(err)});
    };

    // 4. Re-fetch the page row.
    const all = nalarcore.ai_mod.design_model.listPages(allocator, db, input.item_id) catch |err| {
        return try errorXmlOwnedFmt(allocator, "DB: listPages failed: {s}", .{@errorName(err)});
    };
    defer nalarcore.ai_mod.design_model.freePageSummaries(allocator, all);

    for (all) |p| {
        if (!std.mem.eql(u8, p.name, input.name)) continue;
        const action = if (pre_existed) "updated" else "created";
        return try toXml(
            allocator,
            new_id,
            input.item_id,
            p.workspace_item_id,
            input.name,
            p.position,
            p.width,
            p.height,
            p.x,
            p.y,
            action,
        );
    }

    // Should not happen — addPage succeeded but the row isn't in
    // listPages. Treat as a generic DB error.
    return try errorXmlOwned(allocator, "internal: page row missing after addPage");
}

/// Serialize the (one-page) page result to XML for the LLM.
fn toXml(
    allocator: std.mem.Allocator,
    new_id: []const u8,
    item_id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    position: i64,
    width: i64,
    height: i64,
    x: i64,
    y: i64,
    action: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<pages><page>");

    const esc_new_id = try xmlEscape(allocator, new_id);
    defer allocator.free(esc_new_id);
    try buf.print(allocator, "<id>{s}</id>", .{esc_new_id});

    const esc_item_id = try xmlEscape(allocator, item_id);
    defer allocator.free(esc_item_id);
    try buf.print(allocator, "<item_id>{s}</item_id>", .{esc_item_id});

    const esc_wiid = try xmlEscape(allocator, workspace_item_id);
    defer allocator.free(esc_wiid);
    try buf.print(allocator, "<workspace_item_id>{s}</workspace_item_id>", .{esc_wiid});

    const esc_name = try xmlEscape(allocator, name);
    defer allocator.free(esc_name);
    try buf.print(allocator, "<name>{s}</name>", .{esc_name});

    var pos_buf: [32]u8 = undefined;
    const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{position}) catch "0";
    try buf.print(allocator, "<position>{s}</position>", .{pos_str});

    var width_buf: [32]u8 = undefined;
    const width_str = std.fmt.bufPrint(&width_buf, "{d}", .{width}) catch "0";
    try buf.print(allocator, "<width>{s}</width>", .{width_str});

    var height_buf: [32]u8 = undefined;
    const height_str = std.fmt.bufPrint(&height_buf, "{d}", .{height}) catch "0";
    try buf.print(allocator, "<height>{s}</height>", .{height_str});

    var x_buf: [32]u8 = undefined;
    const x_str = std.fmt.bufPrint(&x_buf, "{d}", .{x}) catch "0";
    try buf.print(allocator, "<x>{s}</x>", .{x_str});

    var y_buf: [32]u8 = undefined;
    const y_str = std.fmt.bufPrint(&y_buf, "{d}", .{y}) catch "0";
    try buf.print(allocator, "<y>{s}</y>", .{y_str});

    const esc_action = try xmlEscape(allocator, action);
    defer allocator.free(esc_action);
    try buf.print(allocator, "<action>{s}</action>", .{esc_action});

    try buf.appendSlice(allocator, "</page></pages>");

    return buf.toOwnedSlice(allocator);
}
