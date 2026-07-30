//! `GET /api/workspaces/:ws_id/items/:item_id/kanban/tags?limit=N&offset=K`.
//!
//! Returns one page of distinct tags from tasks belonging to the
//! given kanban workspace item, ordered by frequency DESC then
//! most-recent usage DESC. Powers the kanban task detail dialog's
//! tag autocomplete dropdown. Pagination is via `limit` + `offset`.
//!
//! Response: `{ tags: [{name, count, last_used_at}], has_more }`.
//!
//! Mirrors the layered shape of `tasks_list.zig` (useCase + thin
//! handler that maps errors to status codes / JSON). The useCase
//! body + behavioural tests land in Task 1.4; this file is the
//! red scaffolding only — the handler currently returns 501 with
//! `{"error":"not implemented"}` so the route is wired but not
//! exercised.
//!
//! Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;

pub fn kanbanTagsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = ctx;
    _ = req;
    return res.jsonResponse(.{
        .status_code = 501,
        .data = "{\"error\":\"not implemented\"}",
    });
}
