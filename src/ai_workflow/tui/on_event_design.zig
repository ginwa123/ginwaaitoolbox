//! JSON payload structs for design-mode SSE events.
//!
//! One struct per wire event:
//!   - `DesignElementCreatedData` — emitted on `addElement` (HTTP
//!     handler or LLM `add_element` tool). Frontend listener uses
//!     this to re-fetch the page's element list so the new element
//!     appears in the layers panel + canvas.
//!
//!   - `DesignElementUpdatedData` — emitted on `updateElement` (any
//!     field change, including the contenteditable / Monaco HTML
//!     save and the drag/resize geometry patch). Same shape as
//!     `created` so the frontend listener can treat them uniformly.
//!
//!   - `DesignElementDeletedData` — emitted on `deleteElement`. The
//!     frontend removes the element from the local Pinia store
//!     without a re-fetch when possible.
//!
//! Field names match the frontend's `DesignElementEvent` interface
//! (camelCase for `action`, snake_case for the ids — see
//! `src/apps/desktop/src/api/index.ts`).
//!
//! All three structs share the same shape. The split into three
//! types is for documentation and for future evolution (e.g. a
//! new "moved" event could carry the old + new page id without
//! affecting the other two).
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 2)

/// JSON payload for the `design_element_created` SSE event.
pub const DesignElementCreatedData = struct {
    /// "created"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
};

/// JSON payload for the `design_element_updated` SSE event.
pub const DesignElementUpdatedData = struct {
    /// "updated"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
};

/// JSON payload for the `design_element_deleted` SSE event.
pub const DesignElementDeletedData = struct {
    /// "deleted"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
};
