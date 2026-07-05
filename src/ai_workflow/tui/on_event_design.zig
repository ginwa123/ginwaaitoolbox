//! Wire-shape types for design SSE events.
//!
//! Two event families are emitted on every successful design-page
//! mutation:
//!
//!   - `design_page_updated` — fired when a page is created (via
//!     `set_design_page` from the LLM tool) or replaced (via the
//!     HTTP PUT handler or `updatePageHtml`). Carries the full page
//!     payload so the frontend can patch the tab strip + body in
//!     place without a follow-up GET.
//!
//!   - `design_page_deleted` — fired when a page is deleted (via
//!     the HTTP DELETE handler or the `delete_design_page` tool).
//!     Carries only the ids + name (no html — the page is gone).
//!
//! These structs are also serialized directly via
//! `std.json.Stringify.valueAlloc` for the SSE wire format, so the
//! field names here ARE the JSON field names the frontend reads
//! (frontend types live in `src/apps/desktop/src/api/index.ts`).
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.2).

/// One full page, included as a nested object on
/// `DesignPageUpdatedData`. Field names match the
/// `DesignPageFull` interface on the frontend.
pub const PagePayload = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    /// Full HTML body — included so the frontend can patch the
    /// iframe without a follow-up GET. Up to 5 MB (the PUT body
    /// limit).
    html: []const u8,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// JSON payload for a `design_page_updated` SSE event.
pub const DesignPageUpdatedData = struct {
    /// `"created"` for the first `set_design_page` on a fresh
    /// name, `"updated"` for replacements. The frontend uses this
    /// to decide whether to add a new tab (created) or replace
    /// the html in an existing tab (updated).
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    page: PagePayload,
};

/// JSON payload for a `design_page_deleted` SSE event. `page_id`
/// and `page_name` are sufficient for the frontend to remove the
/// tab + free the iframe.
pub const DesignPageDeletedData = struct {
    /// Always `"deleted"` — kept explicit for symmetry with the
    /// updated event and so future actions (e.g. `"purged"`) can
    /// be added without breaking the frontend discriminator.
    action: []const u8 = "deleted",
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    page_name: []const u8,
};