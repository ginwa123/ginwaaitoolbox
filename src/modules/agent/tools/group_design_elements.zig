//! LLM tool: `group_elements` — wrap 2+ elements into a new `group`
//! or `frame` parent at the union bounding box of the children.
//!
//! Delegates to `design_model.groupElements` (Phase A — Chunks 2/3 of
//! the grouped-layers plan). The tool validates inputs up-front and
//! re-fetches the parent + each child post-commit so the LLM gets the
//! canonical state in the response.
//!
//! Plan: docs/superpowers/plans/2026-07-28-grouped-layers.md (Chunk 8)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;

/// Input structure for `group_elements` tool.
///
/// `page_id` and `child_ids` are required. `name` defaults to
/// `"Group"` and `type` defaults to `"group"` (non-clipping) — the
/// Figma convention. The wire `type` string is one of `"group"` |
/// `"frame"`; any other value is rejected with a self-correcting
/// error XML.
pub const GroupElementsInput = struct {
    /// The page id (NOT the item_id). The LLM discovers page_ids
    /// via `set_design_page` (the response includes the page id).
    page_id: []const u8 = "",
    /// Child element ids. Must contain at least 2 ids; a single-element
    /// group is not meaningful (and is rejected by the model layer).
    /// All ids must reference elements on the SAME `page_id` and none
    /// may already be parented.
    child_ids: []const []const u8 = &.{},
    /// Name for the new parent element (optional). Defaults to
    /// `"Group"`. Must be unique within the page (the model's on-disk
    /// HTML file is `<page_dir>/<sanitized_name>.html`).
    name: ?[]const u8 = null,
    /// Parent type (optional). One of `"group"` (non-clipping
    /// container) or `"frame"` (clipping container). Defaults to
    /// `"group"`.
    type: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM.
pub const group_design_elements_tool_system_prompt =
    \\## Group Design Elements Tool — Behavior
    \\Use `group_elements` to wrap 2+ elements into a new group/frame parent.
    \\- The parent's bbox is the union of children. Use `group` for non-clipping, `frame` for clipping.
    \\- All children must be on the same page and not already parented.
    \\
;

pub const group_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "group_elements",
        .description =
            \\Wrap 2 or more existing elements into a new `group` (non-clipping container) or `frame` (clipping container) parent. The new parent's geometry is the UNION bounding box of its children: x = min(child.x), y = min(child.y), width = max(child.x + child.width) - min(child.x), height = max(child.y + child.height) - min(child.y).
            \\
            \\You must provide at least 2 child element ids. All children must live on the same `page_id` and none may already be parented to another group or frame (the model rejects nested re-parenting for the first cut).
            \\
            \\Use `type="frame"` when children should be visually clipped to the parent's bounding box (e.g. a card with rounded corners and content overflow); use `type="group"` (the default) when children should render freely inside the parent's bbox without clipping (typical structural grouping like a topbar containing logo + nav + buttons).
            \\
            \\Discover the `page_id` by calling `set_design_page` first — the response includes the page id in the `id="..."` attribute. Discover child element ids from the same `set_design_page` response — each `<element id="...">` block carries an id.
            \\
            \\Returns the new parent's element XML plus one `<child id="..." name="..." parent_id="..."/>` block per child with the freshly assigned parent_id.
            \\
            \\On error, recover by: (1) verify `page_id` from a fresh `set_design_page` call; (2) verify each child_id appears in the same `set_design_page` response (and is not already nested in another group); (3) ensure at least 2 children are selected.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "The page id (NOT the item_id). Find it in the `id=\"...\"` attribute of a previous `set_design_page` response. All children must live on this page.",
                },
                .{
                    .name = "child_ids",
                    .type = "array",
                    .description = "List of 2+ element ids to group together. Each id must reference an element on `page_id`, and none may already be parented. Discover ids via `set_design_page` (each `<element id=\"...\">` block).",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Name for the new parent element (optional). Defaults to \"Group\". Must be unique within the page.",
                },
                .{
                    .name = "type",
                    .type = "string",
                    .description = "Parent type (optional): \"group\" (non-clipping container, the default) or \"frame\" (clipping container).",
                },
            },
            .required = &.{ "page_id", "child_ids" },
        },
        .system_prompt = group_design_elements_tool_system_prompt,
    },
};

/// Escape XML special characters. Mirrors the helper in
/// `update_design_element.zig` (duplicated locally to keep this tool
/// file self-contained).
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

/// Generate an error XML response. The error body is wrapped in
/// `<group_elements><error>...</error></group_elements>` so the tool
/// dispatcher can detect it via `<error>` substring search.
pub fn errorXml(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<group_elements><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></group_elements>");
    return try xml.toOwnedSlice(allocator);
}

/// Same as `errorXml` but TAKES OWNERSHIP of `error_msg` and frees it.
pub fn errorXmlOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<group_elements><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></group_elements>");
    return try xml.toOwnedSlice(allocator);
}

/// Parse the optional `type` string into an `ElementType` enum.
/// Returns null when the string is null (use the default); returns
/// the parsed enum on success. The string is restricted to
/// `"group" | "frame"` — any other value, including the 4 leaf types
/// (rectangle, ellipse, text, image), is rejected with
/// `error.InvalidGroupType`.
fn parseOptionalGroupType(type_str: ?[]const u8) !?design_model.ElementType {
    const t = type_str orelse return null;
    if (std.mem.eql(u8, t, "group")) return .group;
    if (std.mem.eql(u8, t, "frame")) return .frame;
    return error.InvalidGroupType;
}

/// Validate `page_id` is non-empty and has the right `page_`
/// prefix. Returns null when shape is correct, or an error XML on
/// mismatch.
fn validatePageIdShape(allocator: std.mem.Allocator, page_id: []const u8) !?[]u8 {
    if (page_id.len == 0) {
        return try errorXml(allocator, "page_id is required (find it in the `id=\"...\"` attribute of a previous set_design_page response)");
    }
    if (std.mem.startsWith(u8, page_id, "item_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\page_id '{s}' looks like an ITEM id (starts with 'item_'). Pass the PAGE id instead — find it in the `id="..."` attribute of a `set_design_page` response.
        , .{page_id}));
    }
    if (std.mem.startsWith(u8, page_id, "elem_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\page_id '{s}' looks like an ELEMENT id (starts with 'elem_'). Pass the PAGE id instead.
        , .{page_id}));
    }
    if (!std.mem.startsWith(u8, page_id, "page_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\page_id '{s}' has an unrecognized prefix (expected 'page_'). group_elements expects a page_id from a previous set_design_page response.
        , .{page_id}));
    }
    return null;
}

/// Validate `child_ids` is non-empty, has at least 2 elements, and
/// every entry has the right `elem_` prefix. Returns null when shape
/// is correct, or an error XML on mismatch.
fn validateChildIdsShape(allocator: std.mem.Allocator, child_ids: []const []const u8) !?[]u8 {
    if (child_ids.len == 0) {
        return try errorXml(allocator, "child_ids is required and must contain at least 2 element ids (a single-element group is not meaningful)");
    }
    if (child_ids.len < 2) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\child_ids must contain at least 2 element ids (got {d}). Select more elements before grouping.
        , .{child_ids.len}));
    }
    for (child_ids) |cid| {
        if (cid.len == 0) {
            return try errorXml(allocator, "child_ids contains an empty string; every entry must be a non-empty element id");
        }
        if (std.mem.startsWith(u8, cid, "page_")) {
            return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
                \\child_ids entry '{s}' looks like a PAGE id (starts with 'page_'). Pass the ELEMENT id instead — find it in the `id="..."` attribute of an `<element>` block in a `set_design_page` response.
            , .{cid}));
        }
        if (std.mem.startsWith(u8, cid, "item_")) {
            return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
                \\child_ids entry '{s}' looks like an ITEM id (starts with 'item_'). Pass the ELEMENT id instead.
            , .{cid}));
        }
        if (!std.mem.startsWith(u8, cid, "elem_")) {
            return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
                \\child_ids entry '{s}' has an unrecognized prefix (expected 'elem_'). group_elements expects element ids from a previous set_design_page response.
            , .{cid}));
        }
    }
    return null;
}

/// Render the parent element XML block. Same shape as
/// `add_design_element.elementToXml` but scoped to the parent fields
/// the LLM needs (id, name, type, geometry + parent_id which is
/// always empty for the new root parent).
fn parentToXml(allocator: std.mem.Allocator, elem: design_model.DesignElement) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<parent");

    const eid = try xmlEscape(allocator, elem.id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, " id=\"");
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "\"");

    const ename = try xmlEscape(allocator, elem.name);
    defer allocator.free(ename);
    try xml.appendSlice(allocator, " name=\"");
    try xml.appendSlice(allocator, ename);
    try xml.appendSlice(allocator, "\"");

    const etype = try xmlEscape(allocator, elem.elem_type);
    defer allocator.free(etype);
    try xml.appendSlice(allocator, " type=\"");
    try xml.appendSlice(allocator, etype);
    try xml.appendSlice(allocator, "\"");

    try appendIntAttr(&xml, allocator, "x", elem.x);
    try appendIntAttr(&xml, allocator, "y", elem.y);
    try appendIntAttr(&xml, allocator, "width", elem.width);
    try appendIntAttr(&xml, allocator, "height", elem.height);

    // The new parent is a top-level element — parent_id is always
    // empty for the root. Render as an explicit empty attribute so
    // the LLM can see it.
    try xml.appendSlice(allocator, " parent_id=\"\"");

    try xml.appendSlice(allocator, "/>");
    return try xml.toOwnedSlice(allocator);
}

/// Render a single child block. Minimal shape (id, name, parent_id)
/// — the LLM doesn't need the child's geometry here because that
/// information is unchanged by the grouping operation (the child's
/// x/y/width/height are preserved on disk; the parent is just a new
/// container around them).
fn childToXml(allocator: std.mem.Allocator, elem: design_model.DesignElement) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<child");

    const eid = try xmlEscape(allocator, elem.id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, " id=\"");
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "\"");

    const ename = try xmlEscape(allocator, elem.name);
    defer allocator.free(ename);
    try xml.appendSlice(allocator, " name=\"");
    try xml.appendSlice(allocator, ename);
    try xml.appendSlice(allocator, "\"");

    if (elem.parent_id.len > 0) {
        const epid = try xmlEscape(allocator, elem.parent_id);
        defer allocator.free(epid);
        try xml.appendSlice(allocator, " parent_id=\"");
        try xml.appendSlice(allocator, epid);
        try xml.appendSlice(allocator, "\"");
    } else {
        try xml.appendSlice(allocator, " parent_id=\"\"");
    }

    try xml.appendSlice(allocator, "/>");
    return try xml.toOwnedSlice(allocator);
}

fn appendIntAttr(
    xml: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: i64,
) !void {
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
    try xml.appendSlice(allocator, " ");
    try xml.appendSlice(allocator, name);
    try xml.appendSlice(allocator, "=\"");
    try xml.appendSlice(allocator, str);
    try xml.appendSlice(allocator, "\"");
}

/// Execute the `group_elements` tool. Returns an XML string for the
/// LLM.
///
/// On success, the response shape is:
/// ```xml
/// <group_elements>
///   <parent id="elem_..." name="..." type="group|frame" x=".." y=".." width=".." height=".." parent_id="" />
///   <child id="elem_..." name="..." parent_id="elem_NEW_ID" />
///   ...
/// </group_elements>
/// ```
///
/// On error, the response is wrapped in
/// `<group_elements><error>...</error></group_elements>`.
pub fn executeGroupElementsToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: GroupElementsInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validatePageIdShape(allocator, input.page_id)) |e| return e;
    if (try validateChildIdsShape(allocator, input.child_ids)) |e| return e;

    // 1. Parse the optional type string. parseOptionalGroupType
    //    returns:
    //      null → "use default" (string was null) → caller applies .group
    //      enum value → parsed successfully
    //      error.InvalidGroupType → not one of the 2 valid container types
    const parsed_type = parseOptionalGroupType(input.type) catch |err| {
        if (err == error.InvalidGroupType) {
            return try errorXml(allocator,
                "type must be one of: group, frame");
        }
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: parseOptionalGroupType failed: {s}", .{@errorName(err)}));
    };

    // 2. Apply the Figma defaults (name="Group", type=group).
    const parent_name: []const u8 = if (input.name) |n| (if (n.len == 0) "Group" else n) else "Group";
    const parent_type: design_model.ElementType = parsed_type orelse .group;

    // 3. Call groupElements. Returns the new element_id on success;
    //    errors are mapped to wire XML below.
    const new_id = design_model.groupElements(allocator, db, .{
        .page_id = input.page_id,
        .child_ids = input.child_ids,
        .parent_name = parent_name,
        .parent_type = parent_type,
    }) catch |err| switch (err) {
        error.PageNotFound => return try errorXml(allocator, "page_id does not match any design page — call set_design_page first"),
        error.BadChildId => return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "child_id is invalid — one of the child_ids ({s}) does not match any design element. Re-fetch the page via set_design_page to get fresh ids.", .{input.child_ids[0]})),
        error.ChildAcrossDifferentPages => return try errorXml(allocator, "one of the child_ids lives on a different page than page_id. All children must be on the same page as the new parent"),
        error.ChildAlreadyParented => return try errorXml(allocator, "one of the child_ids is already parented to another group or frame. group_elements does not support nested re-parenting in the first cut"),
        error.ItemPathMissing => return try errorXml(allocator, "the design item has no path; set one via the design item dialog"),
        error.FileWriteFailed => return try errorXml(allocator, "could not write the group HTML file to disk (permission denied or out of space)"),
        else => return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: groupElements failed: {s}", .{@errorName(err)})),
    };
    defer allocator.free(new_id);

    // 4. Re-fetch the parent + each reparented child so the response
    //    carries the canonical state (with timestamps + parent_id).
    const parent = design_model.getElement(allocator, db, new_id) catch |err| {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement(parent) failed: {s}", .{@errorName(err)}));
    };
    defer design_model.freeElement(allocator, parent);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<group_elements>");
    const parent_xml = try parentToXml(allocator, parent);
    defer allocator.free(parent_xml);
    try xml.appendSlice(allocator, parent_xml);

    for (input.child_ids) |cid| {
        const child = design_model.getElement(allocator, db, cid) catch |err| {
            return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement(child='{s}') failed: {s}", .{ cid, @errorName(err) }));
        };
        defer design_model.freeElement(allocator, child);
        const child_xml = try childToXml(allocator, child);
        defer allocator.free(child_xml);
        try xml.appendSlice(allocator, child_xml);
    }

    try xml.appendSlice(allocator, "</group_elements>");
    return try xml.toOwnedSlice(allocator);
}

const testing = std.testing;
const group_elements = @import("group_design_elements.zig");
const text_normalize = @import("helpers").text_normalize;

const TOOL_PATH = "src/modules/agent/tools/group_design_elements.zig";
const TOOL_REGISTRY_PATH = "src/agentic_loop/tools_equipped.zig"; // legacy alias; tool_registry.zig was deleted 2026-08-06 — see plan
const TOOL_EXEC_PATH = "src/agentic_loop/tools_exec_group_elements.zig";
const TOOLS_EQUIPPED_PATH = "src/agentic_loop/tools_equipped.zig";
const TOOLS_ZIG_PATH = "src/agentic_loop/tools.zig";
const ROOT_PATH = "src/root.zig";

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

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── Static source-check tests ────────────────────────────────────────────

test "group_elements tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"group_elements\"")) {
        std.debug.print("!! group_design_elements.zig does not define the tool with .name = \"group_elements\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "group_elements description mentions frame vs group" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must disambiguate `group` (non-clipping) from
    // `frame` (clipping) and tell the LLM the 2+ children requirement.
    if (!contains(source, "frame") or !contains(source, "group")) {
        std.debug.print("!! group_elements description does not mention both frame and group !!\n", .{});
        return error.FrameGroupHintMissing;
    }
}

test "group_elements description mentions 2+ children requirement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "2") or !contains(source, "child")) {
        std.debug.print("!! group_elements description does not mention the 2+ children requirement !!\n", .{});
        return error.TwoChildrenHintMissing;
    }
}

test "group_elements input struct has all fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    const fields = [_][]const u8{
        "page_id: []const u8",
        "child_ids: []const []const u8",
        "name: ?[]const u8",
        "type: ?[]const u8",
    };
    for (fields) |f| {
        if (!contains(source, f)) {
            std.debug.print("!! GroupElementsInput is missing field '{s}' !!\n", .{f});
            return error.FieldMissing;
        }
    }
}

test "group_elements description references set_design_page as the source of page_id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "set_design_page")) {
        std.debug.print("!! group_elements description does not reference set_design_page as the source of page_id !!\n", .{});
        return error.PageIdSourceMissing;
    }
}

// ─── Static wiring tests ─────────────────────────────────────────────────

test "tools_equipped.zig imports group_design_elements module" {
    // After deduplication of `UNIFIED_TOOL_REGISTRY` (2026-08-06), the
    // registry body lives in `tools_equipped.zig` and no longer lives
    // in `tool_registry.zig`. This test now reads the imports from
    // the canonical home.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "const group_design_elements_mod = nalarcore.group_design_elements;")) {
        std.debug.print("!! tools_equipped.zig does not bind group_design_elements_mod = nalarcore.group_design_elements !!\n", .{});
        return error.GroupElementsModBindingMissing;
    }
}

test "agentic_loop defines execGroupElements" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execGroupElements(")) {
        std.debug.print("!! tools_exec_group_elements.zig does not define pub fn execGroupElements !!\n", .{});
        return error.ExecGroupElementsMissing;
    }
}

test "tools.zig re-exports execGroupElements" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_ZIG_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub const execGroupElements = @import(\"tools_exec_group_elements.zig\").execGroupElements")) {
        std.debug.print("!! tools.zig does not re-export execGroupElements !!\n", .{});
        return error.ExecGroupElementsReExportMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains group_elements entry" {
    // The registry body moved from `tool_registry.zig` (deleted) to
    // `tools_equipped.zig` (canonical home) on 2026-08-06. The test
    // now reads from the canonical file. tools_equipped.zig imports
    // `tools = @import("tools.zig")` directly, so the `.exec` binding
    // is `tools.execGroupElements` (NOT `agentic_loop_mod.tools.execGroupElements`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"group_elements\"")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the group_elements entry !!\n", .{});
        return error.RegistryEntryMissing;
    }
    if (!contains(source, ".exec = tools.execGroupElements")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = tools.execGroupElements !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = group_design_elements_mod.group_design_element_tool")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def binding !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains group_design_element tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "group_design_elements_mod.group_design_element_tool,")) {
        std.debug.print("!! tools_equipped.zig comptime list is missing group_design_elements_mod.group_design_element_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "root.zig exposes group_design_elements module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, ROOT_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub const group_design_elements = @import(\"modules/agent/tools/group_design_elements.zig\");")) {
        std.debug.print("!! root.zig does not expose group_design_elements as a top-level module !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}

// ─── XML serialization ───────────────────────────────────────────────────

test "errorXml on missing field returns <group_elements><error>...</error></group_elements>" {
    const alloc = testing.allocator;
    const xml = try group_elements.errorXml(alloc, "page_id is required");
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<group_elements>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</group_elements>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_id is required"));
}

test "errorXmlOwned takes ownership and frees the message" {
    const alloc = testing.allocator;
    const msg = try alloc.dupe(u8, "child_ids must be at least 2 elements");
    const xml = try group_elements.errorXmlOwned(alloc, msg);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "child_ids must be at least 2 elements"));
    // msg has been freed by errorXmlOwned — using `msg` here would
    // be UAF. The test passes by virtue of the closure capturing the
    // allocation lifecycle.
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the v6 design schema + one page +
/// three rectangle elements ("card-a", "card-b", "card-c") all on the
/// same page. Returns the DB handle + page_id so tests can call
/// group_elements on them.
fn setupDbWithThreeElements() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []u8,
    page_id: []u8,
    element_a: []u8,
    element_b: []u8,
    element_c: []u8,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL, name TEXT, path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    description TEXT NOT NULL DEFAULT '')
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    workspace_item_task_id TEXT,
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    UNIQUE (workspace_item_id, name),
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '',
        \\    x INTEGER NOT NULL DEFAULT 0, y INTEGER NOT NULL DEFAULT 0,
        \\    width INTEGER NOT NULL DEFAULT 375, height INTEGER NOT NULL DEFAULT 667,
        \\    z_index INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        \\    type TEXT NOT NULL DEFAULT 'rectangle', rotation REAL NOT NULL DEFAULT 0,
        \\    fill TEXT NOT NULL DEFAULT '', stroke TEXT NOT NULL DEFAULT '',
        \\    stroke_width INTEGER NOT NULL DEFAULT 0,
        \\    corner_radius INTEGER NOT NULL DEFAULT 0, opacity REAL NOT NULL DEFAULT 1.0,
        \\    text_content TEXT NOT NULL DEFAULT '', text_style TEXT NOT NULL DEFAULT '',
        \\    image_url TEXT NOT NULL DEFAULT '', parent_id TEXT,
        \\    created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path: []const u8 = tmpdir_buf[0..tmpdir_len];

    const item_id_str = "item_design_group_1";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES (?, 'ws_test', 'design', 'Test Design', ?)",
        &.{ item_id_str, tmpdir_path });

    const page_id_str = "page_test_group_1";
    try db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name, width, height, position) " ++
        "VALUES (?, ?, 'Login', 1440, 1024, 0)",
        &.{ page_id_str, item_id_str });

    const element_a_str = "elem_a";
    try db.exec(alloc,
        "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, z_index, position, type, fill) " ++
        "VALUES (?, ?, 'card-a', '/tmp/a.html', 10, 20, 100, 50, 0, 0, 'rectangle', '#ffffff')",
        &.{ element_a_str, page_id_str });

    const element_b_str = "elem_b";
    try db.exec(alloc,
        "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, z_index, position, type, fill) " ++
        "VALUES (?, ?, 'card-b', '/tmp/b.html', 200, 300, 100, 50, 1, 1, 'rectangle', '#ffffff')",
        &.{ element_b_str, page_id_str });

    const element_c_str = "elem_c";
    try db.exec(alloc,
        "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, z_index, position, type, fill) " ++
        "VALUES (?, ?, 'card-c', '/tmp/c.html', 400, 600, 100, 50, 2, 2, 'rectangle', '#ffffff')",
        &.{ element_c_str, page_id_str });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = try alloc.dupe(u8, item_id_str),
        .page_id = try alloc.dupe(u8, page_id_str),
        .element_a = try alloc.dupe(u8, element_a_str),
        .element_b = try alloc.dupe(u8, element_b_str),
        .element_c = try alloc.dupe(u8, element_c_str),
    };
}

test "executeGroupElementsToString wraps two elements into a parent with union bbox" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);

    // Outer envelope.
    try testing.expect(std.mem.startsWith(u8, xml, "<group_elements>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</group_elements>"));
    // Parent rendered with the union bbox (10, 20, 290, 330).
    try testing.expect(contains(xml, "<parent"));
    try testing.expect(contains(xml, "name=\"Group\""));
    try testing.expect(contains(xml, "type=\"group\""));
    try testing.expect(contains(xml, "x=\"10\""));
    try testing.expect(contains(xml, "y=\"20\""));
    try testing.expect(contains(xml, "width=\"290\""));
    try testing.expect(contains(xml, "height=\"330\""));
    // Both children rendered with parent_id pointing to the new parent.
    try testing.expect(contains(xml, "<child"));
    try testing.expect(contains(xml, "id=\"elem_a\""));
    try testing.expect(contains(xml, "id=\"elem_b\""));
    try testing.expect(contains(xml, "name=\"card-a\""));
    try testing.expect(contains(xml, "name=\"card-b\""));
    // The parent_id must appear 2 times with the elem_ prefix
    // (once per child render — note: the parent block also renders
    // `parent_id=""` so a naive count of `parent_id="` would be 3).
    const parent_id_with_id = std.mem.count(u8, xml, "parent_id=\"elem_");
    try testing.expect(parent_id_with_id == 2);
    try testing.expect(!contains(xml, "<error>"));
}

test "executeGroupElementsToString honours custom name and type=frame" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_b, s.element_c },
        .name = "Kanban-view",
        .type = "frame",
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(contains(xml, "name=\"Kanban-view\""));
    try testing.expect(contains(xml, "type=\"frame\""));
    // Union bbox of (200,300,500,650) and (400,600,500,650) →
    // (200, 300, 300, 350).
    try testing.expect(contains(xml, "x=\"200\""));
    try testing.expect(contains(xml, "y=\"300\""));
    try testing.expect(contains(xml, "width=\"300\""));
    try testing.expect(contains(xml, "height=\"350\""));
}

test "executeGroupElementsToString returns error XML when page_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = "",
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_id"));
}

test "executeGroupElementsToString returns error XML when child_ids is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{},
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "child_ids"));
}

test "executeGroupElementsToString returns error XML when child_ids has only 1 element" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{s.element_a},
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "child_ids"));
}

test "executeGroupElementsToString returns error XML when type is invalid" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, s.element_b },
        .type = "rectangle",
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "type"));
}

test "executeGroupElementsToString returns error XML when page_id does not exist" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = "page_does_not_exist",
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_id"));
}

test "executeGroupElementsToString returns error XML when a child_id does not exist" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, "elem_does_not_exist" },
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
}

test "executeGroupElementsToString returns error XML when a child is already parented" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    // Pre-parent element_b to a non-existent parent (still parented
    // in the DB). The model rejects children whose parent_id is set.
    try s.db.exec(alloc,
        "UPDATE design_page_elements SET parent_id = 'elem_orphan' WHERE id = ?",
        &.{s.element_b});

    const input = group_elements.GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const xml = try group_elements.executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "parented"));
}
