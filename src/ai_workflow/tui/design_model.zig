//! Data layer for the Design Mode workspace item (item_type='design').
//!
//! Each design workspace item hosts N named HTML pages (e.g. "Login",
//! "Dashboard", "Settings"). Pages are pure metadata containers —
//! `width`/`height`/`x`/`y` define the canvas, and the body is composed
//! of N positioned `DesignPageElement` rows. Each element stores its
//! HTML on disk at `<workspace_item.path>/<derived file_path>` — the
//! DB only holds the metadata (position, size, file_path, z_index).
//!
//! Schema: see Migration 055 (`Migration055AddDesignPagesAndElements`
//! in `src/ai_workflow/tui/migration.zig`).
//!
//! SQL convention: every SELECT aliases its tables (`dp` for
//! `design_pages`, `dpe` for `design_page_elements`) and qualifies
//! every column reference with the alias. See the project memory
//! `nalar-sql-alias-tables.md`.
//!
//! Row ownership: each `db.query()` row's `values[i]` slices are owned
//! by the `Row` and freed by `row.deinit(allocator)`. To keep a value
//! past the loop iteration, the field is duplicated with
//! `allocator.dupe(u8, row.values[i])`.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 1)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const helpers = nalarcore.helpers;

// ─── Pages (metadata-only) ────────────────────────────────────────────────

/// One page row from `listPages` — pure metadata, no html. The
/// frontend renders a tab strip from this (name + position + canvas
/// size) and only fetches elements via `listElements` when the tab
/// is activated.
pub const DesignPageSummary = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    position: i64,
    width: i64,
    height: i64,
    x: i64,
    y: i64,
    created_at: []u8,
    updated_at: []u8,
};

/// One page row from `getPage` — same shape as the Summary (no html
/// field on pages). Kept as a separate type for forward-compat with
/// callers that may want a different return shape (e.g. including
/// the elements list inline).
pub const DesignPageFull = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    position: i64,
    width: i64,
    height: i64,
    x: i64,
    y: i64,
    created_at: []u8,
    updated_at: []u8,
};

/// Free the per-page strings and the backing slice in one call.
pub fn freePageSummaries(allocator: std.mem.Allocator, pages: []DesignPageSummary) void {
    for (pages) |p| {
        allocator.free(p.id);
        allocator.free(p.workspace_item_id);
        allocator.free(p.name);
        allocator.free(p.created_at);
        allocator.free(p.updated_at);
    }
    allocator.free(pages);
}

/// Free the per-field strings of a `DesignPageFull`. Does NOT free the
/// `DesignPageFull` value itself (it's passed by value, so the storage
/// is on the caller's stack).
pub fn freePageFull(allocator: std.mem.Allocator, page: DesignPageFull) void {
    allocator.free(page.id);
    allocator.free(page.workspace_item_id);
    allocator.free(page.name);
    allocator.free(page.created_at);
    allocator.free(page.updated_at);
}

/// List the pages of a design workspace item, ordered by `position` ASC.
///
/// Returns an owned slice; the caller must release it with
/// `freePageSummaries(allocator, slice)`. If the item has no pages, the
/// slice has length 0 (not an error).
///
/// SQL convention: aliases `design_pages` as `dp` and qualifies every
/// column reference with the alias per `nalar-sql-alias-tables.md`.
pub fn listPages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]DesignPageSummary {
    var q = try db.query(allocator,
        \\SELECT dp.id, dp.workspace_item_id, dp.name, dp.position,
        \\       dp.width, dp.height, dp.x, dp.y,
        \\       dp.created_at, dp.updated_at
        \\FROM design_pages dp
        \\WHERE dp.workspace_item_id = ?
        \\ORDER BY dp.position ASC
    , &.{workspace_item_id});
    defer q.deinit();

    var rows = std.ArrayList(DesignPageSummary).empty;
    errdefer {
        for (rows.items) |r| {
            allocator.free(r.id);
            allocator.free(r.workspace_item_id);
            allocator.free(r.name);
            allocator.free(r.created_at);
            allocator.free(r.updated_at);
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
            .width = try std.fmt.parseInt(i64, row.values[4], 10),
            .height = try std.fmt.parseInt(i64, row.values[5], 10),
            .x = try std.fmt.parseInt(i64, row.values[6], 10),
            .y = try std.fmt.parseInt(i64, row.values[7], 10),
            .created_at = try allocator.dupe(u8, row.values[8]),
            .updated_at = try allocator.dupe(u8, row.values[9]),
        });
    }
    return rows.toOwnedSlice(allocator);
}

/// Fetch a single page by id. Returns `error.PageNotFound` if no row
/// matches. The returned `DesignPageFull` is owned by the caller —
/// release with `freePageFull`.
pub fn getPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) !DesignPageFull {
    var q = try db.query(allocator,
        \\SELECT dp.id, dp.workspace_item_id, dp.name, dp.position,
        \\       dp.width, dp.height, dp.x, dp.y,
        \\       dp.created_at, dp.updated_at
        \\FROM design_pages dp WHERE dp.id = ?
    , &.{page_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.PageNotFound;
    defer row.deinit(allocator);
    return DesignPageFull{
        .id = try allocator.dupe(u8, row.values[0]),
        .workspace_item_id = try allocator.dupe(u8, row.values[1]),
        .name = try allocator.dupe(u8, row.values[2]),
        .position = try std.fmt.parseInt(i64, row.values[3], 10),
        .width = try std.fmt.parseInt(i64, row.values[4], 10),
        .height = try std.fmt.parseInt(i64, row.values[5], 10),
        .x = try std.fmt.parseInt(i64, row.values[6], 10),
        .y = try std.fmt.parseInt(i64, row.values[7], 10),
        .created_at = try allocator.dupe(u8, row.values[8]),
        .updated_at = try allocator.dupe(u8, row.values[9]),
    };
}

/// Append-or-replace a page to a design item. Pages are pure metadata
/// (no html, no file_path on the row itself).
///
/// **Idempotent on `(workspace_item_id, name)`**: re-issuing with the
/// same name updates the existing row's `width`/`height`/`x`/`y` and
/// `updated_at` in place (does NOT create a duplicate). The row's `id`
/// is preserved across re-issues, so the caller can use the returned
/// id as a stable handle for the page's lifetime.
///
/// New pages get `position = COALESCE(MAX(position), -1) + 1` so the
/// first page in an empty item is at position 0 and subsequent pages
/// append at the end. Replacement (existing-name) calls do NOT change
/// the position (the ON CONFLICT only updates width/height/x/y +
/// updated_at).
///
/// Returns a freshly-allocated id of the form `page_<unix_nanoseconds>`.
/// Caller owns the returned slice.
pub fn addPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    name: []const u8,
    width: i64,
    height: i64,
    x: i64,
    y: i64,
) ![]u8 {
    const id = try std.fmt.allocPrint(allocator, "page_{d}", .{helpers.unixTimestampNanos()});
    errdefer allocator.free(id);

    // SQLite parameter binding goes through []const []const u8 (see
    // Sqlite.zig:146), so i64 → string via allocPrint.
    const width_s = try std.fmt.allocPrint(allocator, "{d}", .{width});
    defer allocator.free(width_s);
    const height_s = try std.fmt.allocPrint(allocator, "{d}", .{height});
    defer allocator.free(height_s);
    const x_s = try std.fmt.allocPrint(allocator, "{d}", .{x});
    defer allocator.free(x_s);
    const y_s = try std.fmt.allocPrint(allocator, "{d}", .{y});
    defer allocator.free(y_s);

    try db.exec(allocator,
        \\INSERT INTO design_pages (id, workspace_item_id, name, width, height, x, y, position)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT MAX(position) FROM design_pages WHERE workspace_item_id = ?), -1) + 1)
        \\ON CONFLICT(workspace_item_id, name) DO UPDATE SET
        \\    width = excluded.width,
        \\    height = excluded.height,
        \\    x = excluded.x,
        \\    y = excluded.y,
        \\    updated_at = datetime('now')
    , &.{ id, workspace_item_id, name, width_s, height_s, x_s, y_s, workspace_item_id });
    return id;
}

/// Delete a page by id. Idempotent: returns `true` if a row was
/// deleted, `false` if no such id exists (no error). Callers use the
/// bool to decide whether to emit an SSE event — `false` is the
/// "delete was a no-op" case (e.g. a duplicate DELETE request).
///
/// Note: ON DELETE CASCADE on `design_page_elements.page_id` cleans up
/// the metadata rows. **The HTML files on disk are NOT cleaned up by
/// this function** — callers must explicitly delete elements first
/// (or call a higher-level "purge" that walks elements → files →
/// row → files-of-child-pages). For now the simple-delete behavior
/// matches the plan: pages are metadata; orphan files are a known
/// limitation that Chunk 2 (the new handlers) will address via a
/// cascade-delete endpoint.
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

/// Update a page's canvas geometry (`width`/`height`/`x`/`y`). All
/// four fields are required (no partial update — drag handlers
/// always send the full rect). Touches `updated_at = datetime('now')`.
///
/// Returns `true` on a successful UPDATE, `false` if no such id
/// exists.
pub fn updatePageGeometry(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    width: i64,
    height: i64,
    x: i64,
    y: i64,
) !bool {
    var q = try db.query(allocator,
        "SELECT id FROM design_pages WHERE id = ?", &.{page_id});
    defer q.deinit();
    const row = try q.next();
    if (row == null) return false;
    if (row) |r| r.deinit(allocator);

    const width_s = try std.fmt.allocPrint(allocator, "{d}", .{width});
    defer allocator.free(width_s);
    const height_s = try std.fmt.allocPrint(allocator, "{d}", .{height});
    defer allocator.free(height_s);
    const x_s = try std.fmt.allocPrint(allocator, "{d}", .{x});
    defer allocator.free(x_s);
    const y_s = try std.fmt.allocPrint(allocator, "{d}", .{y});
    defer allocator.free(y_s);

    try db.exec(allocator,
        \\UPDATE design_pages SET
        \\    width = ?, height = ?, x = ?, y = ?,
        \\    updated_at = datetime('now')
        \\WHERE id = ?
    , &.{ width_s, height_s, x_s, y_s, page_id });
    return true;
}

// ─── Elements (file-backed) ───────────────────────────────────────────────

/// One element row from `listElements` — metadata only. The HTML body
/// is read on demand via `getElement` (which returns a `DesignPageElementFull`).
pub const DesignPageElement = struct {
    id: []u8,
    page_id: []u8,
    name: []u8,
    file_path: []u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    z_index: i64,
    position: i64,
    created_at: []u8,
    updated_at: []u8,
};

/// One element row from `getElement` — includes the HTML body read
/// from disk. The HTML is `[]u8` (NOT `[]const u8`) so callers can
/// free it without an allocator round-trip.
pub const DesignPageElementFull = struct {
    id: []u8,
    page_id: []u8,
    name: []u8,
    file_path: []u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    z_index: i64,
    position: i64,
    created_at: []u8,
    updated_at: []u8,
    html: []u8,
};

/// Free an owned slice of `DesignPageElement` (metadata). Does NOT
/// touch any HTML files — they live on disk.
pub fn freeElements(allocator: std.mem.Allocator, elements: []DesignPageElement) void {
    for (elements) |e| {
        allocator.free(e.id);
        allocator.free(e.page_id);
        allocator.free(e.name);
        allocator.free(e.file_path);
        allocator.free(e.created_at);
        allocator.free(e.updated_at);
    }
    allocator.free(elements);
}

/// Free the per-field strings of a `DesignPageElementFull`. Does NOT
/// free the `DesignPageElementFull` value itself (passed by value).
pub fn freeElementFull(allocator: std.mem.Allocator, el: DesignPageElementFull) void {
    allocator.free(el.id);
    allocator.free(el.page_id);
    allocator.free(el.name);
    allocator.free(el.file_path);
    allocator.free(el.created_at);
    allocator.free(el.updated_at);
    allocator.free(el.html);
}

// ─── Workspace item resolution ────────────────────────────────────────────

/// Minimal workspace-item view: just the `path` we need to resolve an
/// element's `file_path` to an absolute on-disk path. We don't reuse
/// `WorkspaceItemInfo` (in `llm_history.zig`) because that struct
/// exposes fields we don't need (timestamps) and pulls in `name`,
/// which would force every callsite to free an extra string.
const ResolvedWorkspaceItem = struct {
    id: []u8,
    path: ?[]u8,
    workspace_id: []u8,

    pub fn deinit(self: ResolvedWorkspaceItem, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.workspace_id);
        if (self.path) |p| allocator.free(p);
    }
};

/// Look up the workspace item's `path` so we can resolve element
/// `file_path` to absolute paths for file IO. Returns
/// `error.WorkspaceItemNotFound` if no row matches.
///
/// SqliteBackend.exec binds empty slices as SQL NULL (see project
/// memory `sqlite-backend-empty-slice-binds-as-null.md`), so a NULL
/// `path` column returns `values[i].len == 0` and we surface `null`
/// (not empty string) — callers must then translate that to "use
/// cwd-relative file IO" or fail with `error.WorkspaceItemPathRequired`.
fn resolveWorkspaceItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) !ResolvedWorkspaceItem {
    var q = try db.query(allocator,
        \\SELECT wi.id, wi.path, wi.workspace_id
        \\FROM workspace_items wi
        \\WHERE wi.id = ?
    , &.{workspace_item_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.WorkspaceItemNotFound;
    defer row.deinit(allocator);
    return ResolvedWorkspaceItem{
        .id = try allocator.dupe(u8, row.values[0]),
        .path = if (row.values[1].len > 0) try allocator.dupe(u8, row.values[1]) else null,
        .workspace_id = try allocator.dupe(u8, row.values[2]),
    };
}

// ─── sanitizeFilename ─────────────────────────────────────────────────────

/// Errors emitted by `sanitizeFilename`.
pub const SanitizeError = error{
    /// The input was empty, or sanitization produced an empty string
    /// (e.g. input was all whitespace / slashes / dots).
    InvalidFilename,
    /// `allocator.alloc` can fail with OOM. Surfaced as part of the
    /// public error set so callers don't have to wrap.
    OutOfMemory,
};

/// Sanitize an element's `name` for use as a derived file path
/// component. Rules (matching the plan's spec):
///   1. Lowercase ASCII (preserves non-ASCII bytes — readable UTF-8
///      stays readable).
///   2. Replace `/` and `\` with `_` (path separator safety). The
///      resulting filename stays flat (no sub-dir escapes).
///   3. Strip a single leading `.` (hides the file on POSIX `ls`).
///   4. Collapse whitespace runs (space/tab/newline/CR) to a single `-`.
///   5. Trim trailing whitespace/dashes.
///   6. Reject empty result with `error.InvalidFilename`.
///
/// The result is suitable for concatenation into
/// `<workspace_item.path>/.nalar/design/<page_name>/<sanitized>.html`.
/// Caller owns the returned slice.
pub fn sanitizeFilename(allocator: std.mem.Allocator, name: []const u8) SanitizeError![]u8 {
    // Allocate at most len (sanitization never grows the string). After
    // scanning we shrink with `realloc` to the exact out_len so the
    // returned slice's len matches the underlying allocation's
    // tracked size — required by DebugAllocator's canary check (calling
    // `free` on a slice shorter than the original allocation fires
    // "Allocation size N bytes does not match free size M bytes").
    var buf = try allocator.alloc(u8, name.len);
    errdefer allocator.free(buf);

    var out_len: usize = 0;
    // `in_word` tracks whether we've emitted a content character
    // since the last whitespace/separator. Used to decide whether
    // to emit a separator (`_` or `-`) before the next character.
    var in_word = false;
    // Just-emitted-separator: used so we collapse runs of mixed
    // separators/whitespace without producing "a___-b" or similar.
    var just_emitted_sep = false;

    var i: usize = 0;
    while (i < name.len) {
        const c = name[i];
        if (c == '/' or c == '\\') {
            // Path separator → `_`. Emit one if we're in a word.
            if (in_word and !just_emitted_sep) {
                buf[out_len] = '_';
                out_len += 1;
                just_emitted_sep = true;
                in_word = false;
            }
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            // Whitespace → `-`. Emit one if we're in a word.
            if (in_word and !just_emitted_sep) {
                buf[out_len] = '-';
                out_len += 1;
                just_emitted_sep = true;
                in_word = false;
            }
            i += 1;
            continue;
        }
        if (c == '.' and out_len == 0) {
            // Strip ALL leading dots (not just the first). An input
            // consisting entirely of dots (e.g. "...") must sanitize
            // to "" so the caller returns InvalidFilename. Once we
            // emit a non-dot character, internal dots are kept as-is.
            i += 1;
            continue;
        }
        // Lowercase ASCII A-Z → a-z.
        const out_c: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        buf[out_len] = out_c;
        out_len += 1;
        in_word = true;
        just_emitted_sep = false;
        i += 1;
    }

    // Trim trailing separators (`_` or `-`).
    while (out_len > 0 and (buf[out_len - 1] == '-' or buf[out_len - 1] == '_')) {
        out_len -= 1;
    }

    if (out_len == 0) {
        // Don't free via errdefer — caller will see the error.
        return error.InvalidFilename;
    }

    // Shrink to the exact output length so the returned slice matches
    // the allocation's tracked size. Without this, calling `free` on
    // `buf[0..out_len]` (smaller than the original `name.len`
    // allocation) trips DebugAllocator's size-mismatch canary.
    const shrunk = allocator.realloc(buf, out_len) catch buf;
    return shrunk[0..out_len];
}

// ─── File IO helpers ──────────────────────────────────────────────────────

/// Compute the RELATIVE file path for an element (stored in the DB).
/// Result: `.nalar/design/<page_name>/<element_sanitized>.html`.
///
/// The file_path column holds a path relative to `workspace_item.path`
/// so the file is portable across users / machines (e.g., when
/// exporting/importing a design item). The caller resolves it to an
/// absolute path by prepending `workspace_item.path` at file IO time.
fn relativeElementFilePath(
    allocator: std.mem.Allocator,
    page_name: []const u8,
    element_sanitized: []const u8,
) ![]u8 {
    const prefix = ".nalar/design/";
    const suffix = ".html";
    const total = prefix.len + page_name.len + 1 + element_sanitized.len + suffix.len;
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos..][0..page_name.len], page_name);
    pos += page_name.len;
    buf[pos] = '/';
    pos += 1;
    @memcpy(buf[pos..][0..element_sanitized.len], element_sanitized);
    pos += element_sanitized.len;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    return buf[0..pos];
}

/// Build an absolute path by concatenating `workspace_item.path` and
/// the element's relative `file_path`. Used at file-IO time only.
fn absoluteElementPath(
    allocator: std.mem.Allocator,
    workspace_item_path: []const u8,
    relative_file_path: []const u8,
) ![]u8 {
    const total = workspace_item_path.len + 1 + relative_file_path.len;
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);
    @memcpy(buf[0..workspace_item_path.len], workspace_item_path);
    buf[workspace_item_path.len] = '/';
    @memcpy(buf[workspace_item_path.len + 1 ..][0..relative_file_path.len], relative_file_path);
    return buf[0..total];
}

/// Errors from element file IO operations.
pub const ElementFileError = error{
    WorkspaceItemNotFound,
    WorkspaceItemPathRequired,
    InvalidFilename,
    /// IO error from the underlying std.Io operations (mkdir, open,
    /// write, read, delete). Kept generic because Zig 0.16's std.Io
    /// surfaces a wide variety of POSIX errno-equivalent errors.
    IoFailed,
    /// alloc / allocPrint can fail with OOM.
    OutOfMemory,
};

/// mkdir -p the directory that will hold the element's html file.
/// The dir path is `<workspace_item.path>/.nalar/design/<page_name>/`.
/// Uses libc `mkdirat` (via `std.c.*`) so this compiles on Linux,
/// macOS, and Windows (UCRT) — `std.os.linux.*` would fail on Mac CI
/// per the project memory `zig-cross-platform-blockers-and-fixes.md`.
fn ensureElementDir(
    allocator: std.mem.Allocator,
    workspace_item_path: []const u8,
    page_name: []const u8,
) ElementFileError!void {
    // Build the cumulative path by appending each segment to a
    // running buffer. We mkdir each cumulative prefix in order so a
    // missing intermediate (like `.nalar`) gets created before we
    // try to mkdir its child. The leaf is included so the
    // subsequent createFile can open it directly.
    //
    // segments = ["workspace_item_path", ".nalar", "design", "page_name"]
    //  → mkdirat("/workspace_item_path")            (EEXIST ok)
    //  → mkdirat("/workspace_item_path/.nalar")      (EEXIST ok)
    //  → mkdirat("/workspace_item_path/.nalar/design")  (EEXIST ok)
    //  → mkdirat("/workspace_item_path/.nalar/design/<page_name>")  (EEXIST ok)
    const segments: [4][]const u8 = .{ workspace_item_path, ".nalar", "design", page_name };
    var cumulative: std.ArrayList(u8) = .empty;
    defer cumulative.deinit(allocator);

    for (segments) |seg| {
        if (cumulative.items.len > 0) {
            try cumulative.append(allocator, '/');
        }
        try cumulative.appendSlice(allocator, seg);
        var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
        if (cumulative.items.len >= path_z.len) return error.IoFailed;
        @memcpy(path_z[0..cumulative.items.len], cumulative.items);
        path_z[cumulative.items.len] = 0;
        const rc = std.c.mkdirat(std.c.AT.FDCWD, &path_z, 0o755);
        if (rc == -1) {
            const err = std.c._errno().*;
            // EEXIST (17) is fine — that's the "mkdir -p" semantics.
            if (err != 17) return error.IoFailed;
        }
    }
}

/// Write `html` to the file at `abs_path`, creating/truncating it.
/// Caller owns `abs_path` and `html` — neither is freed.
fn writeElementFile(
    io: std.Io,
    abs_path: []const u8,
    html: []const u8,
) ElementFileError!void {
    const file = std.Io.Dir.cwd().createFile(io, abs_path, .{ .truncate = true }) catch {
        return error.IoFailed;
    };
    defer file.close(io);
    file.writeStreamingAll(io, html) catch {
        return error.IoFailed;
    };
}

/// Delete the file at `abs_path` if it exists. Idempotent: a missing
/// file is NOT an error (deleteElement must not fail just because
/// the file is already gone).
fn unlinkElementFile(abs_path: []const u8) void {
    // Use libc unlink directly — simpler than std.Io.Dir.deleteFile
    // (which surfaces a variety of error unions and would force every
    // caller to swallow them). We don't need the `io: std.Io` here.
    var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (abs_path.len >= path_z.len) return;
    @memcpy(path_z[0..abs_path.len], abs_path);
    path_z[abs_path.len] = 0;
    _ = std.c.unlink(&path_z);
}

// ─── Element CRUD ─────────────────────────────────────────────────────────

/// Errors emitted by element add/get/update/move/resize/delete. We
/// merge the SQLite error set + the file-IO error set so the
/// underlying `db.query` / `db.exec` / file-IO calls can propagate
/// any error without each call site needing a catch-rewrap. Handlers
/// will treat any non-domain error as 500 (matches the kanban_model
/// pattern).
pub const ElementError = sqlite.Error || ElementFileError || error{
    WorkspaceItemNotFound,
    /// The workspace item exists but has no `path` column set (the
    /// design item was created via the path-less flow or the legacy
    /// migration missed it). The element cannot be stored on disk.
    WorkspaceItemPathRequired,
    InvalidFilename,
    PageNotFound,
    ElementNotFound,
    FileIoFailed,
};

/// Append a new element to a page. Writes the HTML body to disk at
/// `<workspace_item.path>/.nalar/design/<page_name>/<sanitized>.html`
/// and INSERTs the metadata row. Returns the newly-allocated id of
/// the form `elem_<unix_nanoseconds>`; caller owns the slice.
///
/// The element's `file_path` is derived from `name` via
/// `sanitizeFilename` and the page's `name` (looked up via `page_id`).
/// If `name` is empty or sanitizes to empty, returns
/// `error.InvalidFilename`.
///
/// `position` defaults to `COALESCE(MAX(position), -1) + 1` so
/// elements append at the end of the page's z-ordered list.
pub fn addElement(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    name: []const u8,
    html: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    z_index: i64,
) ElementError![]u8 {
    // 1. Look up the page (to get its workspace_item_id and name).
    const page = getPage(allocator, db, page_id) catch |err| {
        if (err == error.PageNotFound) return error.PageNotFound;
        return error.FileIoFailed;
    };
    defer freePageFull(allocator, page);

    // 2. Look up the workspace item (to get its path).
    const item = resolveWorkspaceItem(allocator, db, page.workspace_item_id) catch |err| {
        if (err == error.WorkspaceItemNotFound) return error.WorkspaceItemNotFound;
        return error.FileIoFailed;
    };
    defer item.deinit(allocator);

    const item_path = item.path orelse return error.WorkspaceItemPathRequired;

    // 3. Sanitize the element name and derive the (relative) file path
    //    stored in the DB. Resolve to an absolute path for the file
    //    IO step below. We pass the optional back from
    //    `sanitizeFilename` so an `error.InvalidFilename` cleanly
    //    returns without trying to free an uninitialized slice.
    const sanitized_result = sanitizeFilename(allocator, name);
    if (sanitized_result) |sanitized_owned| {
        defer allocator.free(sanitized_owned);
        const sanitized = sanitized_owned;
        const rel_path = try relativeElementFilePath(allocator, page.name, sanitized);
        defer allocator.free(rel_path);
        const abs_path = try absoluteElementPath(allocator, item_path, rel_path);
        defer allocator.free(abs_path);

        // 4. mkdir -p the parent directory + write the html file.
        try ensureElementDir(allocator, item_path, page.name);
        try writeElementFile(io, abs_path, html);

        // 5. INSERT the metadata row. SQLite parameter binding goes
        //    through []const []const u8 (see Sqlite.zig:146), so i64 →
        //    string via allocPrint.
        const id = try std.fmt.allocPrint(allocator, "elem_{d}", .{helpers.unixTimestampNanos()});
        errdefer allocator.free(id);
        const x_s = try std.fmt.allocPrint(allocator, "{d}", .{x});
        defer allocator.free(x_s);
        const y_s = try std.fmt.allocPrint(allocator, "{d}", .{y});
        defer allocator.free(y_s);
        const w_s = try std.fmt.allocPrint(allocator, "{d}", .{width});
        defer allocator.free(w_s);
        const h_s = try std.fmt.allocPrint(allocator, "{d}", .{height});
        defer allocator.free(h_s);
        const z_s = try std.fmt.allocPrint(allocator, "{d}", .{z_index});
        defer allocator.free(z_s);

        try db.exec(allocator,
            \\INSERT INTO design_page_elements
            \\    (id, page_id, name, file_path, x, y, width, height, z_index, position)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?,
            \\    COALESCE((SELECT MAX(position) FROM design_page_elements WHERE page_id = ?), -1) + 1)
        , &.{ id, page_id, name, rel_path, x_s, y_s, w_s, h_s, z_s, page_id });
        return id;
    } else |err| {
        // sanitizeFilename returned an error — propagate it.
        return err;
    }
}

/// Fetch a single element by id, including the HTML body read from
/// disk. Returns `error.ElementNotFound` if no row matches.
///
/// The element's file is read via `std.Io.Dir.openDir +
/// readFileAlloc` with a `.unlimited` limit (HTML is bounded by the
/// PUT-handler's 5 MB cap, enforced upstream).
pub fn getElement(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) ElementError!DesignPageElementFull {
    var q = try db.query(allocator,
        \\SELECT dpe.id, dpe.page_id, dpe.name, dpe.file_path,
        \\       dpe.x, dpe.y, dpe.width, dpe.height,
        \\       dpe.z_index, dpe.position,
        \\       dpe.created_at, dpe.updated_at
        \\FROM design_page_elements dpe
        \\WHERE dpe.id = ?
    , &.{element_id});
    defer q.deinit();

    const row = (try q.next()) orelse return error.ElementNotFound;
    var duped_id: []u8 = undefined;
    var duped_page_id: []u8 = undefined;
    var duped_name: []u8 = undefined;
    var duped_file_path: []u8 = undefined;
    var duped_created_at: []u8 = undefined;
    var duped_updated_at: []u8 = undefined;
    var x: i64 = undefined;
    var y: i64 = undefined;
    var w: i64 = undefined;
    var h: i64 = undefined;
    var z: i64 = undefined;
    var pos: i64 = undefined;
    {
        defer row.deinit(allocator);
        duped_id = try allocator.dupe(u8, row.values[0]);
        duped_page_id = try allocator.dupe(u8, row.values[1]);
        duped_name = try allocator.dupe(u8, row.values[2]);
        duped_file_path = try allocator.dupe(u8, row.values[3]);
        x = std.fmt.parseInt(i64, row.values[4], 10) catch return error.FileIoFailed;
        y = std.fmt.parseInt(i64, row.values[5], 10) catch return error.FileIoFailed;
        w = std.fmt.parseInt(i64, row.values[6], 10) catch return error.FileIoFailed;
        h = std.fmt.parseInt(i64, row.values[7], 10) catch return error.FileIoFailed;
        z = std.fmt.parseInt(i64, row.values[8], 10) catch return error.FileIoFailed;
        pos = std.fmt.parseInt(i64, row.values[9], 10) catch return error.FileIoFailed;
        duped_created_at = try allocator.dupe(u8, row.values[10]);
        duped_updated_at = try allocator.dupe(u8, row.values[11]);
    }
    errdefer {
        allocator.free(duped_id);
        allocator.free(duped_page_id);
        allocator.free(duped_name);
        allocator.free(duped_file_path);
        allocator.free(duped_created_at);
        allocator.free(duped_updated_at);
    }

    // Read the html from disk. Look up the workspace item's path
    // (needed to resolve file_path → absolute path).
    const page = getPage(allocator, db, duped_page_id) catch |err| {
        if (err == error.PageNotFound) return error.ElementNotFound;
        return error.FileIoFailed;
    };
    defer freePageFull(allocator, page);

    const item = resolveWorkspaceItem(allocator, db, page.workspace_item_id) catch |err| {
        if (err == error.WorkspaceItemNotFound) return error.WorkspaceItemNotFound;
        return error.FileIoFailed;
    };
    defer item.deinit(allocator);
    const item_path = item.path orelse return error.WorkspaceItemPathRequired;

    // Open the workspace item dir + read the file relative to it.
    const dir = std.Io.Dir.cwd().openDir(io, item_path, .{}) catch return error.FileIoFailed;
    defer dir.close(io);
    const html = dir.readFileAlloc(io, duped_file_path, allocator, .unlimited) catch
        return error.FileIoFailed;

    return DesignPageElementFull{
        .id = duped_id,
        .page_id = duped_page_id,
        .name = duped_name,
        .file_path = duped_file_path,
        .x = x,
        .y = y,
        .width = w,
        .height = h,
        .z_index = z,
        .position = pos,
        .created_at = duped_created_at,
        .updated_at = duped_updated_at,
        .html = html,
    };
}

/// List all elements of a page, ordered by `z_index ASC, position ASC`.
/// Returns metadata only (no html bodies). Use `getElement` to fetch
/// a single element's html.
pub fn listElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) ElementError![]DesignPageElement {
    var q = try db.query(allocator,
        \\SELECT dpe.id, dpe.page_id, dpe.name, dpe.file_path,
        \\       dpe.x, dpe.y, dpe.width, dpe.height,
        \\       dpe.z_index, dpe.position,
        \\       dpe.created_at, dpe.updated_at
        \\FROM design_page_elements dpe
        \\WHERE dpe.page_id = ?
        \\ORDER BY dpe.z_index ASC, dpe.position ASC
    , &.{page_id});
    defer q.deinit();

    var rows = std.ArrayList(DesignPageElement).empty;
    errdefer {
        for (rows.items) |e| {
            allocator.free(e.id);
            allocator.free(e.page_id);
            allocator.free(e.name);
            allocator.free(e.file_path);
            allocator.free(e.created_at);
            allocator.free(e.updated_at);
        }
        rows.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .page_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .file_path = try allocator.dupe(u8, row.values[3]),
            .x = std.fmt.parseInt(i64, row.values[4], 10) catch return error.FileIoFailed,
            .y = std.fmt.parseInt(i64, row.values[5], 10) catch return error.FileIoFailed,
            .width = std.fmt.parseInt(i64, row.values[6], 10) catch return error.FileIoFailed,
            .height = std.fmt.parseInt(i64, row.values[7], 10) catch return error.FileIoFailed,
            .z_index = std.fmt.parseInt(i64, row.values[8], 10) catch return error.FileIoFailed,
            .position = std.fmt.parseInt(i64, row.values[9], 10) catch return error.FileIoFailed,
            .created_at = try allocator.dupe(u8, row.values[10]),
            .updated_at = try allocator.dupe(u8, row.values[11]),
        });
    }
    return rows.toOwnedSlice(allocator);
}

/// Optional fields passed to `updateElement`. `null` leaves the
/// column unchanged; non-null overwrites it. File IO is performed
/// only when `html` or `name` is non-null.
pub const ElementUpdate = struct {
    html: ?[]const u8 = null,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    z_index: ?i64 = null,
    name: ?[]const u8 = null,
};

/// Partial update of an element. Any field that's `null` in `patch`
/// is left unchanged; non-null values overwrite the column.
///
///   - `html` non-null → write to disk (overwrite the existing file).
///     If `name` is also changing, the file is moved (old unlinked,
///     new written) so the file_path follows the new name.
///   - `name` non-null → derive a new file_path via
///     `sanitizeFilename(name)`. The old file is unlinked AFTER
///     the metadata row updates (fail-safe: DB is the source of truth,
///     so update DB first, then clean up the old file).
///   - `x`/`y`/`width`/`height`/`z_index` non-null → overwrite column.
///
/// Returns `error.ElementNotFound` if no row matches, or
/// `error.InvalidFilename` if the new name sanitizes to empty.
pub fn updateElement(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
    patch: ElementUpdate,
) ElementError!void {
    // 1. Look up the existing row to know the current state
    //    (page_id, file_path, name) for any file IO.
    const existing = blk: {
        var q = try db.query(allocator,
            \\SELECT dpe.id, dpe.page_id, dpe.name, dpe.file_path
            \\FROM design_page_elements dpe
            \\WHERE dpe.id = ?
        , &.{element_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.ElementNotFound;
        defer row.deinit(allocator);
        break :blk struct {
            id: []u8,
            page_id: []u8,
            name: []u8,
            file_path: []u8,
        }{
            .id = try allocator.dupe(u8, row.values[0]),
            .page_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .file_path = try allocator.dupe(u8, row.values[3]),
        };
    };
    defer allocator.free(existing.id);
    defer allocator.free(existing.page_id);
    defer allocator.free(existing.name);
    defer allocator.free(existing.file_path);

    // 2. If `patch.name` is changing, derive a new file_path. We
    //    update the file on disk BEFORE the metadata row (the row
    //    references the file_path, so the old file is unreachable
    //    after the update). Actually — safer: update the DB first
    //    (so a crash mid-update leaves a consistent "new file_path
    //    pointing at an old file" state which is recoverable; the
    //    OPPOSITE — "old file_path pointing at a new file" — would
    //    point reads at the wrong content).
    var new_file_path: ?[]u8 = null;
    defer if (new_file_path) |p| allocator.free(p);
    // Cache the workspace item path so we can resolve the
    // `existing.file_path` / `new_file_path` to absolute paths in
    // step 4 (file IO) without a second DB roundtrip.
    var item_path_cache: []u8 = &[_]u8{};
    defer if (item_path_cache.len > 0) allocator.free(item_path_cache);
    if (patch.name) |new_name| {
        if (!std.mem.eql(u8, new_name, existing.name)) {
            // Look up the page + workspace item to build the new path.
            const page = getPage(allocator, db, existing.page_id) catch |err| {
                if (err == error.PageNotFound) return error.ElementNotFound;
                return error.FileIoFailed;
            };
            defer freePageFull(allocator, page);
            const item = resolveWorkspaceItem(allocator, db, page.workspace_item_id) catch |err| {
                if (err == error.WorkspaceItemNotFound) return error.WorkspaceItemNotFound;
                return error.FileIoFailed;
            };
            defer item.deinit(allocator);
            const item_path = item.path orelse return error.WorkspaceItemPathRequired;
            item_path_cache = try allocator.dupe(u8, item_path);

            const sanitized = try sanitizeFilename(allocator, new_name);
            defer allocator.free(sanitized);
            new_file_path = try relativeElementFilePath(allocator, page.name, sanitized);
            try ensureElementDir(allocator, item_path, page.name);
        }
    }

    // 3. Build the UPDATE SQL. We always bump updated_at. The WHERE
    //    matches the row by id; we don't need to handle the
    //    "row vanished" race because the caller already saw the row
    //    via the SELECT above.
    //
    //    Use ArrayList.print to assemble the column list. Only the
    //    columns whose `patch.*` is non-null are SET. Mirrors the
    //    kanban partial-update pattern.
    var sql_buf: std.ArrayList(u8) = .empty;
    defer sql_buf.deinit(allocator);
    try sql_buf.appendSlice(allocator, "UPDATE design_page_elements SET ");
    var first = true;
    if (patch.x) |v| {
        if (!first) try sql_buf.append(allocator, ',');
        try sql_buf.print(allocator, " x = {d}", .{v});
        first = false;
    }
    if (patch.y) |v| {
        if (!first) try sql_buf.append(allocator, ',');
        try sql_buf.print(allocator, " y = {d}", .{v});
        first = false;
    }
    if (patch.width) |v| {
        if (!first) try sql_buf.append(allocator, ',');
        try sql_buf.print(allocator, " width = {d}", .{v});
        first = false;
    }
    if (patch.height) |v| {
        if (!first) try sql_buf.append(allocator, ',');
        try sql_buf.print(allocator, " height = {d}", .{v});
        first = false;
    }
    if (patch.z_index) |v| {
        if (!first) try sql_buf.append(allocator, ',');
        try sql_buf.print(allocator, " z_index = {d}", .{v});
        first = false;
    }
    if (patch.name) |n| {
        if (!first) try sql_buf.append(allocator, ',');
        try sql_buf.print(allocator, " name = '{s}'", .{n});
        first = false;
    }
    if (new_file_path) |fp| {
        if (!first) try sql_buf.append(allocator, ',');
        try sql_buf.print(allocator, " file_path = '{s}'", .{fp});
        first = false;
    }
    if (first) {
        // Nothing to update; just bump updated_at.
        try sql_buf.appendSlice(allocator, "updated_at = datetime('now')");
    } else {
        try sql_buf.appendSlice(allocator, ", updated_at = datetime('now')");
    }
    try sql_buf.print(allocator, " WHERE id = '{s}'", .{element_id});

    try db.exec(allocator, sql_buf.items, &.{});

    // 4. Now that the DB row is updated, do the file IO:
    //    - if `html` is set: write to the (possibly new) file_path.
    //      Overwrites in place.
    //    - if `name` changed: unlink the OLD file (the new one was
    //      written in step 2 if html was also set; otherwise we just
    //      unlink the old and leave the new to be created on next
    //      updateElement with html).
    //
    //    We deliberately do file IO AFTER the DB update so a crash
    //    mid-step leaves a consistent "metadata is up to date, file
    //    may be missing or old" state — which is recoverable on the
    //    next update. The opposite ordering (file first) would
    //    briefly point reads at the wrong content.
    if (patch.html != null or new_file_path != null) {
        // We need the absolute file path for file IO. If the name
        // didn't change, item_path_cache is empty; fetch it now.
        if (item_path_cache.len == 0) {
            const page2 = getPage(allocator, db, existing.page_id) catch |err| {
                if (err == error.PageNotFound) return error.ElementNotFound;
                return error.FileIoFailed;
            };
            defer freePageFull(allocator, page2);
            const item2 = resolveWorkspaceItem(allocator, db, page2.workspace_item_id) catch |err| {
                if (err == error.WorkspaceItemNotFound) return error.WorkspaceItemNotFound;
                return error.FileIoFailed;
            };
            defer item2.deinit(allocator);
            const ip = item2.path orelse return error.WorkspaceItemPathRequired;
            item_path_cache = try allocator.dupe(u8, ip);
        }
        if (patch.html) |h| {
            // Write the html to the (possibly new) file_path. When
            // name is also changing, this populates the new file
            // (the old one is unlinked below).
            const rel_target = new_file_path orelse existing.file_path;
            const abs_target = try absoluteElementPath(allocator, item_path_cache, rel_target);
            defer allocator.free(abs_target);
            try writeElementFile(io, abs_target, h);
        }
        if (new_file_path != null) {
            // Name changed. Two cases:
            //   - html was also set: the new file was just written
            //     above. We just unlink the old file.
            //   - html was NOT set: the existing file content must
            //     follow the rename — RENAME the old file to the
            //     new path (rather than copy-then-unlink, which is
            //     atomic on POSIX).
            const abs_old = try absoluteElementPath(allocator, item_path_cache, existing.file_path);
            defer allocator.free(abs_old);
            if (patch.html != null) {
                unlinkElementFile(abs_old);
            } else {
                const abs_new = try absoluteElementPath(allocator, item_path_cache, new_file_path.?);
                defer allocator.free(abs_new);
                renameFile(abs_old, abs_new);
            }
        }
    }
}

/// Rename `old_path` to `new_path`. Both paths are absolute. Best-
/// effort: a failure is silently swallowed (the caller has
/// already committed the DB row, so the file is in an unknown
/// state on disk but the metadata is consistent).
fn renameFile(old_path: []const u8, new_path: []const u8) void {
    var old_z: [std.fs.max_path_bytes:0]u8 = undefined;
    var new_z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (old_path.len >= old_z.len or new_path.len >= new_z.len) return;
    @memcpy(old_z[0..old_path.len], old_path);
    old_z[old_path.len] = 0;
    @memcpy(new_z[0..new_path.len], new_path);
    new_z[new_path.len] = 0;
    _ = std.c.rename(&old_z, &new_z);
}

/// Convenience for drag operations: update x/y only without
/// rewriting the html file.
pub fn moveElement(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
    x: i64,
    y: i64,
) ElementError!void {
    var q = try db.query(allocator,
        "SELECT id FROM design_page_elements WHERE id = ?", &.{element_id});
    defer q.deinit();
    const row = try q.next();
    if (row == null) return error.ElementNotFound;
    if (row) |r| r.deinit(allocator);

    const x_s = try std.fmt.allocPrint(allocator, "{d}", .{x});
    defer allocator.free(x_s);
    const y_s = try std.fmt.allocPrint(allocator, "{d}", .{y});
    defer allocator.free(y_s);

    try db.exec(allocator,
        \\UPDATE design_page_elements SET
        \\    x = ?, y = ?, updated_at = datetime('now')
        \\WHERE id = ?
    , &.{ x_s, y_s, element_id });
}

/// Convenience for resize operations: update width/height only.
pub fn resizeElement(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
    width: i64,
    height: i64,
) ElementError!void {
    var q = try db.query(allocator,
        "SELECT id FROM design_page_elements WHERE id = ?", &.{element_id});
    defer q.deinit();
    const row = try q.next();
    if (row == null) return error.ElementNotFound;
    if (row) |r| r.deinit(allocator);

    const w_s = try std.fmt.allocPrint(allocator, "{d}", .{width});
    defer allocator.free(w_s);
    const h_s = try std.fmt.allocPrint(allocator, "{d}", .{height});
    defer allocator.free(h_s);

    try db.exec(allocator,
        \\UPDATE design_page_elements SET
        \\    width = ?, height = ?, updated_at = datetime('now')
        \\WHERE id = ?
    , &.{ w_s, h_s, element_id });
}

/// Delete an element. Removes the DB row AND unlinks the file on
/// disk (idempotent if the file is already missing). Returns `true`
/// if a row was deleted, `false` if no such id exists (no error).
pub fn deleteElement(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) ElementError!bool {
    // 1. Capture file_path BEFORE the row vanishes (we need it to
    //    unlink the file). Also need the workspace_item.path to
    //    resolve the relative file_path to an absolute path.
    var file_path: ?[]u8 = null;
    var page_id: ?[]u8 = null;
    {
        var q = try db.query(allocator,
            "SELECT dpe.file_path, dpe.page_id FROM design_page_elements dpe WHERE dpe.id = ?",
            &.{element_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            file_path = try allocator.dupe(u8, row.values[0]);
            page_id = try allocator.dupe(u8, row.values[1]);
        }
    }
    defer if (file_path) |fp| allocator.free(fp);
    defer if (page_id) |pid| allocator.free(pid);

    if (file_path == null) return false; // no such id

    // 2. Delete the row.
    try db.exec(allocator,
        "DELETE FROM design_page_elements WHERE id = ?",
        &.{element_id});

    // 3. Unlink the file (idempotent — file may already be missing
    //    due to manual deletion or a crash mid-update). Resolve
    //    the relative file_path against workspace_item.path.
    if (file_path != null and page_id != null) {
        const page_for_io = getPage(allocator, db, page_id.?) catch return true;
        defer freePageFull(allocator, page_for_io);
        const item_for_io = resolveWorkspaceItem(allocator, db, page_for_io.workspace_item_id) catch
            return true;
        defer item_for_io.deinit(allocator);
        if (item_for_io.path) |ip| {
            const abs = absoluteElementPath(allocator, ip, file_path.?) catch return true;
            defer allocator.free(abs);
            unlinkElementFile(abs);
        }
    }
    return true;
}