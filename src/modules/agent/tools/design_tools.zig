//! LLM tools for the Design Mode feature (item_type='design').
//!
//! Three tools:
//!   - `set_design_page`   — create or replace a page's HTML
//!   - `delete_design_page` — remove a page
//!   - `list_design_pages`  — return the page list (names + positions,
//!                            no HTML — the LLM only needs to know
//!                            what's there to address pages by name)
//!
//! Each tool has:
//!   - An `AgentTool` definition (the OpenAI-style function schema the
//!     LLM sees in its system prompt's tool list).
//!   - A `*_to_string` execution function the tool_registry dispatches.
//!     Returns plain text — the LLM sees the result and the user sees
//!     the SSE-driven canvas update side-effect.
//!
//! Errors are returned as `<error>...</error>` XML so the LLM can
//! self-correct on bad input (mirrors the kanban_list / kanban_move_task
//! pattern).
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 3).

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;
const on_event_sent_design = nalarcore.ai_mod.on_event_sent_design;
const helpers = nalarcore.helpers;
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// 5 MB hard cap on a single page's HTML body. Mirrors the
/// `design_pages_update` HTTP handler's limit so the tool can't
/// write a page that the HTTP layer would later reject.
const MAX_HTML_BYTES: usize = 5 * 1024 * 1024;

// =====================================================================
// set_design_page
// =====================================================================

pub const SetDesignPageInput = struct {
    /// The workspace item id of the target design canvas. Should match
    /// the active item_id in the chat context's `## Workspace Context`.
    item_id: []const u8 = "",
    /// Human-readable page label ("Login", "Dashboard"). The unique
    /// index `idx_design_pages_item_name` makes this idempotent — re-issuing
    /// with the same name replaces the existing page's HTML in place.
    page_name: []const u8 = "",
    /// Full HTML body. The LLM is expected to produce a complete
    /// `<!doctype html>...</html>` document including inline `<style>`
    /// and `<script>` tags as needed. The iframe sandbox will render it
    /// verbatim on the user's canvas.
    html: []const u8 = "",
};

pub const set_design_page_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_design_page",
        .description =
            \\Create or replace a page on a design canvas (item_type='design'). Idempotent on (item_id, page_name): re-issuing with the same name replaces the existing page's HTML in place. The html field MUST be a complete HTML document (starts with `<!doctype html>` and ends with `</html>`); the canvas renders it verbatim in a sandboxed iframe. After this call, other connected clients see the page update via SSE.
            \\
            \\The item_id parameter must come from the chat context — see the "## Workspace Context" section of the system prompt. Use list_design_pages first to see what pages already exist on the canvas, so you don't accidentally overwrite a page the user wanted to keep. The page_name must not contain "/" or null bytes; the unique index rejects duplicates with <error>.
            ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The design workspace item id (NOT the name). Find it next to the literal text `id: ` followed by a backtick-quoted id in the Workspace Context listing — pass the value between the backticks, not the human-readable item name.",
                },
                .{
                    .name = "page_name",
                    .type = "string",
                    .description = "Human-readable page label, e.g. 'Login', 'Dashboard', 'Settings'. Must be unique within the design item; duplicates trigger a 409-like <error> response.",
                },
                .{
                    .name = "html",
                    .type = "string",
                    .description = "Full HTML document. Must be a complete page starting with `<!doctype html>` (or `<html>`). Inline <style> and <script> are allowed but the script runs sandboxed (no parent storage access).",
                },
            },
            .required = &.{ "item_id", "page_name", "html" },
        },
    },
};

pub fn executeSetDesignPageToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SetDesignPageInput,
) ![]u8 {
    if (input.item_id.len == 0) {
        return allocator.dupe(u8, "<error>item_id is required</error>") catch unreachable;
    }
    if (input.page_name.len == 0) {
        return allocator.dupe(u8, "<error>page_name is required</error>") catch unreachable;
    }
    if (std.mem.indexOfAny(u8, input.page_name, "/\x00") != null) {
        return std.fmt.allocPrint(allocator, "<error>page_name must not contain '/' or null bytes (got: {s})</error>", .{input.page_name}) catch unreachable;
    }
    if (input.html.len > MAX_HTML_BYTES) {
        return std.fmt.allocPrint(allocator, "<error>html exceeds 5 MB limit (got {d} bytes)</error>", .{input.html.len}) catch unreachable;
    }

    // Resolve workspace_id from the parent item. The SSE event bus
    // scopes events by workspace_id; without it the frontend would
    // drop the event because no client subscribes to a "" key.
    const page_id = design_model.addPage(allocator, db, input.item_id, input.page_name, input.html) catch |err| {
        return std.fmt.allocPrint(allocator, "<error>failed to set design page: {s}</error>", .{@errorName(err)}) catch unreachable;
    };
    defer allocator.free(page_id);

    // Re-fetch to get the persisted row (timestamps + html that was
    // actually written) so the SSE event payload is faithful.
    const page = design_model.getPage(allocator, db, page_id) catch |err| {
        return std.fmt.allocPrint(allocator, "<error>page disappeared after insert: {s}</error>", .{@errorName(err)}) catch unreachable;
    };
    defer design_model.freePageFull(allocator, page);

    const workspace_id = try resolveItemWorkspaceId(allocator, db, input.item_id);

    // Fire-and-forget SSE. Other connected clients on the same canvas
    // see the page appear / refresh.
    on_event_sent_design.onEventSendDesignPageUpdated(allocator, .{
        .action = "updated",
        .workspace_id = workspace_id,
        .item_id = input.item_id,
        .page = .{
            .id = page.id,
            .workspace_item_id = page.workspace_item_id,
            .name = page.name,
            .html = page.html,
            .position = page.position,
            .created_at = page.created_at,
            .updated_at = page.updated_at,
        },
    });

    return std.fmt.allocPrint(allocator,
        \\<design_page>
        \\<page id="{s}" name="{s}" position="{d}" />
        \\<status>set</status>
        \\</design_page>
    , .{ page.id, page.name, page.position }) catch unreachable;
}

// =====================================================================
// delete_design_page
// =====================================================================

pub const DeleteDesignPageInput = struct {
    item_id: []const u8 = "",
    page_name: []const u8 = "",
};

pub const delete_design_page_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "delete_design_page",
        .description =
            \\Delete a page from a design canvas. Idempotent: deleting a non-existent page returns success with `deleted=false`. Use list_design_pages first to see what pages exist. After this call, other connected clients see the tab disappear via SSE.
            \\
            \\The item_id parameter must come from the chat context.
            ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The design workspace item id (NOT the name). Find it in the Workspace Context listing.",
                },
                .{
                    .name = "page_name",
                    .type = "string",
                    .description = "The exact page_name to delete (case-sensitive). List first to verify.",
                },
            },
            .required = &.{ "item_id", "page_name" },
        },
    },
};

pub fn executeDeleteDesignPageToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: DeleteDesignPageInput,
) ![]u8 {
    if (input.item_id.len == 0) {
        return allocator.dupe(u8, "<error>item_id is required</error>") catch unreachable;
    }
    if (input.page_name.len == 0) {
        return allocator.dupe(u8, "<error>page_name is required</error>") catch unreachable;
    }

    // Look up the page id by (item_id, page_name) for the SSE event.
    var page_id_buf: [256]u8 = undefined;
    var page_id: []const u8 = "";
    const found = findPageByName(allocator, db, input.item_id, input.page_name, &page_id_buf, &page_id);
    if (!found) {
        // Idempotent — return success, just with deleted=false.
        return std.fmt.allocPrint(allocator,
            \\<design_page>
            \\<page_name>{s}</page_name>
            \\<deleted>false</deleted>
            \\<reason>not_found</reason>
            \\</design_page>
        , .{input.page_name}) catch unreachable;
    }

    const deleted = design_model.deletePage(allocator, db, page_id) catch |err| {
        return std.fmt.allocPrint(allocator, "<error>failed to delete page: {s}</error>", .{@errorName(err)}) catch unreachable;
    };

    if (!deleted) {
        return std.fmt.allocPrint(allocator,
            \\<design_page>
            \\<page_name>{s}</page_name>
            \\<deleted>false</deleted>
            \\<reason>race_lost</reason>
            \\</design_page>
        , .{input.page_name}) catch unreachable;
    }

    // SSE event so other clients remove the tab.
    const workspace_id = try resolveItemWorkspaceId(allocator, db, input.item_id);
    on_event_sent_design.onEventSendDesignPageDeleted(allocator, .{
        .workspace_id = workspace_id,
        .item_id = input.item_id,
        .page_id = page_id,
        .page_name = input.page_name,
    });

    return std.fmt.allocPrint(allocator,
        \\<design_page>
        \\<page_id>{s}</page_id>
        \\<page_name>{s}</page_name>
        \\<deleted>true</deleted>
        \\</design_page>
    , .{ page_id, input.page_name }) catch unreachable;
}

// =====================================================================
// list_design_pages
// =====================================================================

pub const ListDesignPagesInput = struct {
    item_id: []const u8 = "",
};

pub const list_design_pages_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_design_pages",
        .description =
            \\List the pages on a design canvas. Returns one <page> element per page, with id, name, and position (no html — use set_design_page to read or write the body of a specific page). Use this tool to discover page names before calling set_design_page or delete_design_page, since both tools address pages by name.
            \\
            \\The item_id parameter must come from the chat context.
            ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The design workspace item id (NOT the name). Find it in the Workspace Context listing.",
                },
            },
            .required = &.{ "item_id" },
        },
    },
};

pub fn executeListDesignPagesToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: ListDesignPagesInput,
) ![]u8 {
    if (input.item_id.len == 0) {
        return allocator.dupe(u8, "<error>item_id is required</error>") catch unreachable;
    }

    const pages = design_model.listPages(allocator, db, input.item_id) catch |err| {
        return std.fmt.allocPrint(allocator, "<error>failed to list pages: {s}</error>", .{@errorName(err)}) catch unreachable;
    };
    defer design_model.freePageSummaries(allocator, pages);

    // Build the XML body.
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "<design_pages>");
    for (pages) |p| {
        try body.appendSlice(allocator, "<page id=\"");
        try body.appendSlice(allocator, p.id);
        try body.appendSlice(allocator, "\" name=\"");
        try body.appendSlice(allocator, p.name);
        try body.appendSlice(allocator, "\" position=\"");
        const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{p.position});
        defer allocator.free(pos_str);
        try body.appendSlice(allocator, pos_str);
        try body.appendSlice(allocator, "\" />");
    }
    try body.appendSlice(allocator, "</design_pages>");
    return body.toOwnedSlice(allocator) catch unreachable;
}

// =====================================================================
// helpers
// =====================================================================

/// Look up the parent workspace_id for a workspace_item. Returns "" on
/// miss (the SSE event then has an empty workspace_id, which is fine —
/// the frontend filter on empty key still accepts the event).
fn resolveItemWorkspaceId(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, item_id: []const u8) ![]const u8 {
    var q = try db.query(allocator,
        "SELECT workspace_id FROM workspace_items WHERE id = ?",
        &.{item_id},
    );
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return allocator.dupe(u8, row.values[0]) catch return "";
    }
    return "";
}

/// Find the page id matching (item_id, page_name). Writes the id into
/// `out_buf` (truncated to 256 bytes — page ids are unix-nanos
/// timestamp strings, well under that). Returns true on hit.
fn findPageByName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
    page_name: []const u8,
    out_buf: *[256]u8,
    out_id: *[]const u8,
) bool {
    var q = db.query(allocator,
        "SELECT id FROM design_pages WHERE workspace_item_id = ? AND name = ?",
        &.{ item_id, page_name },
    ) catch return false;
    defer q.deinit();
    const row = q.next() catch return false;
    if (row) |r| {
        defer r.deinit(allocator);
        const src = r.values[0];
        const len = @min(src.len, out_buf.len);
        @memcpy(out_buf[0..len], src[0..len]);
        out_id.* = out_buf[0..len];
        return true;
    }
    return false;
}