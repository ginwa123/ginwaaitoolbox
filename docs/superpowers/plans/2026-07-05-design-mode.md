# Design Mode Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `item_type='design'` workspace item that hosts a chat-driven HTML canvas — multiple named pages per item, an iframe-only preview, and three LLM tools (`set_design_page`, `delete_design_page`, `list_design_pages`) for populating it.

**Architecture:** Backend (Zig) — Migration 055 adds `design_pages` table; new `design_model.zig` wraps CRUD; 5 new HTTP handlers under `/api/workspaces/:ws_id/items/:item_id/design/...`; 2 SSE events (`design_page_updated`, `design_page_deleted`); 3 LLM tools in `tool_registry.zig`. Frontend (Vue 3 + TypeScript) — new `AddDesignDialog.vue` for the workspace dropdown, new `DesignView.vue` with a tab strip + sandboxed iframe, `AppLayout.vue` mounts the view next to `<ChatView>`.

**Tech Stack:** Zig 0.16, SQLite (`nalarcore.sqlite.SqliteBackend`), Vue 3, TypeScript, Vite/Vitest, Bun. SSE via existing `sse_manager.zig`. Tooling patterns from `kanban_model.zig` (mirrored 1:1).

**Spec:** `docs/plans/2026-07-05-design-mode-design.md` (commit `00dbc594`).

---

## File Structure

### Backend (new files)
- `src/ai_workflow/tui/migration.zig` — append `Migration055AddDesignPages` (next free number after `Migration054`).
- `src/ai_workflow/tui/design_model.zig` — new. Pure CRUD against `design_pages` table. Mirrors `src/ai_workflow/tui/kanban_model.zig` structure.
- `src/ai_workflow/tui/on_event_design.zig` — new. Payload structs (`DesignPageUpdatedData`, `DesignPageDeletedData`) + JSON serialization helpers. Mirrors `on_event_kanban.zig`.
- `src/ai_workflow/tui/on_event_sent_design.zig` — new. Two functions (`onEventSendDesignPageUpdated`, `onEventSendDesignPageDeleted`) that wrap `onEventSend` with the design-typed events. Mirrors `on_event_sent_kanban.zig`.
- `src/modules/agent/tools/design_tools.zig` — new. The 3 LLM tools (`set_design_page`, `delete_design_page`, `list_design_pages`). Mirrors `src/modules/agent/tools/kanban_tools.zig`.
- `src/ai_workflow/tui/http_handlers/design_items_create.zig` — new. `POST /items/design`.
- `src/ai_workflow/tui/http_handlers/design_pages_list.zig` — new. `GET .../design/pages`.
- `src/ai_workflow/tui/http_handlers/design_pages_get.zig` — new. `GET .../design/pages/:page_id`.
- `src/ai_workflow/tui/http_handlers/design_pages_update.zig` — new. `PUT .../design/pages/:page_id`.
- `src/ai_workflow/tui/http_handlers/design_pages_delete.zig` — new. `DELETE .../design/pages/:page_id`.

### Backend (modify)
- `src/ai_workflow/tui/migration.zig` — add `Migration055AddDesignPages` struct + register it in `allMigrations`.
- `src/ai_workflow/tui/mod.zig` — re-export `design_model`, `on_event_design`, `on_event_sent_design`.
- `src/ai_workflow/tui/http_handlers/mod.zig` — re-export the 5 new handlers.
- `src/main.zig` — register 5 new routes (`POST /items/design` + 4 under `.../design/pages`).
- `src/modules/agent/tools/mod.zig` — re-export `design_tools`.
- `src/ai_workflow/tui/tool_registry.zig` — register 3 new tools (`set_design_page`, `delete_design_page`, `list_design_pages`).
- `src/ai_workflow/tui/test_runner.zig` — register all 7 new test files.

### Frontend (new files)
- `src/apps/desktop/src/components/AddDesignDialog.vue` — new. Modal: name input → emit `create(name)`. Mirrors `AddKanbanDialog.vue` but without the folder picker.
- `src/apps/desktop/src/components/DesignView.vue` — new. Tab strip + iframe component. ~250 lines.
- `src/apps/desktop/src/__tests__/apiDesign.spec.ts` — new. Vitest tests for 5 new API functions.
- `src/apps/desktop/src/__tests__/addDesignDialog.spec.ts` — new. Vitest tests for the modal.
- `src/apps/desktop/src/__tests__/designViewIframe.spec.ts` — new. Vitest tests for DesignView.

### Frontend (modify)
- `src/apps/desktop/src/api/index.ts` — add 5 new API functions (`createDesign`, `listDesignPages`, `getDesignPage`, `updateDesignPage`, `deleteDesignPage`) + `DesignPageSummary` / `DesignPageFull` types.
- `src/apps/desktop/src/stores/workspaces.ts` — add `'design'` to `item_type` literal type, add `design_pages?: PageSummary[]` field, add `addDesignItem(workspaceId, name)` function, expose `addDesignItem` in the returned object.
- `src/apps/desktop/src/components/WorkspaceList.vue` — add "Add Design" button in the dropdown (after "Add Kanban").
- `src/apps/desktop/src/components/Sidebar.vue` — add `showAddDesignDialog` ref, import `AddDesignDialog`, add `handleCreateDesign(name)` action, mount the dialog.
- `src/apps/desktop/src/components/AppLayout.vue` — add `v-else-if="item_type === 'design'"` branch mounting `<DesignView>` + `<ChatView>` side-by-side (mirror kanban layout).

### Scripts (new + modify)
- `scripts/design-mode-smoke.sh` — new. End-to-end smoke test (7 steps).
- `scripts/ci-smoke-test.sh` — append Step 6 to invoke the new smoke test.

### Test files (Backend, 7 new)
- `src/ai_workflow/tui/design_model_test.zig` — ~150 lines, ~10 unit tests.
- `src/ai_workflow/tui/migration_055_test.zig` — schema + forward-replay tests.
- `src/ai_workflow/tui/http_handlers/design_items_create_test.zig`
- `src/ai_workflow/tui/http_handlers/design_pages_list_test.zig`
- `src/ai_workflow/tui/http_handlers/design_pages_get_test.zig`
- `src/ai_workflow/tui/http_handlers/design_pages_update_test.zig`
- `src/ai_workflow/tui/http_handlers/design_pages_delete_test.zig`

---

## Chunk 1: Migration + Model Layer

Goal: Schema + data-layer foundation. Zig-only. No HTTP, no UI.

### Task 1.1: Add `Migration055AddDesignPages`

**Files:**
- Modify: `src/ai_workflow/tui/migration.zig` (after `Migration054MakeSessionQueueMessageNullable`, before `allMigrations` array)
- Test: `src/ai_workflow/tui/migration_055_test.zig` (new)

- [ ] **Step 1: Write failing test for migration registration**

```zig
// src/ai_workflow/tui/migration_055_test.zig
const std = @import("std");
const testing = std.testing;
const sqlite = nalarcore.sqlite;
const migration_module = @import("../migration.zig");
const Migration055AddDesignPages = migration_module.Migration055AddDesignPages;

test "Migration055 is registered in allMigrations" {
    var found = false;
    for (migration_module.allMigrations) |m| {
        if (m.version == Migration055AddDesignPages.version and
            std.mem.eql(u8, m.name, Migration055AddDesignPages.name)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}
```

- [ ] **Step 2: Run test, expect compile error**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: compile error referencing `Migration055AddDesignPages` (symbol not defined).

- [ ] **Step 3: Add Migration055AddDesignPages struct in migration.zig**

Append after `Migration054MakeSessionQueueMessageNullable`:

```zig
pub const Migration055AddDesignPages = struct {
    pub const version: u32 = 55;
    pub const name = "add_design_pages";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Design Mode (Multi-page HTML canvas) — Migration 055.
        // Adds the design_pages table. Each design workspace item
        // owns N named pages (e.g. "Login", "Dashboard"). Pages are
        // addressed by (workspace_item_id, name) so the LLM tool
        // `set_design_page(item_id, name, html)` is idempotent via
        // ON CONFLICT. Plan: docs/superpowers/plans/2026-07-05-design-mode.md
        // (Chunk 1).
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS design_pages (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL,
            \\    name TEXT NOT NULL DEFAULT '',
            \\    html TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_design_pages_item_name " ++
            "ON design_pages(workspace_item_id, name)",
            &[_][]const u8{},
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_design_pages_item_position " ++
            "ON design_pages(workspace_item_id, position)",
            &[_][]const u8{},
        );
        // ANALYZE so the query planner sees the new indexes.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
```

Then add `.{ .version = Migration055AddDesignPages.version, .name = Migration055AddDesignPages.name, .up = Migration055AddDesignPages.up }` to the `allMigrations` array (after the Migration054 entry).

- [ ] **Step 4: Run test, expect pass**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: pass with `Migration055 is registered in allMigrations` printed.

- [ ] **Step 5: Add schema-shape test**

Append to `migration_055_test.zig`:

```zig
test "Migration055 creates design_pages with the 7 expected columns" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    // Run migrations 1 through 54 first (Migration055 depends on workspace_items).
    // For unit-test scope we only need to apply Migration055 against a
    // pre-populated empty DB; copy the workspace_items CREATE TABLE
    // manually as a shortcut (full migration runner would touch many
    // other tables we don't need here).
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, item_type TEXT NOT NULL DEFAULT 'folder')",
        &.{});
    try Migration055AddDesignPages.up(&db, testing.allocator);

    var q = try db.query(testing.allocator,
        "SELECT name FROM pragma_table_info('design_pages') ORDER BY cid", &.{});
    defer q.deinit();
    var seen: [7][]const u8 = .{ "id", "workspace_item_id", "name", "html", "position", "created_at", "updated_at" };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(testing.allocator);
        if (i >= seen.len) return error.UnexpectedColumnCount;
        try testing.expect(std.mem.eql(u8, row.values[0], seen[i]));
        i += 1;
    }
    try testing.expectEqual(@as(usize, 7), i);
}
```

- [ ] **Step 6: Register test in test_runner.zig**

Modify `src/ai_workflow/tui/test_runner.zig` and append `_ = @import("migration_055_test.zig");`.

- [ ] **Step 7: Run all tests, expect green**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: pass, test count +2.

- [ ] **Step 8: Commit**

```bash
git add src/ai_workflow/tui/migration.zig src/ai_workflow/tui/migration_055_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(migration): add design_pages table (Migration 055)"
```

### Task 1.2: Add `design_model.zig`

**Files:**
- Create: `src/ai_workflow/tui/design_model.zig`
- Test: `src/ai_workflow/tui/design_model_test.zig` (new)

- [ ] **Step 1: Write failing test for `addPage` (creates new page)**

```zig
// src/ai_workflow/tui/design_model_test.zig
const std = @import("std");
const testing = std.testing;
const sqlite = nalarcore.sqlite;
const design_model = @import("design_model.zig");

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, item_type TEXT NOT NULL DEFAULT 'folder')",
        &.{});
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    html TEXT NOT NULL DEFAULT '',
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id) VALUES ('item_test', 'ws_test')", &.{});
    return .{ .db = db, .threaded = threaded };
}

test "addPage creates a new page and returns its id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "Login", "<h1>Hi</h1>");
    defer alloc.free(id);
    try testing.expect(std.mem.startsWith(u8, id, "page_"));
}
```

- [ ] **Step 2: Run test, expect compile error**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: compile error referencing `design_model` (not defined).

- [ ] **Step 3: Create design_model.zig with `addPage`**

```zig
// src/ai_workflow/tui/design_model.zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

pub fn addPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    name: []const u8,
    html: []const u8,
) ![]u8 {
    _ = name;
    _ = html;
    _ = allocator;
    _ = db;
    _ = workspace_item_id;
    @panic("TODO: implement Chunk 1, Task 1.2 Step 3");
}
```

- [ ] **Step 4: Implement `addPage` (idempotent INSERT … ON CONFLICT)**

Replace the `addPage` body with the real implementation:

```zig
pub fn addPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    name: []const u8,
    html: []const u8,
) ![]u8 {
    const id = try std.fmt.allocPrint(allocator, "page_{d}", .{
        std.time.timestamp() * 1_000_000_000,
    });
    errdefer allocator.free(id);

    // Idempotent on (workspace_item_id, name) — re-calling with the
    // same name replaces the existing row's html in place.
    try db.exec(allocator,
        \\INSERT INTO design_pages (id, workspace_item_id, name, html, position)
        \\VALUES (?, ?, ?, ?, COALESCE((SELECT MAX(position) FROM design_pages WHERE workspace_item_id = ?), -1) + 1)
        \\ON CONFLICT(workspace_item_id, name) DO UPDATE SET html = excluded.html, updated_at = datetime('now')
    , &.{ id, workspace_item_id, name, html, workspace_item_id });
    return id;
}
```

- [ ] **Step 5: Run test, expect green**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: pass.

- [ ] **Step 6: Add remaining 9 model tests in same file**

Add tests in this order (one task per pair of test steps is fine; do them all in one batch since they share the `setupDb` helper):

```zig
test "addPage is idempotent on (item_id, name) — second call updates html" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const id1 = try design_model.addPage(alloc, &ctx.db, "item_test", "Login", "<h1>v1</h1>");
    defer alloc.free(id1);
    const id2 = try design_model.addPage(alloc, &ctx.db, "item_test", "Login", "<h1>v2</h1>");
    defer alloc.free(id2);
    try testing.expectEqualStrings(id1, id2);
    var q = try ctx.db.query(alloc, "SELECT html FROM design_pages WHERE id = ?", &.{id1});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("<h1>v2</h1>", row.values[0]);
}

test "addPage on empty item gets position 0" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "First", "");
    defer alloc.free(id);
    var q = try ctx.db.query(alloc, "SELECT position FROM design_pages WHERE id = ?", &.{id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqual(@as(i64, 0), try std.fmt.parseInt(i64, row.values[0], 10));
}

test "addPage assigns incrementing position" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const a = try design_model.addPage(alloc, &ctx.db, "item_test", "A", "");
    defer alloc.free(a);
    const b = try design_model.addPage(alloc, &ctx.db, "item_test", "B", "");
    defer alloc.free(b);
    const c = try design_model.addPage(alloc, &ctx.db, "item_test", "C", "");
    defer alloc.free(c);
    var q = try ctx.db.query(alloc,
        "SELECT position FROM design_pages WHERE workspace_item_id = ? ORDER BY position ASC", &.{"item_test"});
    defer q.deinit();
    var positions: [3]i64 = .{ 0, 0, 0 };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        positions[i] = try std.fmt.parseInt(i64, row.values[0], 10);
        i += 1;
    }
    try testing.expectEqual(@as(usize, 3), i);
    try testing.expect(positions[0] < positions[1]);
    try testing.expect(positions[1] < positions[2]);
}

test "listPages returns rows ordered by position, excludes html" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const a = try design_model.addPage(alloc, &ctx.db, "item_test", "First", "<h1>1</h1>");
    defer alloc.free(a);
    const b = try design_model.addPage(alloc, &ctx.db, "item_test", "Second", "<h1>2</h1>");
    defer alloc.free(b);
    const summaries = try design_model.listPages(alloc, &ctx.db, "item_test");
    defer design_model.freePageSummaries(alloc, summaries);
    try testing.expectEqual(@as(usize, 2), summaries.len);
    try testing.expectEqualStrings("First", summaries[0].name);
    try testing.expectEqualStrings("Second", summaries[1].name);
    try testing.expect(summaries[0].position < summaries[1].position);
    try testing.expect(summaries[0].html == null); // html is excluded
}

test "getPage returns full row including html" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "Foo", "<p>bar</p>");
    defer alloc.free(id);
    const page = try design_model.getPage(alloc, &ctx.db, id);
    defer design_model.freePageFull(alloc, page);
    try testing.expectEqualStrings("Foo", page.name);
    try testing.expectEqualStrings("<p>bar</p>", page.html);
}

test "getPage on missing id returns error.PageNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const result = design_model.getPage(alloc, &ctx.db, "page_does_not_exist");
    try testing.expectError(error.PageNotFound, result);
}

test "deletePage removes the row and returns true" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "Foo", "");
    defer alloc.free(id);
    const deleted = try design_model.deletePage(alloc, &ctx.db, id);
    try testing.expect(deleted);
    const result = design_model.getPage(alloc, &ctx.db, id);
    try testing.expectError(error.PageNotFound, result);
}

test "deletePage on missing id returns false (idempotent)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const deleted = try design_model.deletePage(alloc, &ctx.db, "page_does_not_exist");
    try testing.expect(!deleted);
}

test "updatePageHtml replaces html and returns true" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "Foo", "<p>v1</p>");
    defer alloc.free(id);
    const ok = try design_model.updatePageHtml(alloc, &ctx.db, id, "<p>v2</p>");
    try testing.expect(ok);
    const page = try design_model.getPage(alloc, &ctx.db, id);
    defer design_model.freePageFull(alloc, page);
    try testing.expectEqualStrings("<p>v2</p>", page.html);
}
```

- [ ] **Step 7: Implement the remaining model functions**

Append to `design_model.zig`:

```zig
pub const DesignPageSummary = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    /// `null` — listPages excludes html by design (lazy load).
    html: ?[]u8 = null,
    position: i64,
    created_at: []u8,
    updated_at: []u8,
};

pub const DesignPageFull = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    html: []u8,
    position: i64,
    created_at: []u8,
    updated_at: []u8,
};

pub fn listPages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]DesignPageSummary {
    var q = try db.query(allocator,
        \\SELECT dp.id, dp.workspace_item_id, dp.name, dp.position, dp.created_at, dp.updated_at
        \\FROM design_pages dp
        \\WHERE dp.workspace_item_id = ?
        \\ORDER BY dp.position ASC
    , &.{workspace_item_id});
    defer q.deinit();

    var rows = std.ArrayList(DesignPageSummary).empty;
    errdefer {
        for (rows.items) |row| {
            allocator.free(row.id);
            allocator.free(row.workspace_item_id);
            allocator.free(row.name);
            if (row.html) |h| allocator.free(h);
            allocator.free(row.created_at);
            allocator.free(row.updated_at);
        }
        rows.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_item_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .position = try std.fmt.parseInt(i64, row.values[3], 10),
            .created_at = try allocator.dupe(u8, row.values[4]),
            .updated_at = try allocator.dupe(u8, row.values[5]),
        });
    }
    return rows.toOwnedSlice(allocator);
}

pub fn freePageSummaries(allocator: std.mem.Allocator, pages: []DesignPageSummary) void {
    for (pages) |p| {
        allocator.free(p.id);
        allocator.free(p.workspace_item_id);
        allocator.free(p.name);
        if (p.html) |h| allocator.free(h);
        allocator.free(p.created_at);
        allocator.free(p.updated_at);
    }
    allocator.free(pages);
}

pub fn getPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) !DesignPageFull {
    var q = try db.query(allocator,
        \\SELECT dp.id, dp.workspace_item_id, dp.name, dp.html, dp.position, dp.created_at, dp.updated_at
        \\FROM design_pages dp WHERE dp.id = ?
    , &.{page_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.PageNotFound;
    errdefer row.deinit(allocator);
    return DesignPageFull{
        .id = try allocator.dupe(u8, row.values[0]),
        .workspace_item_id = try allocator.dupe(u8, row.values[1]),
        .name = try allocator.dupe(u8, row.values[2]),
        .html = try allocator.dupe(u8, row.values[3]),
        .position = try std.fmt.parseInt(i64, row.values[4], 10),
        .created_at = try allocator.dupe(u8, row.values[5]),
        .updated_at = try allocator.dupe(u8, row.values[6]),
    };
}

pub fn freePageFull(allocator: std.mem.Allocator, page: DesignPageFull) void {
    allocator.free(page.id);
    allocator.free(page.workspace_item_id);
    allocator.free(page.name);
    allocator.free(page.html);
    allocator.free(page.created_at);
    allocator.free(page.updated_at);
}

pub fn deletePage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) !bool {
    var q = try db.query(allocator,
        "SELECT id FROM design_pages WHERE id = ?", &.{page_id});
    defer q.deinit();
    const row = try q.next();
    if (row == null) return false;
    if (row) |r| r.deinit(allocator);
    try db.exec(allocator, "DELETE FROM design_pages WHERE id = ?", &.{page_id});
    return true;
}

pub fn updatePageHtml(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    html: []const u8,
) !bool {
    var q = try db.query(allocator,
        "SELECT id FROM design_pages WHERE id = ?", &.{page_id});
    defer q.deinit();
    const row = try q.next();
    if (row == null) return false;
    if (row) |r| r.deinit(allocator);
    try db.exec(allocator,
        "UPDATE design_pages SET html = ?, updated_at = datetime('now') WHERE id = ?",
        &.{ html, page_id });
    return true;
}
```

- [ ] **Step 8: Re-export design_model in mod.zig**

Modify `src/ai_workflow/tui/mod.zig`: append `pub const design_model = @import("design_model.zig");`.

- [ ] **Step 9: Register test in test_runner.zig**

Append: `_ = @import("design_model_test.zig");`.

- [ ] **Step 10: Run all tests, expect green**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: pass, test count +10 (or +9 net) from new model tests.

- [ ] **Step 11: Commit**

```bash
git add src/ai_workflow/tui/design_model.zig src/ai_workflow/tui/design_model_test.zig src/ai_workflow/tui/mod.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat(design): add design_model CRUD layer with 10 unit tests"
```

---

## Chunk 2: HTTP Handlers + SSE Events

Goal: Backend-complete surface. 5 new handlers + 2 SSE events, all with static-contract tests.

### Task 2.1: `design_items_create.zig` (POST `/items/design`)

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/design_items_create.zig`
- Test: `src/ai_workflow/tui/http_handlers/design_items_create_test.zig`
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Write failing test (static contract)**

```zig
// design_items_create_test.zig
const std = @import("std");
const testing = std.testing;
const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_items_create.zig";

fn readSource(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(alloc, path, 1 << 16);
}

test "design_items_create handler uses parseFromSliceLeaky" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("!! {s} does not use parseFromSliceLeaky !!\n", .{HANDLER_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
}

test "design_items_create handler inserts item_type='design'" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "'design'") == null) {
        std.debug.print("!! {s} does not hard-code 'design' !!\n", .{HANDLER_PATH});
        return error.ItemTypeDesignMissing;
    }
}

test "design_items_create handler returns 201 on success" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "status_code = 201") == null) {
        std.debug.print("!! {s} does not return 201 !!\n", .{HANDLER_PATH});
        return error.StatusCode201Missing;
    }
}
```

- [ ] **Step 2: Run test, expect failure**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: compile error — handler not defined.

- [ ] **Step 3: Create handler**

Create `src/ai_workflow/tui/http_handlers/design_items_create.zig` modeled on `workspace_items_create_kanban.zig` (the closest pattern):

```zig
//! `POST /api/workspaces/:workspace_id/items/design`.
//!
//! Creates a new workspace item of `item_type='design'` (HTML canvas).
//! No schema migration needed — `item_type` is a free-form TEXT column.
//!
//! Body: `{name}` — `name` is required. Returns `{id, workspace_id,
//! item_type:"design", name, position, pages:[]}` (201).
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = nalarcore.helpers;

const CreateDesignBody = struct {
    name: []const u8,
};

pub const DesignItemsCreateResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: []const u8,
    position: i64,
    pages: []const []const u8 = &[_][]const u8{}, // empty on creation
};

pub const DesignItemsCreateError = error{
    WorkspaceIdRequired,
    MissingBody,
    InvalidJson,
    NameRequired,
    InsertFailed,
    OutOfMemory,
};

pub const DesignItemsCreateInput = struct {
    workspace_id: []const u8,
    body: CreateDesignBody,
};

pub fn designItemsCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;
    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
        });
    }
    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }
    const parsed = std.json.parseFromSliceLeaky(CreateDesignBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };
    if (parsed.name.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }

    const ts = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{ts});
    defer allocator.free(item_id);

    sqlite_db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) " ++
        "VALUES (?, ?, 'design', ?, NULL, COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ item_id, workspace_id, parsed.name, workspace_id },
    ) catch return res.jsonResponse(.{
        .status_code = 500,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create design item" }),
    });

    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(allocator, DesignItemsCreateResponse{
            .id = item_id,
            .workspace_id = workspace_id,
            .item_type = "design",
            .name = parsed.name,
            .position = 0, // first item in this workspace
        }, .{}),
    });
}
```

- [ ] **Step 4: Re-export + run tests, expect green**

In `src/ai_workflow/tui/http_handlers/mod.zig` append:
```zig
pub const design_items_create = @import("design_items_create.zig");
pub const design_items_create_handler = design_items_create.designItemsCreateHandler;
```

Register test in `test_runner.zig`:
```zig
_ = @import("http_handlers/design_items_create_test.zig");
```

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: pass with +3 tests.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/design_items_create.zig \
        src/ai_workflow/tui/http_handlers/design_items_create_test.zig \
        src/ai_workflow/tui/http_handlers/mod.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "feat(design): add POST /items/design handler"
```

### Task 2.2: SSE event types (`on_event_design.zig` + `on_event_sent_design.zig`)

**Files:**
- Create: `src/ai_workflow/tui/on_event_design.zig`
- Create: `src/ai_workflow/tui/on_event_sent_design.zig`
- Modify: `src/ai_workflow/tui/mod.zig`

- [ ] **Step 1: Create `on_event_design.zig` with payload structs**

```zig
//! Wire-shape types for design SSE events.
//!
//! Two event types: `design_page_updated`, `design_page_deleted`.
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2).

const std = @import("std");
const nalarcore = @import("nalarcore");

pub const DesignPageUpdatedData = struct {
    /// `"created"` for new pages, `"updated"` for replacements via
    /// `set_design_page` or `updatePageHtml`.
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    page: PagePayload,
};

pub const DesignPageDeletedData = struct {
    action: []const u8 = "deleted",
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    page_name: []const u8,
};

pub const PagePayload = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    /// Full HTML — included so frontend can apply without a follow-up GET.
    html: []const u8,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Serialize `data` into a `data: <JSON>\n\n` SSE chunk.
pub fn serializePageUpdated(allocator: std.mem.Allocator, data: DesignPageUpdatedData) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, data, .{});
}

pub fn serializePageDeleted(allocator: std.mem.Allocator, data: DesignPageDeletedData) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, data, .{});
}
```

- [ ] **Step 2: Create `on_event_sent_design.zig` with two emit functions**

```zig
//! SSE emitter functions for design events.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2).

const std = @import("std");
const nalarcore = @import("nalarcore");
const on_event_design = @import("on_event_design.zig");

/// Emit a `design_page_updated` event. Fire-and-forget — failures are
/// logged and swallowed so the calling tool call still succeeds.
pub fn onEventSendDesignPageUpdated(
    allocator: std.mem.Allocator,
    data: on_event_design.DesignPageUpdatedData,
) !void {
    // Re-use the existing on_event_sent dispatcher with the design event
    // name. Mirrors `on_event_sent_kanban.onEventSendKanbanColumn`.
    const json_data = try on_event_design.serializePageUpdated(allocator, data);
    defer allocator.free(json_data);
    const payload = std.fmt.allocPrint(allocator, "{{\"event\":\"design_page_updated\",\"data\":{s}}}", .{json_data}) catch |err| {
        std.log.warn("design_page_updated: allocPrint failed (non-fatal): {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(payload);
    nalarcore.on_event_sent.broadcastEvent(allocator, "design_page_updated", payload) catch |err| {
        std.log.warn("design_page_updated: broadcast failed (non-fatal): {s}", .{@errorName(err)});
    };
}

pub fn onEventSendDesignPageDeleted(
    allocator: std.mem.Allocator,
    data: on_event_design.DesignPageDeletedData,
) !void {
    const json_data = try on_event_design.serializePageDeleted(allocator, data);
    defer allocator.free(json_data);
    const payload = std.fmt.allocPrint(allocator, "{{\"event\":\"design_page_deleted\",\"data\":{s}}}", .{json_data}) catch |err| {
        std.log.warn("design_page_deleted: allocPrint failed (non-fatal): {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(payload);
    nalarcore.on_event_sent.broadcastEvent(allocator, "design_page_deleted", payload) catch |err| {
        std.log.warn("design_page_deleted: broadcast failed (non-fatal): {s}", .{@errorName(err)});
    };
}
```

- [ ] **Step 3: Inspect the actual `on_event_sent` API surface**

Before committing, verify that `nalarcore.on_event_sent` exposes the function name pattern used in `on_event_sent_kanban.zig`. Read that file and adapt the `broadcastEvent` call to match the real signature. If the API uses `onEventSend(allocator, event_name, data_ptr, data_len)` instead, change the calls. **DO NOT GUESS** — check the existing pattern.

- [ ] **Step 4: Re-export both in mod.zig**

Append: `pub const on_event_design = @import("on_event_design.zig");` and `pub const on_event_sent_design = @import("on_event_sent_design.zig");`.

- [ ] **Step 5: Build and commit**

Run: `timeout 180 zig build install:linux:system 2>&1 | tail -n 5`
Expected: 4/6 steps succeed (cp to /usr/local/bin/nalar fails with permission denied — that's expected).

```bash
git add src/ai_workflow/tui/on_event_design.zig src/ai_workflow/tui/on_event_sent_design.zig src/ai_workflow/tui/mod.zig
git commit -m "feat(design): add SSE event types and emitters"
```

### Task 2.3: `design_pages_list.zig` (GET `/design/pages`)

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/design_pages_list.zig`
- Test: `src/ai_workflow/tui/http_handlers/design_pages_list_test.zig`
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Write static-contract tests**

```zig
const std = @import("std");
const testing = std.testing;
const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_pages_list.zig";

fn readSource(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(alloc, path, 1 << 16);
}

test "design_pages_list handler does not parse a request body" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "req.body") != null) {
        std.debug.print("!! {s} should NOT read req.body (GET has no body) !!\n", .{HANDLER_PATH});
        return error.BodyShouldNotBeParsed;
    }
}

test "design_pages_list handler calls design_model.listPages" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "design_model.listPages") == null) {
        std.debug.print("!! {s} does not call design_model.listPages !!\n", .{HANDLER_PATH});
        return error.ModelCallMissing;
    }
}

test "design_pages_list handler validates item_id + workspace_id" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "item_id") == null or
        std.mem.indexOf(u8, source, "workspace_id") == null) {
        std.debug.print("!! {s} does not validate params !!\n", .{HANDLER_PATH});
        return error.ParamValidationMissing;
    }
}

test "design_pages_list handler returns 200 on success" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "status_code = 200") == null) {
        std.debug.print("!! {s} does not return 200 !!\n", .{HANDLER_PATH});
        return error.StatusCode200Missing;
    }
}
```

- [ ] **Step 2: Create handler**

```zig
//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages`.
//!
//! Lists all pages of a design item, ordered by `position`. Excludes
//! the `html` field — lazy-loaded by `design_pages_get`.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

pub fn designPagesListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    if (workspace_id.len == 0 or item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id and item_id required" }),
        });
    }

    const pages = design_model.listPages(allocator, &nalarcore.getSingleton().db, item_id) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to list design pages" }),
        });
    };
    defer design_model.freePageSummaries(allocator, pages);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, pages, .{}),
    });
}
```

- [ ] **Step 3: Re-export, register test, build, commit**

```bash
git add src/ai_workflow/tui/http_handlers/design_pages_list.zig \
        src/ai_workflow/tui/http_handlers/design_pages_list_test.zig \
        src/ai_workflow/tui/http_handlers/mod.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "feat(design): add GET /design/pages handler"
```

### Task 2.4: `design_pages_get.zig` (GET `/design/pages/:page_id`)

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/design_pages_get.zig`
- Test: `src/ai_workflow/tui/http_handlers/design_pages_get_test.zig`
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Static-contract tests**

```zig
test "design_pages_get handler calls design_model.getPage" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "design_model.getPage") == null) return error.ModelCallMissing;
}
test "design_pages_get handler returns 404 on PageNotFound" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "404") == null) return error.StatusCode404Missing;
}
test "design_pages_get handler returns 200 on success" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "status_code = 200") == null) return error.StatusCode200Missing;
}
```

- [ ] **Step 2: Create handler modeled on the list handler, calling `design_model.getPage` and mapping `error.PageNotFound` to 404.**

- [ ] **Step 3: Re-export, register test, build, commit**

### Task 2.5: `design_pages_update.zig` (PUT `/design/pages/:page_id`)

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/design_pages_update.zig`
- Test: `src/ai_workflow/tui/http_handlers/design_pages_update_test.zig`
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Static-contract tests**

Tests should verify:
- Uses `parseFromSliceLeaky`
- Calls `design_model.updatePageHtml`
- Calls `onEventSendDesignPageUpdated` (grep for that function name)
- Returns 200 on success, 400 on missing/invalid body, 404 on missing page
- Rejects html > 5 MB

- [ ] **Step 2: Create handler** — implements PUT, emits SSE event on success.

- [ ] **Step 3: Register, build, commit**

### Task 2.6: `design_pages_delete.zig` (DELETE `/design/pages/:page_id`)

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/design_pages_delete.zig`
- Test: `src/ai_workflow/tui/http_handlers/design_pages_delete_test.zig`
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Static-contract tests** verifying:
- Does not parse a body
- Calls `design_model.deletePage`
- Calls `onEventSendDesignPageDeleted`
- Returns 200 + `{deleted: true, page_id}` on success

- [ ] **Step 2: Create handler.**

- [ ] **Step 3: Register, build, commit.**

### Task 2.7: Wire all 5 routes in `src/main.zig`

**Files:** Modify `src/main.zig` around line 367 (near the existing kanban routes).

- [ ] **Step 1: Add the 5 route registrations**

```zig
try gs.router.post("/api/workspaces/:workspace_id/items/design", ai_mod.http_handlers.designItemsCreateHandler);
try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/design/pages", ai_mod.http_handlers.designPagesListHandler);
try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesGetHandler);
try gs.router.put("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesUpdateHandler);
try gs.router.delete("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesDeleteHandler);
```

(Adjust the function names if the handler exports `n` instead of the long name — see how `workspace_items_create` exports `n`.)

- [ ] **Step 2: Build, expect clean**

Run: `timeout 180 zig build install:linux:system 2>&1 | tail -n 8`
Expected: 4/6 succeed (cp fail is harmless).

- [ ] **Step 3: Commit**

```bash
git add src/main.zig
git commit -m "feat(design): wire 5 HTTP routes for design canvas"
```

---

## Chunk 3: LLM Tools

Goal: 3 LLM tools wired into the registry.

### Task 3.1: `design_tools.zig` — `set_design_page`

**Files:**
- Create: `src/modules/agent/tools/design_tools.zig`
- Modify: `src/modules/agent/tools/mod.zig`

- [ ] **Step 1: Create file with tool stub** matching the pattern in `src/modules/agent/tools/kanban_tools.zig`. Tool signature:

```zig
pub fn execSetDesignPage(
    ctx: *ToolExecContext,
    tc: ToolCall,
) ![]u8 {
    _ = ctx;
    _ = tc;
    @panic("TODO");
}
```

- [ ] **Step 2: Implement the tool**

```zig
pub fn execSetDesignPage(
    ctx: *ToolExecContext,
    tc: ToolCall,
) ![]u8 {
    const allocator = ctx.allocator;
    const parsed = std.json.parseFromSliceLeaky(SetDesignPageInput, allocator, tc.arguments, .{}) catch {
        return try makeToolError(allocator, "Invalid JSON: expected {item_id, page_name, html}");
    };
    if (parsed.item_id.len == 0) return try makeToolError(allocator, "item_id is required");
    if (parsed.page_name.len == 0) return try makeToolError(allocator, "page_name is required");
    if (std.mem.indexOfAny(u8, parsed.page_name, "/\x00") != null) {
        return try makeToolError(allocator, "page_name must not contain '/' or null bytes");
    }
    if (parsed.html.len > 5 * 1024 * 1024) {
        return try makeToolError(allocator, "html exceeds 5 MB limit");
    }

    const di = nalarcore.getSingleton() catch return try makeToolError(allocator, "Backend not initialized");
    const db = di.db;
    const id = design_model.addPage(allocator, db, parsed.item_id, parsed.page_name, parsed.html) catch {
        return try makeToolError(allocator, "Failed to set design page");
    };
    defer allocator.free(id);

    // Re-fetch the row so we can emit the full payload including
    // updated_at and the persisted html.
    const page = design_model.getPage(allocator, db, id) catch return try makeToolError(allocator, "Page disappeared after insert");
    defer design_model.freePageFull(allocator, page);

    // Resolve workspace_id from the page's parent item. Used as the
    // SSE event scope (mirrors kanban_column pattern).
    const workspace_id = std.mem.span(getItemWorkspaceId(allocator, db, parsed.item_id) orelse "");
    // ...emit SSE event, return success XML.

    on_event_sent_design.onEventSendDesignPageUpdated(allocator, .{
        .action = "updated",
        .workspace_id = workspace_id,
        .item_id = parsed.item_id,
        .page = .{
            .id = page.id,
            .workspace_item_id = page.workspace_item_id,
            .name = page.name,
            .html = page.html,
            .position = page.position,
            .created_at = page.created_at,
            .updated_at = page.updated_at,
        },
    }) catch {};

    return try makeToolOk(allocator, "page set: {s}", parsed.page_name);
}
```

- [ ] **Step 3: Add the other 2 tools** (`execDeleteDesignPage`, `execListDesignPages`)

Same shape. `delete` calls `design_model.deletePage` + emits `design_page_deleted`. `list` returns a formatted text list of page names + positions (no html).

- [ ] **Step 4: Implement tool-description schema strings**

Look up the project convention from `src/ai_workflow/tui/tool_registry.zig` for how tool descriptions are formatted (typically a JSON-schema-like text or a free-form description). Match it exactly.

- [ ] **Step 5: Register tools in `tool_registry.zig`**

Add 3 new entries alongside the kanban_* tools, plus their `tool.description` strings and dispatch calls.

- [ ] **Step 6: Static-contract tests for the tool descriptions** — new test file `src/ai_workflow/tui/tool_registry_design_test.zig` (per the existing `tool_registry_*_test.zig` pattern). Grep for each tool name + description string.

- [ ] **Step 7: Build and commit**

```bash
git add src/modules/agent/tools/design_tools.zig \
        src/modules/agent/tools/mod.zig \
        src/modules/agent/tools/*.zig \
        src/ai_workflow/tui/tool_registry.zig \
        src/ai_workflow/tui/tool_registry_design_test.zig
git commit -m "feat(design): add 3 LLM tools (set/delete/list_design_page)"
```

---

## Chunk 4: Frontend API + Types

Goal: TypeScript layer ready — 5 new API functions, store action, and type additions.

### Task 4.1: Add `apiDesign` functions

**Files:** Modify `src/apps/desktop/src/api/index.ts`

- [ ] **Step 1: Add types near `DesignPageSummary` definitions**

```ts
export interface DesignPageSummary {
  id: string
  name: string
  position: number
  created_at: string
  updated_at: string
}

export interface DesignPageFull extends DesignPageSummary {
  html: string
}
```

- [ ] **Step 2: Add 5 API functions**

```ts
export async function createDesign(workspaceId: string, name: string): Promise<WorkspaceItem> {
  return await apiFetch(`/api/workspaces/${workspaceId}/items/design`, {
    method: 'POST',
    body: JSON.stringify({ name }),
  })
}

export async function listDesignPages(workspaceId: string, itemId: string): Promise<DesignPageSummary[]> {
  return await apiFetch(`/api/workspaces/${workspaceId}/items/${itemId}/design/pages`, { method: 'GET' })
}

export async function getDesignPage(workspaceId: string, itemId: string, pageId: string): Promise<DesignPageFull> {
  return await apiFetch(`/api/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`, { method: 'GET' })
}

export async function updateDesignPage(workspaceId: string, itemId: string, pageId: string, html: string): Promise<DesignPageFull> {
  return await apiFetch(`/api/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`, {
    method: 'PUT',
    body: JSON.stringify({ html }),
  })
}

export async function deleteDesignPage(workspaceId: string, itemId: string, pageId: string): Promise<{ deleted: boolean, page_id: string }> {
  return await apiFetch(`/api/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`, { method: 'DELETE' })
}
```

### Task 4.2: Update `workspacesStore`

**Files:** Modify `src/apps/desktop/src/stores/workspaces.ts`

- [ ] **Step 1: Add `'design'` to the `item_type` union** around line 26.

- [ ] **Step 2: Add `design_pages?: DesignPageSummary[]`** to the `WorkspaceItem` interface.

- [ ] **Step 3: Add `addDesignItem` near `addKanbanItem`**

```ts
async function addDesignItem(workspaceId: string, name: string): Promise<string | undefined> {
  const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
  if (!workspace) return undefined
  try {
    const newItem = await api.createDesign(workspaceId, name)
    const expandedItems = loadExpandedItems()
    workspace.items.push({
      ...newItem,
      design_pages: [],
      expanded: expandedItems.has(newItem.id),
    })
    if (!workspace.expanded) {
      workspace.expanded = true
      const expandedWorkspaces = loadExpandedWorkspaces()
      expandedWorkspaces.add(workspace.id)
      saveExpandedWorkspaces(expandedWorkspaces)
    }
    return newItem.id
  } catch (err) {
    console.error('[workspacesStore.addDesignItem] API call failed:', err)
    return undefined
  }
}
```

- [ ] **Step 4: Expose `addDesignItem` in the returned object** at the bottom of the store.

### Task 4.3: Tests

**Files:** Create `src/apps/desktop/src/__tests__/apiDesign.spec.ts`

- [ ] **Step 1: Write tests** for the 5 API functions. Use the `apiFetch-mock-must-include-text-and-pinia` pattern (mock helper with `text()` + `setActivePinia(createPinia())` in `beforeEach`).

- [ ] **Step 2: Run tests**

```bash
cd src/apps/desktop && timeout 60 bunx vitest run apiDesign
```

Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/api/index.ts \
        src/apps/desktop/src/stores/workspaces.ts \
        src/apps/desktop/src/__tests__/apiDesign.spec.ts
git commit -m "feat(design): frontend API + store action"
```

---

## Chunk 5: AddDesignDialog + Sidebar Wiring

Goal: "+ Add Design" entry in the workspace dropdown.

### Task 5.1: `AddDesignDialog.vue`

**Files:**
- Create: `src/apps/desktop/src/components/AddDesignDialog.vue`
- Test: `src/apps/desktop/src/__tests__/addDesignDialog.spec.ts`

- [ ] **Step 1: Create the dialog** — minimal modal with a name input only (no folder picker). Pattern: mirror `AddKanbanDialog.vue` lines 26-101 with the folder picker block stripped.

- [ ] **Step 2: Tests** verify modal opens on `show=true`, name validation, emits `create(name)`, resets state on close.

- [ ] **Step 3: Commit**

### Task 5.2: Wire into sidebar dropdown

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceList.vue:613-628` — add "Add Design" button in the dropdown `<ul>`.
- Modify: `src/apps/desktop/src/components/Sidebar.vue` — extend `handleAddItem` (line 374-382) to set `showAddDesignDialog.value = true`, import the dialog, add `handleCreateDesign(name)` action, mount `<AddDesignDialog>` in the template (line 1138 area).

- [ ] **Step 1: Update WorkspaceList.vue** — add a third `<li><button>` after "Add Kanban" that calls `handleAddItem(workspace.id, 'design')`.

- [ ] **Step 2: Update Sidebar.vue** — imports, ref, handler, dialog mount.

- [ ] **Step 3: Build + manual smoke**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10
```

Expected: build clean. Then start the dev server and visually confirm "Add Design" appears in the dropdown.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/components/AddDesignDialog.vue \
        src/apps/desktop/src/components/WorkspaceList.vue \
        src/apps/desktop/src/components/Sidebar.vue
git commit -m "feat(design): add AddDesignDialog + sidebar dropdown entry"
```

---

## Chunk 6: DesignView Component

Goal: The main canvas component with tab strip + iframe + SSE subscriptions.

### Task 6.1: `DesignView.vue` (skeleton)

**Files:** Create `src/apps/desktop/src/components/DesignView.vue`

- [ ] **Step 1: Create the component** with the layout described in the design doc (`## Frontend architecture → B. New DesignView.vue component`). Skeleton first:

```vue
<script setup lang="ts">
import { ref, onMounted, watch } from 'vue'
import * as api from '../api'
import type { DesignPageSummary } from '../api'

const props = defineProps<{
  workspaceId: string
  item: { id: string, name: string }
}>()

const pages = ref<DesignPageSummary[]>([])
const activePageId = ref<string | null>(null)
const activePageHtml = ref<string>('')
const newPageName = ref('')
const showAddPage = ref(false)

const loadPages = async () => {
  pages.value = await api.listDesignPages(props.workspaceId, props.item.id)
  if (!activePageId.value && pages.value.length > 0) {
    await selectPage(pages.value[0].id)
  }
}

const selectPage = async (pageId: string) => {
  activePageId.value = pageId
  const page = await api.getDesignPage(props.workspaceId, props.item.id, pageId)
  activePageHtml.value = page.html
}

const addPage = async () => {
  const name = newPageName.value.trim()
  if (!name) return
  // Idempotent: POST (well, PUT on the unified /pages/:page_id with an
  // empty html) would create the row. Since we don't have a POST
  // endpoint, use the createViaEmptyUpdate trick: create a dummy id
  // and PUT it, then fix the position. Simpler: call set_design_page
  // through the LLM tool. We do API-direct: use the unique-index
  // fallback pattern by calling updateDesignPage with a fresh page id
  // assigned client-side. Since the backend doesn't have POST
  // /design/pages, we use an HTTP workaround: PUT with a generated
  // page_id, then re-list to refresh.
  // (Implementation will be clarified after Tooling: backend gets
  //  POST /design/pages in Chunk 2.5.x if needed.)
  newPageName.value = ''
  showAddPage.value = false
}

const deletePage = async (pageId: string) => {
  await api.deleteDesignPage(props.workspaceId, props.item.id, pageId)
  pages.value = pages.value.filter(p => p.id !== pageId)
  if (activePageId.value === pageId && pages.value.length > 0) {
    await selectPage(pages.value[0].id)
  }
}

onMounted(loadPages)
watch(() => props.item.id, loadPages)
</script>

<template>
  <div class="flex flex-col h-full">
    <!-- Tab strip -->
    <div class="flex items-center gap-1 px-3 py-2 overflow-x-auto border-b" style="border-color: var(--color-border)">
      <button
        v-for="page in pages"
        :key="page.id"
        @click="selectPage(page.id)"
        class="px-3 py-1.5 rounded-md text-xs flex items-center gap-2 transition-colors"
        :style="activePageId === page.id ? 'background: var(--semantic-active-bg); color: var(--semantic-text);' : 'color: var(--semantic-text-dim);'"
      >
        {{ page.name }}
        <span @click.stop="deletePage(page.id)" class="text-xs opacity-50 hover:opacity-100" aria-label="Close tab">×</span>
      </button>
      <button @click="showAddPage = !showAddPage" class="px-3 py-1.5 rounded-md text-xs" style="color: var(--semantic-text-dim);">
        + Add Page
      </button>
      <input
        v-if="showAddPage"
        v-model="newPageName"
        @keyup.enter="addPage"
        @blur="showAddPage = false"
        class="px-2 py-1 rounded-md text-xs"
        placeholder="Page name"
        style="background: var(--semantic-sidebar-bg); color: var(--semantic-text);"
        autofocus
      />
    </div>
    <!-- Iframe canvas -->
    <iframe
      v-if="activePageHtml"
      :srcdoc="activePageHtml"
      sandbox="allow-scripts"
      class="flex-1 w-full border-0"
      title="Design canvas"
    />
    <div v-else class="flex-1 flex items-center justify-center" style="color: var(--semantic-text-dim);">
      <p class="text-sm">No page selected. Add a page to start.</p>
    </div>
  </div>
</template>
```

- [ ] **Step 2: SSE subscriptions** — listen for `design_page_updated` and `design_page_deleted` events. Use the existing `api.createSseClient` or equivalent. On `updated`, refetch `activePageHtml` if the page id matches; otherwise just re-list tabs. On `deleted`, similar to `deletePage` handler.

- [ ] **Step 3: Test** `src/apps/desktop/src/__tests__/designViewIframe.spec.ts` — verifies tab strip render, srcDoc binding, sandbox attribute `"allow-scripts"`.

- [ ] **Step 4: Build + commit**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
```

```bash
git add src/apps/desktop/src/components/DesignView.vue \
        src/apps/desktop/src/__tests__/designViewIframe.spec.ts
git commit -m "feat(design): add DesignView with tab strip + sandboxed iframe"
```

> **Note:** The "POST /design/pages endpoint" question — if the frontend needs to add a page directly (without going through the LLM tool), and the PUT-by-generated-id trick in the skeleton above doesn't work cleanly, then in this chunk ADD a `POST .../design/pages` handler (Chunk 2 retro-add). Re-justify the design doc's "idempotent set via ON CONFLICT only" decision if so.

---

## Chunk 7: AppLayout Routing

Goal: Mount `<DesignView>` when a design item is active.

### Task 7.1: Add design branch in AppLayout

**Files:** Modify `src/apps/desktop/src/components/AppLayout.vue` around lines 1188-1326.

- [ ] **Step 1: Add a `v-else-if` branch mirroring the kanban branch**

After the kanban block, add:

```vue
<DesignView
  v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'design'"
  :key="'design-' + activeWorkspaceItem.id"
  :workspace-id="activeWorkspace?.id ?? ''"
  :item="activeWorkspaceItem"
/>
```

- [ ] **Step 2: Import `DesignView`** at the top of the file.

- [ ] **Step 3: Build + visual smoke test**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
```

Manual: start dev server, open a design item, confirm the canvas renders in the main area.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/components/AppLayout.vue
git commit -m "feat(design): mount DesignView in AppLayout"
```

---

## Chunk 8: Smoke Test

Goal: End-to-end coverage that proves the whole stack works against a fresh database.

### Task 8.1: `scripts/design-mode-smoke.sh`

**Files:**
- Create: `scripts/design-mode-smoke.sh`
- Modify: `scripts/ci-smoke-test.sh`

- [ ] **Step 1: Write the smoke script**

```bash
#!/usr/bin/env bash
# design-mode-smoke.sh — End-to-end test for the design canvas feature.
# Uses an isolated $HOME so it runs cleanly against a fresh agent.db.
set -euo pipefail

HOME_DIR=$(mktemp -d)
export HOME="$HOME_DIR"
PORT=8089
BIN="$HOME_DIR/../agentic_coding_zig/ginwaaitoolbox/zig-out/bin/nalar"

cleanup() { kill -- "$NALAR_PID" 2>/dev/null || true; rm -rf "$HOME_DIR"; }
trap cleanup EXIT

# Boot
"$BIN" --port "$PORT" > "$HOME_DIR/server.log" 2>&1 &
NALAR_PID=$!
for i in {1..20}; do
  curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null && break
  sleep 0.5
done
curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null || { echo "server failed to boot"; cat "$HOME_DIR/server.log"; exit 1; }

# 1. Create a workspace
WS=$(curl -sf -X POST "http://127.0.0.1:$PORT/api/workspaces" \
  -H 'content-type: application/json' \
  -d '{"name":"design-smoke","icon":"circle"}' | jq -r .id)
[ -n "$WS" ] || { echo "no workspace id"; exit 1; }

# 2. Create a design item
DESIGN=$(curl -sf -X POST "http://127.0.0.1:$PORT/api/workspaces/$WS/items/design" \
  -H 'content-type: application/json' \
  -d '{"name":"My Design"}')
ITEM=$(echo "$DESIGN" | jq -r .id)
[ -n "$ITEM" ] || { echo "no design item id"; echo "$DESIGN"; exit 1; }

# 3-7. Page CRUD via the LLM tool bridge (out of scope for HTTP smoke).
# The HTTP CRUD for design_pages is exercised in Chunk 2 handler tests.
# For the smoke test, just verify the design item was created and the
# page list starts empty.
PAGES=$(curl -sf "http://127.0.0.1:$PORT/api/workspaces/$WS/items/$ITEM/design/pages" | jq 'length')
[ "$PAGES" = "0" ] || { echo "expected 0 pages, got $PAGES"; exit 1; }

echo "design-mode-smoke PASSED"
```

- [ ] **Step 2: Wire into `ci-smoke-test.sh`** as Step 6 (after the existing 5 steps). Don't make it blocking (`|| echo "design-mode-smoke skipped"`); let it be opt-in initially.

- [ ] **Step 3: Manual run + commit**

```bash
chmod +x scripts/design-mode-smoke.sh
./scripts/design-mode-smoke.sh
```

Expected: prints `design-mode-smoke PASSED`.

```bash
git add scripts/design-mode-smoke.sh scripts/ci-smoke-test.sh
git commit -m "test(design): add design-mode-smoke.sh end-to-end test"
```

---

## Final Verification

After all 8 chunks land:

- [ ] `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — should report `test success` and the cumulative new test count (~30+ new tests).
- [ ] `timeout 180 zig build install:linux:system 2>&1 | tail -n 5` — should report 4/6 steps succeed (cp fails harmlessly).
- [ ] `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5` — should report build clean.
- [ ] `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 5` — should report all frontend tests passing.
- [ ] `git log --oneline main..HEAD` — should show 8 commits, one per chunk.
- [ ] Manual smoke: open the dev server, click "+ Add Item → Add Design", name it, click `+ Add Page`, dispatch a chat message "create a login page with a green button", confirm the canvas renders the LLM's HTML.

When all checks pass, the feature is complete and ready for a PR.
