# Design Mode Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the v5 design-mode ship (panzoom canvas, 5 LLM tools, fragile file-sync) with a Figma-lite design mode (drag/resize + layers panel + properties panel) served by 3 LLM tools, keeping the file-backed HTML model.

**Architecture:**
- Backend (Zig 0.16): rewrite `design_model.zig` around page + element CRUD; 9 HTTP handlers; 3 LLM tools; SSE events
- Frontend (Vue 3 + TypeScript): rewrite `DesignView.vue` and add 6 new components; extend store + API layer; new SSE channel
- Migration 057 (purely additive): add 11 new columns to `design_page_elements` for Figma-lite properties
- v5 work is in-place deleted (`feature/design-mode` → `worktree/design-mode-redesign` rewrite)

**Tech Stack:** Zig 0.16 (backend, project memory `zig-cross-platform-blockers-and-fixes.md`), SQLite (project memory `sqlite-backend-empty-slice-binds-as-null.md`), Vue 3 + Tailwind v4 + Kanagawa theme, Pinia, @vue/test-utils + Vitest, Bun (project memory `desktop-typescript-bun-build-as-typecheck.md`).

---

## File Structure

### Files to delete (v5 ship)
- `src/ai_workflow/tui/design_model.zig` → replaced
- `src/ai_workflow/tui/design_model_test.zig` → replaced
- `src/ai_workflow/tui/on_event_design.zig` → replaced
- `src/ai_workflow/tui/on_event_sent_design.zig` → replaced
- `src/ai_workflow/tui/on_event_sent_design_test.zig` → replaced
- `src/ai_workflow/tui/http_handlers/design_*` (12 files: pages + elements + tests) → replaced
- `src/modules/agent/tools/design_page*.zig` + tests (5 files) → replaced
- `src/apps/desktop/src/components/DesignView.vue` → replaced
- `src/apps/desktop/src/__tests__/DesignView.spec.ts` → replaced
- `src/apps/desktop/src/__tests__/stubs/panzoom.ts` → DELETE (panzoom no longer used)
- `src/apps/desktop/src/__tests__/apiDesign.spec.ts` → replaced
- `src/apps/desktop/vitest.config.ts` reference to panzoom stub → DELETE

### Files to create (v6 ship)
- **Backend (data + http + tools):**
  - `src/ai_workflow/tui/design_model.zig` (rewrite, ~600 lines)
  - `src/ai_workflow/tui/design_model_test.zig` (rewrite, ~700 lines)
  - `src/ai_workflow/tui/migration_057_test.zig` (new, ~120 lines)
  - `src/ai_workflow/tui/on_event_design.zig` (rewrite, ~50 lines)
  - `src/ai_workflow/tui/on_event_sent_design.zig` (rewrite, ~100 lines)
  - `src/ai_workflow/tui/on_event_sent_design_test.zig` (rewrite, ~150 lines)
  - `src/ai_workflow/tui/http_handlers/design_pages_list.zig` + test
  - `src/ai_workflow/tui/http_handlers/design_pages_create.zig` + test
  - `src/ai_workflow/tui/http_handlers/design_pages_get.zig` + test
  - `src/ai_workflow/tui/http_handlers/design_elements_create.zig` + test
  - `src/ai_workflow/tui/http_handlers/design_elements_update.zig` + test
  - `src/ai_workflow/tui/http_handlers/design_elements_delete.zig` + test
  - `src/ai_workflow/tui/http_handlers/design_elements_html_get.zig` + test
  - `src/ai_workflow/tui/http_handlers/design_elements_html_update.zig` + test
  - `src/ai_workflow/tui/http_handlers/design_elements_geometry_update.zig` + test
  - `src/modules/agent/tools/set_design_page.zig` + test
  - `src/modules/agent/tools/add_design_element.zig` + test
  - `src/modules/agent/tools/update_design_element.zig` + test
- **Frontend (Vue + TS):**
  - `src/apps/desktop/src/stores/designSse.ts` (new, ~150 lines)
  - `src/apps/desktop/src/components/DesignView.vue` (rewrite, ~600 lines)
  - `src/apps/desktop/src/components/DesignElement.vue` (new, ~250 lines)
  - `src/apps/desktop/src/components/DesignPageTabs.vue` (new, ~100 lines)
  - `src/apps/desktop/src/components/LayersPanel.vue` (new, ~200 lines)
  - `src/apps/desktop/src/components/PropertiesPanel.vue` (new, ~400 lines)
  - `src/apps/desktop/src/components/DesignElementPreview.vue` (new, ~80 lines)
  - `src/apps/desktop/src/components/DesignElementEditor.vue` (new, ~150 lines)
  - `src/apps/desktop/src/components/AddDesignElementDialog.vue` (new, ~150 lines)
  - `src/apps/desktop/src/__tests__/DesignView.spec.ts` (rewrite, ~400 lines)
  - `src/apps/desktop/src/__tests__/apiDesign.spec.ts` (rewrite, ~350 lines)
  - `src/apps/desktop/src/__tests__/designSseStore.spec.ts` (new, ~200 lines)
  - `scripts/design-mode-smoke.sh` (extend with element CRUD)

### Files to modify
- `src/ai_workflow/tui/migration.zig` (add Migration057AddDesignElementProperties)
- `src/ai_workflow/tui/mod.zig` (re-export new modules)
- `src/ai_workflow/tui/http_handlers/mod.zig` (re-export new handlers)
- `src/ai_workflow/tui/http_handlers/http_response.zig` (add DesignElementResponse + DesignPageResponse)
- `src/main.zig` (register 9 routes)
- `src/ai_workflow/tui/tool_registry.zig` (register 3 tools + allAgentTools entries)
- `src/ai_workflow/tui/test_runner.zig` (add 6+ new _test.zig imports)
- `src/root.zig` (re-export 3 new tools)
- `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` (update BuildDesignCanvasPrompt to mention 3 tools)
- `src/apps/desktop/src/api/index.ts` (add 9 API functions + interfaces + bus channel)
- `src/apps/desktop/src/helpers/sseBus.ts` (add design channel)
- `src/apps/desktop/src/stores/workspaces.ts` (add design_elements + new actions)
- `src/apps/desktop/src/components/AppLayout.vue` (add design v-else-if branches)
- `src/apps/desktop/src/components/WorkspaceItem.vue` (add design discriminator)
- `src/apps/desktop/src/components/Sidebar.vue` (add design path check)
- `package.json` (add `monaco-editor` lazy-load code-split if needed)

**Total: ~35 files deleted, ~25 files created, ~15 modified.**

---

## Chunk 1: Backend foundation (Migration + Model)

### Task 1.1: Migration 057 — Add new columns to design_page_elements

**Files:**
- Modify: `src/ai_workflow/tui/migration.zig` (add `Migration057AddDesignElementProperties`)
- Create: `src/ai_workflow/tui/migration_057_test.zig`

The migration adds the 11 new columns from design §5.1. Migration 056 (the v5 `add_design_pages` → `upgrade_design_pages_to_file_model`) already exists at `migration.zig:1133+`. Migration 057 must be ADDITIVE — never drop a column.

Reference patterns:
- `Migration051AddKanban` at `migration.zig:948-999` (simple CREATE TABLE — too simple)
- `Migration053AddKanbanColumnDescription` at `migration.zig:1059-1088` (ADD COLUMN pattern — USE THIS)
- `Migration054MakeSessionQueueMessageNullable` at `migration.zig:1133-1203` (table-recreate pattern — too complex)
- `addColumnIfMissing` helper at `migration.zig:1311-1334` (use this for safety)

- [ ] **Step 1: Write the failing migration test**

Create `src/ai_workflow/tui/migration_057_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const sqlite = nalarcore.sqlite;
const helpers = nalarcore.helpers;

test "migration 057 adds the new columns to design_page_elements" {
    // Setup: in-memory DB + workspace_items + design_pages + design_page_elements (v5 schema)
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(testing.allocator,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL, name TEXT, path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME
        \\)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE design_pages (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '', width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024, x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '', x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0, width INTEGER NOT NULL DEFAULT 375,
        \\    height INTEGER NOT NULL DEFAULT 667, z_index INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0, created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    try helpers.Migration055AddDesignPages.up(&db, testing.allocator);
    try helpers.Migration056UpgradeDesignPagesToFileModel.up(&db, testing.allocator);
    try helpers.Migration057AddDesignElementProperties.up(&db, testing.allocator);

    // Verify the 11 new columns exist
    var q = try db.query(testing.allocator,
        \\SELECT name FROM pragma_table_info('design_page_elements')
        \\WHERE name IN ('type','rotation','fill','stroke','stroke_width','corner_radius',
        \\                'opacity','text_content','text_style','image_url','parent_id')
        \\ORDER BY name
    , &.{});
    defer q.deinit();
    var found: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(testing.allocator);
        found += 1;
    }
    try testing.expectEqual(@as(usize, 11), found);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 180 zig build test --summary all 2>&1 | grep -E "migration_057|FAIL|error:"`
Expected: Compile error `Migration057AddDesignElementProperties not found`.

- [ ] **Step 3: Write Migration 057**

Add to `src/ai_workflow/tui/migration.zig` (after Migration056, before the `dropColumnIfExists` helper):

```zig
pub const Migration057AddDesignElementProperties = struct {
    pub const version: u32 = 57;
    pub const name = "add_design_element_properties";

    pub fn up(db: *sqlite.SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Use addColumnIfMissing (defined at migration.zig:1311+) — idempotent and safe
        try addColumnIfMissing(db, allocator, "design_page_elements", "type",
            "TEXT NOT NULL DEFAULT 'rectangle'");
        try addColumnIfMissing(db, allocator, "design_page_elements", "rotation",
            "REAL NOT NULL DEFAULT 0");
        try addColumnIfMissing(db, allocator, "design_page_elements", "fill",
            "TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(db, allocator, "design_page_elements", "stroke",
            "TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(db, allocator, "design_page_elements", "stroke_width",
            "INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(db, allocator, "design_page_elements", "corner_radius",
            "INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(db, allocator, "design_page_elements", "opacity",
            "REAL NOT NULL DEFAULT 1.0");
        try addColumnIfMissing(db, allocator, "design_page_elements", "text_content",
            "TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(db, allocator, "design_page_elements", "text_style",
            "TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(db, allocator, "design_page_elements", "image_url",
            "TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(db, allocator, "design_page_elements", "parent_id",
            "TEXT");

        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
```

Also add to `allMigrations[]` at the bottom of the file:
```zig
.{ .version = Migration057AddDesignElementProperties.version, .name = Migration057AddDesignElementProperties.name, .up = Migration057AddDesignElementProperties.up },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `timeout 180 zig build test --summary all 2>&1 | grep -E "migration_057"`
Expected: Test passes with `11 == 11`.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/migration.zig src/ai_workflow/tui/migration_057_test.zig
git commit -m "feat(design): migration 057 — add v6 element properties columns"
```

### Task 1.2: File IO utilities (atomic write, sanitize, cleanup)

**Files:**
- Create: `src/ai_workflow/tui/design_io.zig` (new file)
- Create: `src/ai_workflow/tui/design_io_test.zig`

These utilities are used by `design_model.zig` and the HTTP handlers. They encapsulate the v6 file-backed fix: atomic writes via `writeTemp + fsync + renameat2`, path sanitization, orphan cleanup.

- [ ] **Step 1: Write failing tests for `design_io`**

```zig
const std = @import("std");
const testing = std.testing;
const design_io = @import("design_io.zig");

test "sanitizeFilename strips / and .. and NUL" {
    try testing.expectEqualStrings("login_card", try design_io.sanitizeFilename(testing.allocator, "login/card"));
    try testing.expectEqualStrings("etc_passwd", try design_io.sanitizeFilename(testing.allocator, "../../etc/passwd"));
    try testing.expectEqualStrings("hidden", try design_io.sanitizeFilename(testing.allocator, ".hidden"));
    try testing.expectEqualStrings("normal", try design_io.sanitizeFilename(testing.allocator, "normal"));
}

test "atomicWriteFile creates file with fsync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathAlloc(testing.allocator, "test.html");
    defer testing.allocator.free(path);
    try design_io.atomicWriteFile(testing.allocator, path, "<div>hello</div>");
    // Read back
    const content = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("<div>hello</div>", content);
}

test "deleteFileIfExists succeeds when missing (no error)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathAlloc(testing.allocator, "missing.html");
    defer testing.allocator.free(path);
    // No file exists — should not error
    try design_io.deleteFileIfExists(testing.allocator, path);
}
```

- [ ] **Step 2: Run tests — should fail with "module not found"**

`timeout 180 zig build test 2>&1 | grep "design_io"`
Expected: Compile error.

- [ ] **Step 3: Write `design_io.zig`**

```zig
const std = @import("std");
const c = std.c;

/// Strip path-traversal characters from a user-provided name.
/// Returns a name that's safe to use as a file/folder component.
/// Replaces `/`, `\`, NUL, and leading `.` with `_`.
/// Caller owns the returned slice.
pub fn sanitizeFilename(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (name) |ch| {
        switch (ch) {
            '/', '\\', 0 => try out.append(allocator, '_'),
            else => try out.append(allocator, ch),
        }
    }
    // Strip leading dots (hidden file convention)
    while (out.items.len > 0 and out.items[0] == '.') {
        _ = out.orderedRemove(0);
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "untitled");
    return out.toOwnedSlice(allocator);
}

/// Atomically write `content` to `path`:
/// 1. Write to `<path>.tmp`
/// 2. `fsync(2)` the tmp file
/// 3. `rename(2)` tmp to `path` (atomic on POSIX)
pub fn atomicWriteFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    _ = allocator;
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path});
    // Write content
    const fd = try c.open(tmp_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644);
    defer _ = c.close(fd);
    var written: usize = 0;
    while (written < content.len) {
        const n = c.write(fd, content[written..].ptr, content[written..].len);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
    // fsync
    _ = c.fsync(fd);
    // Atomic rename
    if (c.rename(tmp_path.ptr, path.ptr) != 0) return error.RenameFailed;
}

/// Unlink `path` if it exists. Does NOT error when the file is missing.
pub fn deleteFileIfExists(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    _ = c.unlink(path.ptr); // POSIX unlink returns -1 + ENOENT when missing — we ignore
}

/// Recursively delete a directory and all its contents.
/// Uses libc walk + unlink + rmdir.
pub fn deleteDirectoryRecursively(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, path, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(entry_path);
        switch (entry.kind) {
            .file => try deleteFileIfExists(allocator, entry_path),
            .directory => try deleteDirectoryRecursively(allocator, entry_path),
            else => {},
        }
    }
    _ = c.rmdir(path.ptr);
}
```

- [ ] **Step 4: Run tests — should all pass**

`timeout 180 zig build test 2>&1 | grep -E "design_io|PASS|FAIL"`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/design_io.zig src/ai_workflow/tui/design_io_test.zig
git commit -m "feat(design): add design_io utilities (atomic write, sanitize, cleanup)"
```

### Task 1.3: Rewrite `design_model.zig` — page CRUD

**Files:**
- Modify: `src/ai_workflow/tui/design_model.zig` (rewrite, keep file-backed behavior)

Delete the v5 file, write a new one focused on the 3-tool surface. Mirrors `kanban_model.zig` exactly.

- [ ] **Step 1: Write failing tests for page CRUD**

Create `src/ai_workflow/tui/design_model_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const sqlite = nalarcore.sqlite;
const helpers = nalarcore.helpers;
const design_model = @import("design_model.zig");
const design_io = @import("design_io.zig");

fn setupDbAndItem(allocator: std.mem.Allocator) !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []u8,
    workspace_id: []u8,
    item_path: []u8,
} {
    var threaded = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(allocator,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL, name TEXT, path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0, created_at DATETIME, updated_at DATETIME)
    , &.{});
    try db.exec(allocator,
        \\CREATE TABLE design_pages (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '', width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024, x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});
    try db.exec(allocator,
        \\CREATE TABLE design_page_elements (id TEXT PRIMARY KEY, page_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '', file_path TEXT NOT NULL DEFAULT '',
        \\    x INTEGER NOT NULL DEFAULT 0, y INTEGER NOT NULL DEFAULT 0,
        \\    width INTEGER NOT NULL DEFAULT 375, height INTEGER NOT NULL DEFAULT 667,
        \\    z_index INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        \\    type TEXT NOT NULL DEFAULT 'rectangle', rotation REAL NOT NULL DEFAULT 0,
        \\    fill TEXT NOT NULL DEFAULT '', stroke TEXT NOT NULL DEFAULT '',
        \\    stroke_width INTEGER NOT NULL DEFAULT 0, corner_radius INTEGER NOT NULL DEFAULT 0,
        \\    opacity REAL NOT NULL DEFAULT 1.0, text_content TEXT NOT NULL DEFAULT '',
        \\    text_style TEXT NOT NULL DEFAULT '', image_url TEXT NOT NULL DEFAULT '',
        \\    parent_id TEXT, FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    const workspace_id = try allocator.dupe(u8, "ws_test");
    const item_id = try allocator.dupe(u8, "item_test");
    const item_path = try std.fs.path.join(allocator, &.{
        try std.testing.tmpDir_alloc.allocator.dupe(u8, std.testing.tmpDir.?.dir.path orelse "/tmp"),
        "design_mode_test",
    });
    defer testing.allocator.free(item_path);
    try db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) VALUES (?, ?, 'design', ?)",
        &.{ item_id, workspace_id, item_path });
    return .{ .db = db, .threaded = threaded, .item_id = item_id, .workspace_id = workspace_id, .item_path = item_path };
}

test "listPages on empty item returns empty slice" {
    const allocator = testing.allocator;
    const ctx = try setupDbAndItem(allocator);
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const pages = try design_model.listPages(allocator, &ctx.db, ctx.item_id);
    defer allocator.free(pages);
    try testing.expectEqual(@as(usize, 0), pages.len);
}

test "setDesignPage creates a new page on first call" {
    const allocator = testing.allocator;
    const ctx = try setupDbAndItem(allocator);
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const page_id = try design_model.setDesignPage(allocator, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer allocator.free(page_id);
    try testing.expect(page_id.len > 0);
}

test "setDesignPage is idempotent (same name updates width)" {
    const allocator = testing.allocator;
    const ctx = try setupDbAndItem(allocator);
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const id1 = try design_model.setDesignPage(allocator, &ctx.db, .{ .item_id = ctx.item_id, .page_name = "Login", .width = 1440, .height = 1024 });
    defer allocator.free(id1);
    const id2 = try design_model.setDesignPage(allocator, &ctx.db, .{ .item_id = ctx.item_id, .page_name = "Login", .width = 800, .height = 600 });
    defer allocator.free(id2);
    try testing.expectEqualStrings(id1, id2);
}
```

- [ ] **Step 2: Run tests — should fail**

- [ ] **Step 3: Implement `design_model.zig` page CRUD**

Write a fresh file. Mirror `kanban_model.zig` structure (`KanbanColumn` → `DesignPage`):

```zig
const std = @import("std");
const sqlite = nalarcore.sqlite;
const design_io = @import("design_io.zig");

pub const DesignPage = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    width: i64,
    height: i64,
    position: i64,
    created_at: []u8,
    updated_at: []u8,

    pub fn deinit(self: DesignPage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.workspace_item_id);
        allocator.free(self.name);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
    }
};

pub const SetDesignPageInput = struct {
    item_id: []const u8,
    page_name: []const u8,
    width: i64,
    height: i64,
};

pub const SetDesignPageError = error{
    ItemPathMissing,
    BadPageName,
    DbError,
    OutOfMemory,
};

pub fn setDesignPage(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, input: SetDesignPageInput) SetDesignPageError![]u8 {
    if (input.page_name.len == 0) return error.BadPageName;
    // Look up the design item's path
    const path_opt: ?[]u8 = blk: {
        var q = try db.query(allocator, "SELECT path FROM workspace_items WHERE id = ? AND item_type = 'design'",
            &.{input.item_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            if (row.values[0].len == 0) break :blk null;
            break :blk try allocator.dupe(u8, row.values[0]);
        }
        break :blk null;
    };
    defer if (path_opt) |p| allocator.free(p);
    if (path_opt == null) return error.ItemPathMissing;

    // Idempotent insert
    const id = try helpers.unixTimestampNanosId(allocator, "page_");
    errdefer allocator.free(id);
    try db.exec(allocator,
        \\INSERT INTO design_pages (id, workspace_item_id, name, width, height, position, created_at, updated_at)
        \\VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(position) FROM design_pages WHERE workspace_item_id = ?), -1) + 1, datetime('now'), datetime('now'))
        \\ON CONFLICT(workspace_item_id, name) DO UPDATE SET
        \\    width = excluded.width, height = excluded.height, updated_at = datetime('now')
    , &.{ id, input.item_id, input.page_name, input.width, input.height, input.item_id });
    return allocator.dupe(u8, id);
}

pub fn listPages(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, item_id: []const u8) ![]DesignPage {
    var q = try db.query(allocator,
        \\SELECT id, workspace_item_id, name, width, height, position,
        \\       COALESCE(created_at, ''), COALESCE(updated_at, '')
        \\FROM design_pages
        \\WHERE workspace_item_id = ?
        \\ORDER BY position ASC
    , &.{item_id});
    defer q.deinit();
    var rows = std.ArrayList(DesignPage).empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_item_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .width = try std.fmt.parseInt(i64, row.values[3], 10),
            .height = try std.fmt.parseInt(i64, row.values[4], 10),
            .position = try std.fmt.parseInt(i64, row.values[5], 10),
            .created_at = try allocator.dupe(u8, row.values[6]),
            .updated_at = try allocator.dupe(u8, row.values[7]),
        });
    }
    return rows.toOwnedSlice(allocator);
}

// Additional functions (deletePage, getPage, etc.) — covered in sub-tasks
```

- [ ] **Step 4: Run tests — should all pass**

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/design_model.zig src/ai_workflow/tui/design_model_test.zig
git commit -m "feat(design): design_model.zig — page CRUD (idempotent setDesignPage)"
```

### Task 1.4: design_model.zig — `addElement` + `updateElement`

Mirror `kanban_model.addColumn` + `updateColumn`. The `addElement` writes an HTML file atomically (via `design_io.atomicWriteFile`).

- [ ] **Step 1: Write failing test for addElement**

```zig
test "addElement creates a row + writes the HTML file" {
    const ctx = try setupDbAndItem(allocator);
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    // Create a page first
    const page_id = try design_model.setDesignPage(allocator, &ctx.db, .{ .item_id = ctx.item_id, .page_name = "Login", .width = 1440, .height = 1024 });
    defer allocator.free(page_id);
    // Add an element
    const element_id = try design_model.addElement(allocator, &ctx.db, .{
        .page_id = page_id,
        .name = "login-card",
        .type = .rectangle,
        .html = "<div>Login</div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0, .corner_radius = 0, .opacity = 1.0,
    });
    defer allocator.free(element_id);
    // Verify file exists and content
    const file_path = try std.fmt.allocPrint(allocator, "{s}/.nalar/design/Login/login-card.html", .{ctx.item_path});
    defer allocator.free(file_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, allocator, .limited(1024));
    defer allocator.free(content);
    try testing.expectEqualStrings("<div>Login</div>", content);
}
```

- [ ] **Step 2: Implement `addElement`**

```zig
pub const ElementType = enum { rectangle, ellipse, text, image, frame, group };

pub const AddElementInput = struct {
    page_id: []const u8,
    name: []const u8,
    type: ElementType,
    html: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    fill: []const u8,
    rotation: f64,
    corner_radius: i64,
    opacity: f64,
    text_content: []const u8 = "",
    text_style: []const u8 = "",
    image_url: []const u8 = "",
};

pub const AddElementError = error{
    PageNotFound,
    ItemPathMissing,
    DuplicateName,
    BadName,
    FileWriteFailed,
    DbError,
    OutOfMemory,
};

pub fn addElement(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, input: AddElementInput) AddElementError![]u8 {
    if (input.name.len == 0) return error.BadName;

    // Look up the page to get item_id + page name + item path
    const Lookup = struct { item_id: []u8, page_name: []u8, item_path: []u8 };
    const lookup: Lookup = blk: {
        var q = try db.query(allocator,
            \\SELECT dp.workspace_item_id, dp.name, wi.path
            \\FROM design_pages dp JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE dp.id = ?
        , &.{input.page_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.PageNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .item_id = try allocator.dupe(u8, row.values[0]),
            .page_name = try allocator.dupe(u8, row.values[1]),
            .item_path = try allocator.dupe(u8, row.values[2]),
        };
    };
    defer allocator.free(lookup.item_id);
    defer allocator.free(lookup.page_name);
    defer allocator.free(lookup.item_path);
    if (lookup.item_path.len == 0) return error.ItemPathMissing;

    // Build file path
    const sanitized_page = try design_io.sanitizeFilename(allocator, lookup.page_name);
    defer allocator.free(sanitized_page);
    const sanitized_elem = try design_io.sanitizeFilename(allocator, input.name);
    defer allocator.free(sanitized_elem);
    const page_dir = try std.fmt.allocPrint(allocator, "{s}/.nalar/design/{s}", .{ lookup.item_path, sanitized_page });
    defer allocator.free(page_dir);
    // Make sure the page directory exists
    try std.Io.Dir.cwd().makeDirPath(std.testing.io, page_dir);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ page_dir, sanitized_elem });
    defer allocator.free(file_path);
    // Atomic write the HTML
    design_io.atomicWriteFile(allocator, file_path, input.html) catch return error.FileWriteFailed;

    // Insert the row
    const id = try helpers.unixTimestampNanosId(allocator, "elem_");
    errdefer allocator.free(id);
    const type_str = @tagName(input.type);
    try db.exec(allocator,
        \\INSERT INTO design_page_elements (
        \\    id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, created_at, updated_at
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0,
        \\    COALESCE((SELECT MAX(position) FROM design_page_elements WHERE page_id = ?), -1) + 1,
        \\    ?, ?, ?, '', 0, ?, 1.0, '', '', '', datetime('now'), datetime('now'))
    , &.{
        id, input.page_id, input.name, file_path,
        input.x, input.y, input.width, input.height, input.page_id,
        type_str, input.rotation, input.fill, input.corner_radius,
    });
    return allocator.dupe(u8, id);
}
```

- [ ] **Step 3: Implement `updateElement` + write its test**

`updateElement` updates the row fields AND (if `html` is changed) rewrites the file atomically.

```zig
pub const UpdateElementInput = struct {
    element_id: []const u8,
    name: ?[]const u8 = null,
    type: ?ElementType = null,
    html: ?[]const u8 = null,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
    fill: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    stroke_width: ?i64 = null,
    corner_radius: ?i64 = null,
    opacity: ?f64 = null,
    text_content: ?[]const u8 = null,
    text_style: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
};

pub fn updateElement(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, input: UpdateElementInput) ![]u8 {
    // Build dynamic UPDATE
    var sets: std.ArrayList([]const u8) = .empty;
    defer sets.deinit(allocator);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    if (input.name) |v| { try sets.append(allocator, "name = ?"); try args.append(allocator, v); }
    if (input.type) |v| { const s = @tagName(v); try sets.append(allocator, "type = ?"); try args.append(allocator, s); }
    if (input.x) |v| { try sets.append(allocator, "x = ?"); try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v})); }
    // ... (similar for y, width, height, rotation, fill, stroke, stroke_width, corner_radius, opacity, text_content, text_style, image_url)

    // If html changed, rewrite the file
    if (input.html) |new_html| {
        // Look up file_path
        var q = try db.query(allocator, "SELECT file_path FROM design_page_elements WHERE id = ?", &.{input.element_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.ElementNotFound;
        defer row.deinit(allocator);
        const file_path = try allocator.dupe(u8, row.values[0]);
        defer allocator.free(file_path);
        design_io.atomicWriteFile(allocator, file_path, new_html) catch return error.FileWriteFailed;
        try sets.append(allocator, "updated_at = datetime('now')");
    }

    if (sets.items.len == 0) return error.NoChanges;
    try sets.append(allocator, "updated_at = datetime('now')");

    // Construct the UPDATE statement
    var sql_buf: [4096]u8 = undefined;
    var sql = std.fs.path.fmtBuffer(&sql_buf, "UPDATE design_page_elements SET ") catch return error.SqlTooLong;
    for (sets.items, 0..) |s, i| {
        if (i > 0) sql = std.fs.path.fmtAppendBuffer(&sql_buf, sql, ", ", .{}) catch return error.SqlTooLong;
        sql = std.fs.path.fmtAppendBuffer(&sql_buf, sql, s, .{}) catch return error.SqlTooLong;
    }
    sql = std.fs.path.fmtAppendBuffer(&sql_buf, sql, " WHERE id = ?", .{}) catch return error.SqlTooLong;
    try args.append(allocator, input.element_id);

    try db.exec(allocator, sql, args.items);
    return allocator.dupe(u8, input.element_id);
}
```

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

### Task 1.5: design_model.zig — list/get with all elements + delete

- [ ] **Step 1: Implement `getPageWithElements` + `listPagesWithElements`**

These return a page struct that includes all elements (excluding HTML bodies — lazy-loaded via separate endpoint).

- [ ] **Step 2: Implement `deleteElement` (unlinks the file via defer-pattern)**

```zig
pub fn deleteElement(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, element_id: []const u8) !bool {
    // Look up file_path BEFORE delete
    var q = try db.query(allocator, "SELECT file_path FROM design_page_elements WHERE id = ?", &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return false;
    defer row.deinit(allocator);
    const file_path = try allocator.dupe(u8, row.values[0]);
    defer allocator.free(file_path);
    // Delete row first
    try db.exec(allocator, "DELETE FROM design_page_elements WHERE id = ?", &.{element_id});
    // Defer-pattern: unlink file AFTER SQL succeeds
    design_io.deleteFileIfExists(allocator, file_path) catch {};
    return true;
}
```

- [ ] **Step 3: Implement `loadElementHtml` (read file to string)**

```zig
pub fn loadElementHtml(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, element_id: []const u8) ![]u8 {
    var q = try db.query(allocator, "SELECT file_path FROM design_page_elements WHERE id = ?", &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(allocator);
    return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, row.values[0], allocator, .limited(5 * 1024 * 1024));
}
```

- [ ] **Step 4: Add tests + commit**

```bash
git add src/ai_workflow/tui/design_model.zig src/ai_workflow/tui/design_model_test.zig
git commit -m "feat(design): design_model.zig — element CRUD with file IO"
```

### Task 1.6: Register new test files + verify migration registration

- [ ] **Step 1: Register new tests in `src/ai_workflow/tui/test_runner.zig`**

Append at end (alphabetical order matching existing pattern):
```zig
_ = @import("design_io_test.zig");
_ = @import("design_model_test.zig");
_ = @import("migration_057_test.zig");
```

- [ ] **Step 2: Re-export modules in `src/ai_workflow/tui/mod.zig`**

```zig
pub const design_io = @import("design_io.zig");
pub const design_model = @import("design_model.zig");
```

- [ ] **Step 3: Run full test suite — verify no regressions**

`timeout 240 zig build test --summary all 2>&1 | tail -5`
Expected: All existing tests still pass + 3 new design_io tests + design_model_test + migration_057_test.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/test_runner.zig src/ai_workflow/tui/mod.zig
git commit -m "feat(design): register design_io + design_model + migration_057 tests"
```

---

## Chunk 2: SSE Event Layer

### Task 2.1: `on_event_design.zig` — 3 payload structs

**Files:**
- Create: `src/ai_workflow/tui/on_event_design.zig` (rewrite, ~50 lines)

- [ ] **Step 1: Write the file**

```zig
pub const DesignElementCreatedData = struct {
    action: []const u8,        // "created"
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
};

pub const DesignElementUpdatedData = struct {
    action: []const u8,        // "updated"
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
};

pub const DesignElementDeletedData = struct {
    action: []const u8,        // "deleted"
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
};
```

### Task 2.2: `on_event_sent_design.zig` — 3 emitter functions

- [ ] **Step 1: Write the file**

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const on_event_design = @import("on_event_design.zig");

const SseEvent = nalarcore.on_event_sent.SseEvent;

fn emit(allocator: std.mem.Allocator, routing_key: []const u8, data: anytype) !void {
    const json_payload = try std.json.Stringify.valueAlloc(allocator, data, .{});
    defer allocator.free(json_payload);
    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, routing_key, .{
        .session_id = routing_key,
        .data = json_payload,
    });
}

pub fn onEventSendDesignElementCreated(allocator: std.mem.Allocator, data: on_event_design.DesignElementCreatedData) !void {
    try emit(allocator, "design_element", data);
}
// Similar for Updated + Deleted
```

### Task 2.3: Wire emitters into `design_model.zig`

Modify `addElement`, `updateElement`, `deleteElement` to call the emitter after the SQL succeeds. Use `defer` pattern: emit after return.

### Task 2.4: Tests + commit

- [ ] **Static-contract test** for emitter functions
- [ ] Commit

```bash
git add src/ai_workflow/tui/on_event_design.zig src/ai_workflow/tui/on_event_sent_design.zig src/ai_workflow/tui/on_event_sent_design_test.zig src/ai_workflow/tui/design_model.zig
git commit -m "feat(design): SSE events for element create/update/delete"
```

---

## Chunk 3: HTTP Handlers (REST API)

9 handlers total. Each follows the canonical pattern (see design §7.3).

### Task 3.1: Page list + create + get handlers

- [ ] **Create** `src/ai_workflow/tui/http_handlers/design_pages_list.zig` — `GET /design/pages`
- [ ] **Create** `src/ai_workflow/tui/http_handlers/design_pages_create.zig` — `POST /design/pages`
- [ ] **Create** `src/ai/workflow/tui/http_handlers/design_pages_get.zig` — `GET /design/pages/:pid`

Each handler file:
- Uses `parseFromSliceLeaky` for body parsing (per project memory `nalar-http-handler-thin-wrapper-pattern`)
- Uses `std.json.Stringify.valueAlloc` for response
- Routes errors via `switch (err)` with status codes (400/404/409/500)
- Has a sibling `_test.zig` with static-contract assertions (parseFromSliceLeaky, valueAlloc, correct status codes)

### Task 3.2: Element create + update + delete handlers

- [ ] **`design_elements_create.zig`** — `POST /design/pages/:pid/elements`
- [ ] **`design_elements_update.zig`** — `PUT /design/pages/:pid/elements/:eid`
- [ ] **`design_elements_delete.zig`** — `DELETE /design/pages/:pid/elements/:eid`

### Task 3.3: HTML get/update + geometry update handlers

- [ ] **`design_elements_html_get.zig`** — `GET .../elements/:eid/html`
- [ ] **`design_elements_html_update.zig`** — `PATCH .../elements/:eid/html` (used by iframe contenteditable + Monaco)
- [ ] **`design_elements_geometry_update.zig`** — `PATCH .../elements/:eid/geometry` (used by drag/resize)

### Task 3.4: Wire 9 routes in `src/main.zig`

After the kanban routes block (around line 383):

```zig
// Design workspace-item endpoints (item_type='design') — v6
try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/design/pages", ai_mod.http_handlers.designPagesListHandler);
try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages", ai_mod.http_handlers.designPagesCreateHandler);
try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesGetHandler);
try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements", ai_mod.http_handlers.designElementsCreateHandler);
try gs.router.put("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id", ai_mod.http_handlers.designElementsUpdateHandler);
try gs.router.delete("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id", ai_mod.http_handlers.designElementsDeleteHandler);
try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html", ai_mod.http_handlers.designElementsHtmlGetHandler);
try gs.router.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html", ai_mod.http_handlers.designElementsHtmlUpdateHandler);
try gs.router.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/geometry", ai_mod.http_handlers.designElementsGeometryUpdateHandler);
```

### Task 3.5: Re-export 9 handlers in `src/ai_workflow/tui/http_handlers/mod.zig`

### Task 3.6: Add response shapes to `src/ai_workflow/tui/http_handlers/http_response.zig`

```zig
pub const DesignPageResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    width: i64,
    height: i64,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};
pub fn makeDesignPageResponse(allocator: std.mem.Allocator, page: anytype) ![]u8 { ... }

pub const DesignElementResponse = struct {
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    type: []const u8,
    x: i64, y: i64, width: i64, height: i64,
    rotation: f64, fill: []const u8, stroke: []const u8, stroke_width: i64,
    corner_radius: i64, opacity: f64,
    text_content: []const u8, text_style: []const u8, image_url: []const u8,
    file_path: []const u8,
    z_index: i64, position: i64,
    created_at: []const u8, updated_at: []const u8,
};
pub fn makeDesignElementResponse(allocator: std.mem.Allocator, elem: anytype) ![]u8 { ... }
```

### Task 3.7: Commit

```bash
git add src/ai_workflow/tui/http_handlers/design_*.zig src/main.zig src/ai_workflow/tui/http_handlers/http_response.zig
git commit -m "feat(design): 9 HTTP handlers + 9 routes for design mode v6"
```

---

## Chunk 4: LLM Tools (3 tools)

### Task 4.1: `set_design_page` tool

**Files:** `src/modules/agent/tools/set_design_page.zig` + test

- [ ] **Write the tool** (mirror `kanban_list.zig` structure)

Input struct:
```zig
pub const SetDesignPageInput = struct {
    item_id: []const u8,
    page_name: []const u8,
    width: ?i64 = null,
    height: ?i64 = null,
};
```

Behavior:
1. Call `design_model.setDesignPage` — returns page_id
2. Call `design_model.listPages` and filter — get all elements on the page
3. Render XML:
```xml
<page id="<id>" name="<name>" width="<w>" height="<h>" position="<pos>">
  <element id="..." name="..." type="..." x="..." y="..." width="..." height="..." fill="..." rotation="..." />
  ... more elements ...
</page>
```
4. Return `{ output, output_allocated = true }` (matches `kanban_list` envelope)

Errors → wrap in `<error>...</error>`:
```xml
<page><error>design item has no path; set one via AddDesignDialog</error></page>
```

### Task 4.2: `add_element` tool

**Files:** `src/modules/agent/tools/add_design_element.zig`

Input struct (12 params):
```zig
pub const AddElementInput = struct {
    page_id: []const u8,
    name: []const u8,
    type: []const u8,         // "rectangle"|"ellipse"|"text"|"image"|"frame"|"group"
    html: []const u8,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    fill: []const u8 = "",
    rotation: ?f64 = null,
    corner_radius: ?i64 = null,
    opacity: ?f64 = null,
    text_content: []const u8 = "",
    text_style: []const u8 = "",
    image_url: []const u8 = "",
};
```

Behavior:
1. Parse + validate (type must be valid enum, name non-empty, html non-empty)
2. Call `design_model.addElement`
3. Render element XML (omit `html` field — only file_path)
4. On error, wrap in `<add_element><error>...</error></add_element>`

### Task 4.3: `update_element` tool

**Files:** `src/modules/agent/tools/update_design_element.zig`

Input struct (16+ optional params):
```zig
pub const UpdateElementInput = struct {
    element_id: []const u8,
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
    html: ?[]const u8 = null,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
    fill: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    stroke_width: ?i64 = null,
    corner_radius: ?i64 = null,
    opacity: ?f64 = null,
    text_content: ?[]const u8 = null,
    text_style: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
};
```

Behavior:
1. Call `design_model.updateElement`
2. Re-fetch the full element via `loadElement` model helper
3. Render same shape as `add_element`'s response

### Task 4.4: Register 3 tools in `src/ai_workflow/tui/tool_registry.zig`

Add imports + 3 entries to `UNIFIED_TOOL_REGISTRY`:
```zig
.{ .name = "set_design_page", .exec = execSetDesignPage, .tool_def = set_design_page_mod.set_design_page_tool },
.{ .name = "add_element", .exec = execAddElement, .tool_def = add_design_element_mod.add_design_element_tool },
.{ .name = "update_element", .exec = execUpdateElement, .tool_def = update_design_element_mod.update_design_element_tool },
```

Add 3 corresponding `execXxx` functions (mirror `execKanbanList` at `tool_registry.zig:566-606`).

Add 3 entries to `allAgentTools()` at `tool_registry.zig:1784-1810`.

### Task 4.5: Re-export 3 tools in `src/root.zig` (around line 387)

```zig
pub const set_design_page = @import("modules/agent/tools/set_design_page.zig");
pub const add_design_element = @import("modules/agent/tools/add_design_element.zig");
pub const update_design_element = @import("modules/agent/tools/update_design_element.zig");
```

### Task 4.6: Update `BuildDesignCanvasPrompt` in `src/ai_workflow/tui/build_messages_for_agent_prompt.zig:1171+`

Replace the v5 prompt with the v6 version. Include:
- The 3 tool names
- The element types and their fields
- A short example workflow: "to add a login card, call add_element(page_id, name='login-card', type='rectangle', html='<div>...</div>', x=100, y=200, width=400, height=300, fill='#ffffff')"

### Task 4.7: Static-contract tests for the 3 tools

```zig
test "set_design_page tool has workspace_id-aware description" {
    const source = try readSource(testing.allocator, TOOL_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "workspace_id") == null) return error.MissingWorkspaceIdHint;
    if (std.mem.indexOf(u8, source, "<page>") == null) return error.MissingPageTag;
}
// ... similar for add_element and update_element
```

### Task 4.8: Commit

```bash
git add src/modules/agent/tools/set_design_page.zig src/modules/agent/tools/add_design_element.zig src/modules/agent/tools/update_design_element.zig src/ai_workflow/tui/tool_registry.zig src/root.zig src/ai_workflow/tui/build_messages_for_agent_prompt.zig
git commit -m "feat(design): 3 LLM tools (set_design_page, add_element, update_element)"
```

---

## Chunk 5: Frontend API Layer

### Task 5.1: Add interfaces to `src/apps/desktop/src/api/index.ts`

```ts
export interface DesignPage {
  id: string
  workspace_item_id: string
  name: string
  width: number
  height: number
  position: number
  created_at: string
  updated_at: string
}

export interface DesignElement {
  id: string
  page_id: string
  name: string
  type: 'rectangle' | 'ellipse' | 'text' | 'image' | 'frame' | 'group'
  x: number; y: number; width: number; height: number
  rotation: number
  fill: string
  stroke: string
  stroke_width: number
  corner_radius: number
  opacity: number
  text_content: string
  text_style: string
  image_url: string
  file_path: string
  z_index: number
  position: number
  created_at: string
  updated_at: string
}

export interface DesignElementEvent {
  action: 'created' | 'updated' | 'deleted'
  workspace_id: string
  item_id: string
  page_id: string
  element_id: string
}
```

### Task 5.2-5.9: Add 9 API functions

```ts
export async function listDesignPages(workspaceId: string, itemId: string): Promise<{ pages: DesignPage[]; count: number }>
export async function createDesignPage(workspaceId: string, itemId: string, name: string): Promise<DesignPage>
export async function getDesignPage(workspaceId: string, itemId: string, pageId: string): Promise<{ page: DesignPage; elements: DesignElement[] }>
export async function addDesignElement(workspaceId: string, itemId: string, pageId: string, body: Partial<DesignElement> & { name: string; type: DesignElement['type']; html: string }): Promise<DesignElement>
export async function updateDesignElement(workspaceId: string, itemId: string, pageId: string, elementId: string, patch: Partial<DesignElement>): Promise<DesignElement>
export async function deleteDesignElement(workspaceId: string, itemId: string, pageId: string, elementId: string): Promise<{ success: boolean }>
export async function getDesignElementHtml(workspaceId: string, itemId: string, pageId: string, elementId: string): Promise<string>
export async function updateDesignElementHtml(workspaceId: string, itemId: string, pageId: string, elementId: string, html: string): Promise<DesignElement>
export async function updateDesignElementGeometry(workspaceId: string, itemId: string, pageId: string, elementId: string, geometry: { x: number; y: number; width: number; height: number; rotation: number }): Promise<DesignElement>
```

### Task 5.10: Extend `additionalEventTypes` in `createUnifiedSseConnection`

Add `'design_element'` (matches `additionalEventTypes` at `api/index.ts:1720-1732`).

### Task 5.11: Extend `UnifiedChannels` + `createUnifiedSseConnection` signature with `design?`

```ts
export interface UnifiedChannels {
  // ... existing ...
  design?: (event: DesignElementEvent) => void
}
```

### Task 5.12: Tests

Rewrite `src/apps/desktop/src/__tests__/apiDesign.spec.ts` with 9 mock-based tests (mirroring `kanbanApi.spec.ts`). Each test must use the `setActivePinia + createPinia()` + `text()` mock pattern (per project memory `apiFetch-mock-must-include-text-and-pinia`).

### Task 5.13: Commit

```bash
cd src/apps/desktop && git commit -am "feat(design): 9 API functions + bus channel"
```

---

## Chunk 6: Frontend Pinia Store

### Task 6.1: Extend `WorkspaceItem` in `src/apps/desktop/src/stores/workspaces.ts`

Add (OPTIONAL — required for backwards compat per project memory `nalar-frontend-task-literal-typing-rule`):
```ts
design_elements?: DesignElement[]  // populated only when activePageId === designElement.page_id
```

### Task 6.2-6.6: Add store actions

```ts
function fetchDesignElements(workspaceId: string, itemId: string, pageId: string): Promise<void>
function addDesignElement(workspaceId: string, itemId: string, pageId: string, body: any): Promise<DesignElement>
function updateDesignElement(workspaceId: string, itemId: string, pageId: string, elementId: string, patch: any): Promise<DesignElement>
function updateDesignElementGeometry(workspaceId: string, itemId: string, pageId: string, elementId: string, geometry: any): Promise<DesignElement>
function deleteDesignElement(workspaceId: string, itemId: string, pageId: string, elementId: string): Promise<void>
```

All follow the kanban-store pattern (optimistic with rollback, error logging).

### Task 6.7: Create `src/apps/desktop/src/stores/designSse.ts` (~150 lines)

Mirror `kanbanSse.ts` exactly:
```ts
import { defineStore } from 'pinia'
import { ref, watch } from 'vue'
import { useSseBus } from '../helpers/sseBus'
import type { DesignElementEvent } from '../api'
import { useWorkspacesStore } from './workspaces'

export const useDesignSseStore = defineStore('designSse', () => {
  const activeWorkspaceId = ref<string>('')
  let offDesign: (() => void) | null = null
  let stopStateWatch: (() => void) | null = null

  async function initDesignSse(workspaceId: string): Promise<void> {
    activeWorkspaceId.value = workspaceId
    if (offDesign) return // idempotent
    const bus = useSseBus()
    offDesign = bus.on('design', (event: DesignElementEvent) => {
      if (event.workspace_id !== activeWorkspaceId.value) return
      const ws = useWorkspacesStore()
      void ws.fetchDesignElements(event.workspace_id, event.item_id, event.page_id)
    })
    // ... watch on bus.state for reconnect
  }
  function closeDesignSse() { /* cleanup */ }
  // ...
})
```

### Task 6.8: Wire design SSE into `AppLayout.vue`

Mirror the kanban pattern at `AppLayout.vue:121-130`:
```ts
let didInitDesignSse = false
watch(activeWorkspaceId, async (newId) => {
  if (!newId) return
  if (!didInitDesignSse) {
    didInitDesignSse = true
    await designSseStore.initDesignSse(newId)
  } else {
    await designSseStore.setActiveWorkspaceId(newId)
  }
}, { immediate: true })
```

### Task 6.9: Extend `src/helpers/sseBus.ts`

Add `design` to `SseEventMap`, the listeners map, and `createUnifiedSseConnection`'s channel dispatch (lines 20-26, 96-102, 111-128).

### Task 6.10: Tests

Create `src/apps/desktop/src/__tests__/designSseStore.spec.ts` (mirror `kanbanStore.spec.ts`).

### Task 6.11: Commit

```bash
cd src/apps/desktop && git commit -am "feat(design): workspaces store + designSse store + bus channel"
```

---

## Chunk 7: Frontend Vue Components (the BIG chunk)

This chunk has 7 new components plus a rewrite of `DesignView.vue`. Split into subtasks.

### Task 7.1: `DesignPageTabs.vue` (~100 lines)

```vue
<script setup lang="ts">
import { computed } from 'vue'
import type { DesignPage } from '../api'

const props = defineProps<{
  pages: DesignPage[]
  activePageId: string
  workspaceId: string
  itemId: string
}>()

const emit = defineEmits<{
  selectPage: [pageId: string]
  addPage: []
  deletePage: [pageId: string]
}>()
</script>

<template>
  <div class="flex border-b" style="border-color: var(--color-border)">
    <button
      v-for="page in pages" :key="page.id"
      type="button"
      class="px-3 py-2 text-sm"
      :style="page.id === activePageId
        ? 'border-bottom: 2px solid var(--color-violet); color: var(--semantic-text);'
        : 'color: var(--semantic-text-dim);'"
      :data-testid="`design-page-tab-${page.id}`"
      @click="emit('selectPage', page.id)"
    >
      {{ page.name }}
    </button>
    <button
      type="button"
      class="px-3 py-2 text-sm"
      style="color: var(--semantic-text-dim);"
      data-testid="design-add-page"
      @click="emit('addPage')"
    >+ Page</button>
  </div>
</template>
```

### Task 7.2: `DesignElementPreview.vue` (~80 lines)

```vue
<script setup lang="ts">
import { ref, watch } from 'vue'
const props = defineProps<{
  html: string
  editable?: boolean
}>()
const iframeRef = ref<HTMLIFrameElement | null>(null)
const emit = defineEmits<{ htmlChanged: [html: string] }>()

// Listen for iframe content changes (contenteditable)
// ... full implementation per design
</script>

<template>
  <iframe
    ref="iframeRef"
    sandbox="allow-scripts"
    class="w-full h-full"
    :srcdoc="html"
    @blur="handleBlur"
  />
</template>
```

### Task 7.3: `DesignElement.vue` (~250 lines)

Single element with click-to-select + drag-to-move + resize handles. Uses `pointerdown` / `pointermove` / `pointerup` handlers. Coordinate math converts container-relative mouse position to element's x/y/width/height.

### Task 7.4: `LayersPanel.vue` (~200 lines)

Tree of all elements on the page. Drag to reorder z-index (HTML5 DnD). Click to select. Uses Vue Draggable (already in package.json — verify) or simple `pointer*` handlers.

### Task 7.5: `PropertiesPanel.vue` (~400 lines)

Form binding for the selected element's properties. Monaco editor lazy-loaded for the HTML content (use `vue-monaco` or the `monaco-editor` library directly; defer loading with `import()`).

### Task 7.6: `AddDesignElementDialog.vue` (~150 lines)

Modal with `type` select + `name` input + initial HTML textarea. Mirrors `AddDesignDialog.vue` shape.

### Task 7.7: Rewrite `DesignView.vue` (~600 lines)

Top-level layout:
```
┌─────────────────────────────────────────┐
│ DesignPageTabs.vue                      │
├──────────────────────────────────┬──────┤
│                                  │ L    │
│ <Canvas> (scrolled)              │ a    │
│   <DesignElement v-for="..." />  │ y    │
│                                  │ e    │
│                                  │ r    │
│                                  │ s    │
│                                  ├──────┤
│                                  │ P    │
│                                  │ r    │
│                                  │ o    │
│                                  │ p    │
│                                  │ s    │
└──────────────────────────────────┴──────┘
```

### Task 7.8: Tests for each component

Create `__tests__/{DesignPageTabs, DesignElement, LayersPanel, PropertiesPanel}.spec.ts` (static-contract tests).

### Task 7.9: Build verification

```bash
cd src/apps/desktop
timeout 240 bun run build 2>&1 | tail -n 20
timeout 120 bunx vitest run 2>&1 | tail -n 5
```

Expected: clean type-check, all tests pass.

### Task 7.10: Commit

```bash
git commit -am "feat(design): 6 new Vue components + DesignView.vue rewrite"
```

---

## Chunk 8: AppLayout + Sidebar Wiring

### Task 8.1: AppLayout.vue — single-column design branch

Add after the kanban v-else-if block (around line 1335-1357):
```html
<DesignView
  v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'design'"
  :key="'design-' + activeWorkspaceItem.id"
  :item="activeWorkspaceItem"
  :workspace-id="activeWorkspace?.id ?? ''"
  :item-id="activeWorkspaceItem.id"
  @select-page="handleDesignSelectPage"
  @add-page="handleDesignAddPage"
  @add-element="handleDesignAddElement"
  @update-element="handleDesignUpdateElement"
  @delete-element="handleDesignDeleteElement"
  @select-element="handleDesignSelectElement"
/>
```

### Task 8.2: AppLayout.vue — three-column variant (design + chat)

Mirror lines 1226-1326 with `<DesignView>` instead of `<KanbanView>`.

### Task 8.3: AppLayout.vue — handler functions

```ts
const handleDesignSelectPage = (pageId: string) => {
  workspacesStore.setActiveDesignPage(pageId)
}
const handleDesignAddPage = async () => {
  // Open AddDesignPageDialog
}
const handleDesignAddElement = async (pageId: string) => {
  // Open AddDesignElementDialog with this pageId
}
const handleDesignUpdateElement = async (elementId: string, patch: any) => {
  await workspacesStore.updateDesignElement(workspaceId.value, itemId.value, pageId.value, elementId, patch)
}
const handleDesignDeleteElement = async (elementId: string) => {
  await workspacesStore.deleteDesignElement(workspaceId.value, itemId.value, pageId.value, elementId)
}
const handleDesignSelectElement = (elementId: string) => {
  workspacesStore.setActiveDesignElement(elementId)
}
```

### Task 8.4: WorkspaceItem.vue — add design discriminator

In the template at line 430:
```html
<template v-else-if="item.item_type !== 'design' && item.item_type !== 'kanban'">
  <!-- task list rendering -->
</template>
```

In the click handler at line 96-98:
```ts
if (props.item.item_type !== 'kanban' && props.item.item_type !== 'design') {
  workspacesStore.toggleExpandedItem(props.item.id)
}
```

### Task 8.5: Sidebar.vue — design path check (line 435)

```ts
if (item.item_type === 'folder' && item.path) return item.path
// ADD for design (mirrors kanban designnn example):
if (item.item_type === 'design' && item.path) return item.path
```

### Task 8.6: AddDesignDialog.vue — review for v6 compatibility

Verify the dialog still has the path picker. The existing v5 dialog should work unchanged.

### Task 8.7: WorkspaceItemKanbanUpdate + tests

Verify the existing kanban-mode tests aren't broken. Run the test suite.

### Task 8.8: Commit

```bash
cd src/apps/desktop && git commit -am "feat(design): AppLayout + Sidebar + WorkspaceItem integration"
```

---

## Chunk 9: Smoke Test + Final Validation

### Task 9.1: Update `scripts/design-mode-smoke.sh`

Add element CRUD assertions (POST element, GET html, PUT element, PATCH geometry, DELETE element) after the existing page CRUD assertions.

### Task 9.2: Run all tests

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/design-mode-redesign

# Backend
timeout 240 zig build test --summary all 2>&1 | tail -n 5
timeout 240 zig build install:linux:system 2>&1 | tail -n 5

# Frontend
cd src/apps/desktop
timeout 240 bun run build 2>&1 | tail -n 20
timeout 120 bunx vitest run 2>&1 | tail -n 5

# Smoke test
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/design-mode-redesign
PORT=8080 ./zig-out/bin/nalar &
sleep 5
bash scripts/design-mode-smoke.sh
```

Expected: all green.

### Task 9.3: Verify against criteria

For each of the 3 confirmed decisions:

1. **File-backed HTML**: open the DB, create a design item, add an element via the LLM tool, verify a file exists at `<workspace_item.path>/.nalar/design/<page_name>/<element_name>.html` with the right content. Then update the element's HTML and verify the file was atomically rewritten (same path, new content, no `.tmp` left).

2. **Canvas = Tier 2 (Figma-lite)**: open the design in the browser, confirm: no panzoom; elements are draggable; an element gets a violet outline on click; clicking populates Layers + Properties panels; the Properties panel has form fields for x/y/w/h/fill/rotation/corner_radius/opacity.

3. **3 LLM tools**: send a chat message asking the LLM to "design a login page on the Home page". Verify in the logs that exactly 3 tool definitions (`set_design_page`, `add_element`, `update_element`) are exposed, and the LLM uses 2-3 calls to complete the task.

### Task 9.4: Document deferred items

In a new file `docs/plans/2026-07-08-design-mode-deferred.md`, list the 12 deferred items (from design §14) with brief rationale.

### Task 9.5: Final commit

```bash
git add scripts/design-mode-smoke.sh docs/plans/2026-07-08-design-mode-deferred.md
git commit -m "feat(design): smoke test + deferred items doc"
```

---

## Open Decisions During Implementation

The following decisions are NOT in the design doc but may arise during implementation. The agent executing the plan should:

1. **Property panel layout** — propose a layout, ask the user if more than 5 seconds of UI design work would be wasted without input
2. **Selection visual treatment** — violet outline, plus what else? (e.g., always show resize handles, or only on hover/selected?)
3. **Auto-save throttle** — 1 second debounce on Monaco + contenteditable? Increase if user reports lag
4. **Page tab drag-to-reorder** — keep simple v1 (click select only), defer drag-to-reorder to Tier 3

Each requires a quick chat with the user. **If no user input is available**, pick the conservative default (e.g., 1s debounce, no page drag-to-reorder) and document the decision in the code comments.

---

## Out-of-scope Follow-ups (after v6 ships)

1. **Multi-page export (zip)** — zip the design folder for download
2. **HTML sanitizer (DOMPurify)** — add if users report security concerns
3. **iframe→parent postMessage** — add if users need runtime error visibility
4. **Page templates** — add starter templates
5. **Auto-layout (flexbox)** — Tier 3
6. **Component system with variants** — Tier 3
7. **WebGL renderer** — only if >100 nodes/frame becomes slow
8. **Real-time multiplayer** — major project, separate plan

---

**Plan complete.** Saved to `docs/superpowers/plans/2026-07-08-design-mode-redesign.md`. Companion design doc at `docs/plans/2026-07-08-design-mode-redesign-design.md`.

Next step: review this plan with the user. If approved, execute using `superpowers:subagent-driven-development` (one subagent per chunk). Each chunk's subagent should:
1. Work in the same worktree (`.worktrees/design-mode-redesign`)
2. Read the design doc for context
3. Execute every checkbox in their chunk
4. Run all verification commands (tests + builds) before reporting done
5. Commit after each task or at end of chunk
6. Report any blockers back to the orchestrator
