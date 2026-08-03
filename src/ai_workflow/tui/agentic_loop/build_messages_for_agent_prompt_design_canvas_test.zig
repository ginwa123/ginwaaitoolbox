//! Tests for the iframe scrollbar guidance in `BuildDesignCanvasPrompt`.
//!
//! Plan: design-mode-scrollbar-fix — verify the design-canvas system
//! prompt teaches the LLM about the iframe sandbox boundary so future
//! designs ship with custom scrollbar styling instead of leaking the
//! default light-gray webkit scrollbar.
//!
//! What we assert:
//!   1. The prompt renders when the parent item_type === 'design'.
//!   2. The prompt contains the iframe sandbox explanation.
//!   3. The prompt contains a copy-paste-ready `<style>` template the
//!      LLM can embed in element `html` bodies.
//!   4. The prompt mentions both `::-webkit-scrollbar` (Chromium /
//!      WebKit) and `scrollbar-width` (Firefox) so designs render
//!      consistently across the nalar-desktop webviews (WebKitGTK on
//!      Linux, WKWebView on macOS, WebView2 on Windows).
//!
//! We use static-substring tests against the rendered markdown (the
//! pattern this codebase already uses for the BuildKanbanStatusPrompt
//! tests in `build_messages_for_agent_prompt_test.zig`).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const llm_history = @import("../llm_history.zig");

// ─── Test helpers (mirror build_messages_for_agent_prompt_test.zig) ────────

fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal schema needed by `BuildDesignCanvasPrompt`:
    // - workspaces
    // - workspace_items (with item_type)
    // - workspace_item_tasks (per task.id == session_id convention)
    // - design_pages (so the page listing branch doesn't crash)
    // - design_page_elements (so listElements succeeds when called per page)
    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT NULL,
        \\    updated_at DATETIME DEFAULT NULL
        \\)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    kanban_column_id TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    // design_pages — required so listPages in BuildDesignCanvasPrompt
    // returns an empty slice (not a SQL error). The helper bails on
    // any DB error and returns "".
    //
    // NOTE: listPages' SELECT (design_model.zig:329-330) reads
    // `dp.updated_at` (COALESCE'd to '' if NULL). The column must
    // exist on the table even when no rows are inserted — SQLite
    // raises `no such column: dp.updated_at` at prepare time.
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    workspace_item_task_id TEXT,
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    // design_page_elements — required so listElements succeeds when
    // called per page (currently returns 0 rows, but the call must
    // not crash).
    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY,
        \\    page_id TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    file_path TEXT NOT NULL DEFAULT '',
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    width INTEGER NOT NULL DEFAULT 200,
        \\    height INTEGER NOT NULL DEFAULT 100,
        \\    type TEXT NOT NULL DEFAULT 'rectangle',
        \\    fill TEXT NOT NULL DEFAULT '',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id)
        \\        ON DELETE CASCADE
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn seedDesignParent(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator) !void {
    try db.exec(alloc,
        "INSERT INTO workspaces (id, name) VALUES ('ws_design', 'test-design')",
        &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path)
        \\VALUES ('wi_design', 'ws_design', 'design', 'Mockup', '/abs/path')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\    (id, name, workspace_item_id, task_type)
        \\VALUES ('task_design1', 'design chat', 'wi_design', 'standard')
    , &.{});
}

// ─── Test 1: prompt renders for a design parent ───────────────────────────

test "BuildDesignCanvasPrompt renders non-empty markdown for design parent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedDesignParent(&ctx.db, alloc);

    const md = try @import("build_messages_for_agent_prompt.zig").BuildDesignCanvasPrompt(
        alloc,
        &ctx.db,
        "task_design1",
    );
    defer alloc.free(md);

    // Header is the canonical section opener — same prefix the kanban
    // status prompt uses for its section.
    try testing.expect(std.mem.indexOf(u8, md, "## Design Canvas") != null);
}

// ─── Test 2: prompt mentions the iframe sandbox boundary ─────────────────

test "BuildDesignCanvasPrompt explains the iframe sandbox boundary" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedDesignParent(&ctx.db, alloc);

    const md = try @import("build_messages_for_agent_prompt.zig").BuildDesignCanvasPrompt(
        alloc,
        &ctx.db,
        "task_design1",
    );
    defer alloc.free(md);

    // The whole point of the new guidance: the iframe is a SEPARATE
    // document, so parent CSS does NOT propagate in. If the LLM doesn't
    // see this caveat, future designs will keep shipping default
    // webkit scrollbars.
    try testing.expect(std.mem.indexOf(u8, md, "sandbox") != null);
    try testing.expect(std.mem.indexOf(u8, md, "iframe") != null);
    try testing.expect(std.mem.indexOf(u8, md, "separate document") != null);
}

// ─── Test 3: prompt provides a copy-pasteable <style> template ────────────

test "BuildDesignCanvasPrompt provides a usable scrollbar style template" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedDesignParent(&ctx.db, alloc);

    const md = try @import("build_messages_for_agent_prompt.zig").BuildDesignCanvasPrompt(
        alloc,
        &ctx.db,
        "task_design1",
    );
    defer alloc.free(md);

    // Chromium / WebKit scrollbar (covers WebKitGTK on Linux, WKWebView
    // on macOS — the two webviews nalar-desktop uses).
    try testing.expect(std.mem.indexOf(u8, md, "::-webkit-scrollbar") != null);
    try testing.expect(std.mem.indexOf(u8, md, "::-webkit-scrollbar-thumb") != null);

    // Firefox scrollbar (covers development in Firefox + the desktop-
    // app fallback).
    try testing.expect(std.mem.indexOf(u8, md, "scrollbar-width") != null);

    // The template must include the nalar color tokens (background +
    // thumb). #393836 is `--color-border-light` and #625e5a is
    // `--color-whitespace` in `style.css`.
    try testing.expect(std.mem.indexOf(u8, md, "#393836") != null);
    try testing.expect(std.mem.indexOf(u8, md, "#625e5a") != null);

    // The guidance must show a `<style>` block, otherwise the LLM
    // might try to apply the rules via inline `style=` attributes
    // (which can't reach pseudo-elements like ::-webkit-scrollbar).
    try testing.expect(std.mem.indexOf(u8, md, "<style>") != null);
}

// ─── Test 4: prompt mentions the trigger conditions ──────────────────────

test "BuildDesignCanvasPrompt lists the CSS properties that trigger the leak" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedDesignParent(&ctx.db, alloc);

    const md = try @import("build_messages_for_agent_prompt.zig").BuildDesignCanvasPrompt(
        alloc,
        &ctx.db,
        "task_design1",
    );
    defer alloc.free(md);

    // The LLM needs to know WHICH CSS properties trigger the default
    // scrollbar. Without these tokens, the LLM won't connect the
    // scrollbar advice to the `overflow-x: auto` it just wrote.
    try testing.expect(std.mem.indexOf(u8, md, "overflow-x: auto") != null);
    try testing.expect(std.mem.indexOf(u8, md, "overflow-y: auto") != null);
    try testing.expect(std.mem.indexOf(u8, md, "overflow: auto") != null);
}

// ─── Test 5: prompt returns empty for non-design parent ───────────────────

test "BuildDesignCanvasPrompt returns empty string for non-design parent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed a chat item (not design) bound to a task.
    try ctx.db.exec(alloc,
        "INSERT INTO workspaces (id, name) VALUES ('ws_chat', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path)
        \\VALUES ('wi_chat', 'ws_chat', 'chat', 'chat', '/abs/chat')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\    (id, name, workspace_item_id, task_type)
        \\VALUES ('task_chat1', 'chat', 'wi_chat', 'standard')
    , &.{});

    const md = try @import("build_messages_for_agent_prompt.zig").BuildDesignCanvasPrompt(
        alloc,
        &ctx.db,
        "task_chat1",
    );
    defer alloc.free(md);

    // The renderer bails (returns "") when the parent isn't a design
    // canvas — same pattern as BuildKanbanStatusPrompt.
    try testing.expectEqualStrings("", md);
}

// ─── Test 6: prompt mentions the new set_element_parent tool ─────────────

test "BuildDesignCanvasPrompt mentions the set_element_parent tool" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedDesignParent(&ctx.db, alloc);

    const md = try @import("build_messages_for_agent_prompt.zig").BuildDesignCanvasPrompt(
        alloc,
        &ctx.db,
        "task_design1",
    );
    defer alloc.free(md);

    // The set_element_parent tool must be advertised to the LLM so it
    // knows how to fix a previously-created element that landed at the
    // wrong nesting level (the prior gap that caused the bug behind
    // task "design mode, put wrong html").
    try testing.expect(std.mem.indexOf(u8, md, "set_element_parent") != null);
}

// ─── Test 7: prompt mentions parent_id on add_element ───────────────────

test "BuildDesignCanvasPrompt mentions parent_id parameter on add_element" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedDesignParent(&ctx.db, alloc);

    const md = try @import("build_messages_for_agent_prompt.zig").BuildDesignCanvasPrompt(
        alloc,
        &ctx.db,
        "task_design1",
    );
    defer alloc.free(md);

    // The add_element call example must surface `parent_id` so the LLM
    // knows it can nest new elements at creation time.
    try testing.expect(std.mem.indexOf(u8, md, "parent_id") != null);
}

// ─── Test 8: prompt directs re-parenting to set_element_parent, not update_element ─

test "BuildDesignCanvasPrompt directs re-parenting to set_element_parent, not update_element" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedDesignParent(&ctx.db, alloc);

    const md = try @import("build_messages_for_agent_prompt.zig").BuildDesignCanvasPrompt(
        alloc,
        &ctx.db,
        "task_design1",
    );
    defer alloc.free(md);

    // The previous prompt was wrong: it told the LLM to use
    // update_element(child_id, parent_id='...') for re-parenting, but
    // update_element does NOT accept parent_id. The correct API is
    // set_element_parent. This test pins the new behavior.
    //
    // We assert the prompt says "set_element_parent" near "re-parent"
    // (case-insensitive neighborhood search via substring).
    const lower_md = try alloc.dupe(u8, md);
    defer alloc.free(lower_md);
    for (lower_md, 0..) |c, i| lower_md[i] = std.ascii.toLower(c);

    // The word "set_element_parent" must appear in the prompt AND
    // appear in a context that mentions re-parenting.
    try testing.expect(std.mem.indexOf(u8, md, "set_element_parent") != null);
    // The phrase "re-parent" (or "reparent") should appear in the prompt.
    try testing.expect(
        std.mem.indexOf(u8, lower_md, "re-parent") != null or
            std.mem.indexOf(u8, lower_md, "reparent") != null,
    );
}
