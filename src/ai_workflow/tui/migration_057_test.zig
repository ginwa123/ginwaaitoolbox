//! Behavioral tests for Migration 057 (add v6 element properties to
//! `design_page_elements`).
//!
//! What Migration 057 adds
//! ───────────────────────
//! 11 new columns on `design_page_elements`:
//!   type, rotation, fill, stroke, stroke_width, corner_radius,
//!   opacity, text_content, text_style, image_url, parent_id
//!
//! All defaults are sensible:
//!   - text/colour fields default to '' (the "no value" sentinel
//!     per the `sqlite-backend-empty-slice-binds-as-null` convention)
//!   - numeric defaults are 0 or 1.0 (no rotation, full opacity)
//!   - `parent_id` is nullable (TEXT) for non-nested elements
//!   - `type` defaults to 'rectangle' (the most common shape)
//!
//! Why a behavioral DB test (not a static check)?
//! ───────────────────────────────────────────────
//! A static source check would not catch a misspelled column name,
//! wrong DEFAULT clause, missing ALTER TABLE statement, or a typo in
//! the column type. Asserting the actual schema after `up()` runs
//! mirrors the pattern used by `migration_051_test.zig`.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Task 1.1)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const migrations = nalarcore.migrations_mod.migration;

const Migration055AddDesignPages = migrations.Migration055AddDesignPages;
const Migration056UpgradeDesignPagesToFileModel = migrations.Migration056UpgradeDesignPagesToFileModel;
const Migration057AddDesignElementProperties = migrations.Migration057AddDesignElementProperties;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with `workspace_items` +
/// `design_pages` (Migration 055 v1 schema with `html` column) +
/// `design_page_elements` (Migration 056 v5 schema, 12 columns).
/// This mirrors the state of a DB that has Migrations 1..56 applied,
/// which is the precondition for Migration 057.
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

    // workspace_items: required for the design_pages FK reference
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    // design_pages v1 schema (Migration 055 — pre-upgrade, includes html)
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    html TEXT NOT NULL DEFAULT '',
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});
    // design_page_elements v5 schema (Migration 056 — 12 columns, no v6 props)
    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '', x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0, width INTEGER NOT NULL DEFAULT 375,
        \\    height INTEGER NOT NULL DEFAULT 667, z_index INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0, created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: Migration 057 adds all 11 v6 columns ────────────────────────

test "Migration057 adds the 11 v6 element properties columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the upgrade path through 055 → 056 → 057, mirroring what
    // the live migration manager does for an existing v1 user.
    try Migration055AddDesignPages.up(&ctx.db, alloc);
    try Migration056UpgradeDesignPagesToFileModel.up(&ctx.db, alloc);
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);

    // Assert all 11 new columns exist on design_page_elements.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('design_page_elements')
        \\WHERE name IN ('type','rotation','fill','stroke','stroke_width',
        \\                'corner_radius','opacity','text_content',
        \\                'text_style','image_url','parent_id')
        \\ORDER BY name
    , &.{});
    defer q.deinit();

    const expected = [_][]const u8{
        "corner_radius",
        "fill",
        "image_url",
        "opacity",
        "parent_id",
        "rotation",
        "stroke",
        "stroke_width",
        "text_content",
        "text_style",
        "type",
    };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(i < expected.len);
        try testing.expectEqualStrings(expected[i], row.values[0]);
        i += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), i);
}

// ─── Test 2: Migration 057 idempotent on a v6-ready DB ──────────────────

test "Migration057 is idempotent when the columns already exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run once.
    try Migration055AddDesignPages.up(&ctx.db, alloc);
    try Migration056UpgradeDesignPagesToFileModel.up(&ctx.db, alloc);
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);

    // Run again — addColumnIfMissing must make this a no-op. If it
    // weren't idempotent, the second run would crash with
    // "duplicate column name: type" (or similar).
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);
}

// ─── Test 3: Migration 057 preserves existing v5 columns ─────────────────

test "Migration057 preserves the v5 columns on design_page_elements" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration055AddDesignPages.up(&ctx.db, alloc);
    try Migration056UpgradeDesignPagesToFileModel.up(&ctx.db, alloc);
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);

    // The 12 v5 columns must still be present after 057 (which is
    // strictly additive — never drop).
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('design_page_elements')
        \\WHERE name IN ('id','page_id','name','file_path','x','y','width',
        \\                'height','z_index','position','created_at','updated_at')
        \\ORDER BY name
    , &.{});
    defer q.deinit();

    var found: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        found += 1;
    }
    try testing.expectEqual(@as(usize, 12), found);
}
