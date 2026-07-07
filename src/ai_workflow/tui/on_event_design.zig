//! Wire-shape types for design SSE events.
//!
//! Four event families are emitted on every successful design-page
//! or design-element mutation (HTTP handler or LLM tool):
//!
//!   - `design_page_updated`   — fired when a page is created or
//!     replaced. Carries the full page payload (id, name, geometry,
//!     position, timestamps) so the frontend can patch the tab
//!     strip in place without a follow-up GET.
//!   - `design_page_deleted`   — fired when a page is deleted.
//!     Carries only the ids + name (the page row is gone).
//!   - `design_element_created` — fired when an element is added
//!     to a page. Carries metadata only (the html lives on disk;
//!     the frontend reads it via GET /elements/:eid).
//!   - `design_element_updated` — fired when an element is
//!     replaced (name/html/geometry). Metadata only.
//!   - `design_element_deleted` — fired when an element is removed.
//!     Carries the id + page_id so the frontend can drop the
//!     positioned div + free its iframe.
//!
//! These structs are also serialized directly via
//! `std.json.Stringify.valueAlloc` for the SSE wire format, so the
//! field names here ARE the JSON field names the frontend reads
//! (frontend types live in `src/apps/desktop/src/api/index.ts`).
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2 + 3, SSE emitters)

/// One full page, included as a nested object on
/// `DesignPageUpdatedData`. Field names match the
/// `DesignPageFull` interface on the frontend.
///
/// Note: pages have NO `html` field (the v5 file-backed model
/// stores html on `design_page_elements` only). Geometry
/// (`width`/`height`/`x`/`y`) is carried so the frontend can
/// layout the tab strip without a follow-up GET.
pub const PagePayload = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    width: i64,
    height: i64,
    x: i64,
    y: i64,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// JSON payload for a `design_page_updated` SSE event.
pub const DesignPageUpdatedData = struct {
    /// `"created"` for the first `set_design_page` on a fresh
    /// name, `"updated"` for replacements. The frontend uses this
    /// to decide whether to add a new tab (created) or replace
    /// the geometry in an existing tab (updated).
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

/// One element's metadata, included as a nested object on
/// `DesignElementCreatedData` / `DesignElementUpdatedData`.
/// NO `html` — the html is on disk and the frontend fetches it
/// on demand via GET /design/pages/:page_id/elements/:element_id.
pub const ElementPayload = struct {
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    /// Relative path (`.nalar/design/<page_name>/<element_sanitized>.html`).
    /// Stored on the row; useful for debugging and "open in editor"
    /// UI affordances on the frontend.
    file_path: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    z_index: i64,
    /// Iteration order within the page (separate from z_index —
    /// drives the "add new element at the end" behavior of
    /// `addElement`'s COALESCE+1 default).
    position: i64,
};

/// JSON payload for a `design_element_created` SSE event.
pub const DesignElementCreatedData = struct {
    /// Always `"created"`. Symmetric with the page event family.
    action: []const u8 = "created",
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element: ElementPayload,
};

/// JSON payload for a `design_element_updated` SSE event.
/// Fired for PUT (full or partial update), PATCH move, PATCH
/// resize.
pub const DesignElementUpdatedData = struct {
    /// `"updated"` for PUT body updates; `"moved"` for PATCH move;
    /// `"resized"` for PATCH resize. The frontend uses this to
    /// decide between "re-render the iframe" (updated) and "just
    /// update the positioned div's CSS transform" (moved/resized)
    /// — though v1 may treat them all the same.
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element: ElementPayload,
};

/// JSON payload for a `design_element_deleted` SSE event. The
/// frontend drops the positioned div + frees its iframe.
pub const DesignElementDeletedData = struct {
    action: []const u8 = "deleted",
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
};