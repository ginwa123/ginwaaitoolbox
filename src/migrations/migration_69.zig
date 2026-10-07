const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 069 — Add `workspace_item_tasks.image_urls` column
/// (kanban-image-urls-column plan, 2026-08-06).
///
/// ## Why this migration exists
///
/// Until now, the only way to attach an image to a kanban task was the
/// filesystem-backed attachment endpoint (`POST /api/workspaces/tasks/:id/attachments`),
/// which writes the file to `<workspace_item.path>/.pabrik/attachments/<task_id>/<n>.<ext>`
/// and serves it back via a broken `GET /...attachments/*` wildcard route
/// (the custom router doesn't actually handle `*` — see
/// `src/modules/custom_http_server/src/router.zig::matchPathWithParams`).
/// Net effect: images uploaded that way were 404'd on every read.
///
/// The user feedback (task_id tracking) was unambiguous: stop using the
/// attachment endpoint, add a new column on `workspace_item_tasks` that
/// stores the raw base64 data URL inline. Self-contained, no filesystem,
/// no separate GET endpoint, no broken route. The image renders directly
/// via `<img :src="task.imageUrls[0]">`.
///
/// ## Storage format
///
/// `image_urls TEXT NOT NULL DEFAULT ''` — `||`-delimited base64 data
/// URLs. Some images carry kilobytes of payload (post-downscale), so we
/// put the column in TEXT (not VARCHAR) and avoid any CLOB boundaries.
/// The `||` delimiter is the same convention used by the
/// `llm_history.image_url` `||`-delimited string (Migration 036 + the
/// `saveMessage` join at `llm_history.zig:1207-1221`).
///
/// On read: split on `|` into `[]u8` slices; each non-empty slice is a
/// data URL. On write: `ArrayList(u8).appendSlice(url)` + `"||"` between
/// non-empty entries; an empty input list yields `""` (the column's
/// DEFAULT). The wire format is identical to `llm_history.image_url` so
/// any helper that handles `||`-delimited URL strings can be reused.
///
/// ## Why `||` and not `JSON` (per the user's "like llm_history" hint)
///
/// The `llm_history.image_url` column already uses `||` for the same
/// shape. Following the same convention here means:
///
///   - One code path for the join / split helpers (a single `||` is
///     easy to grep; JSON would diverge from the precedent).
///   - No `json_valid` / `json_type` defensive checks needed (the
///     `tags` column has those for malformed-data reasons; a `||`
///     delimiter is unambiguous).
///   - SQLite `LIKE` filtering on image URLs is straightforward if
///     we ever need to search by URL.
///
/// ## Idempotency / fresh-DB safety
///
/// `addColumnIfMissing` is the canonical helper that wraps `ALTER TABLE`
/// in a column-existence check. Both fresh-DB replay (the canonical
/// `CREATE TABLE workspace_item_tasks` body in Migration 026 doesn't
/// declare `image_urls`) and upgrade-from-v1 paths land on the same
/// end state.
///
/// ## User-visible wire format
///
/// The handler reads `image_urls` as the raw `||`-delimited string and
/// returns it in the JSON response as-is. The frontend parses with
/// `s.split('|').filter(Boolean)` (no JSON wrap, no double-encoding).
/// This keeps the round-trip trivial to debug — the value you see in
/// the DB is the value you see in the network tab.
///
/// Plan: docs/superpowers/plans/2026-08-06-kanban-image-urls-column.md
/// Bug: task_1785795051796 ("kanban task not saving the images or
/// base 64 in kanban description, after create a task or run aent")
pub const Migration069AddTaskImageUrls = struct {
    pub const version: u32 = 69;
    pub const name = "add_task_image_urls";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // `image_urls TEXT NOT NULL DEFAULT ''` — the empty string is the
        // canonical "no images" sentinel (matches `description` / `tags`
        // patterns from Migrations 062 / 067). `addColumnIfMissing`
        // constructs `ALTER TABLE {table} ADD COLUMN {definition}`, so
        // the definition MUST include the column name AND the type —
        // omitting the type would create a column literally named
        // "TEXT NOT NULL DEFAULT ''". See project memory
        // `addColumnIfMissing-requires-name-type`.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_item_tasks",
            "image_urls",
            "image_urls TEXT NOT NULL DEFAULT ''",
        );
    }
};
