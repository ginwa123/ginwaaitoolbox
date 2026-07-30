# Kanban Task Tags — Lazy Autocomplete from Recent History

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user is typing a tag in the kanban task detail dialog, show a dropdown of suggestions drawn from the **distinct tags that already exist on other tasks in the same kanban board**. Suggestions are loaded **lazily** (only when the user focuses the tag input) and **paginated** (the dropdown grows as the user scrolls, fetching the next page from the server). The first batch is ordered by usage frequency (most-used first), with a tie-breaker on the most-recent task that used each tag. This is a UX polish feature on top of the existing free-form tag input.

**User-facing behaviour:**

| User action | What happens |
|---|---|
| Click into the Tags input on a kanban task | First batch (top 8 most-used tags, filtered to exclude tags already on the current task) is fetched lazily. Each suggestion is a small chip with a small "(N)" usage count. |
| Scroll the dropdown to the bottom | If more tags exist past the current page, the next 8 are fetched and appended. A small "Loading more…" indicator is shown while the fetch is in flight. |
| Scroll to the very end | The "Loading more…" indicator disappears — no more fetches happen. |
| Type a few characters in the input | Suggestions are filtered to tags whose lowercase form starts with the typed prefix (case-insensitive). The filter is client-side — does NOT trigger a new fetch (the paginated list is already in memory). |
| Click a suggestion | It becomes a chip on the task (same path as if the user typed the tag and pressed Enter). The dropdown closes. |
| Press Enter / comma (the existing commit keys) | The typed text becomes a chip, dropdown closes. |
| Press ArrowDown / ArrowUp + Enter (keyboard nav) | Highlights the next/prev suggestion; Enter accepts it. |
| Click outside / Esc / blur | Dropdown closes; existing auto-commit-on-blur still fires. |

**Architecture:**

1. **NEW** backend endpoint `GET /api/workspaces/:ws/items/:item/kanban/tags?limit=8&offset=0` — returns one page of distinct tags ordered by frequency DESC, then by most-recent usage DESC. `limit` defaults to 8, max 50. `offset` defaults to 0. Response is `{ tags: [{name, count, last_used_at}], has_more: bool }`. Reuses the existing tag JSON column (Migration 067); no schema change.
2. **NEW** `src/ai_workflow/tui/llm_history.zig::listKanbanDistinctTags` — model function with `(workspace_item_id, limit, offset)` signature. Uses `json_each()` over the `tags` column, `GROUP BY je.value`, `COUNT(*)`, `MAX(updated_at)`, `ORDER BY count DESC, last_used DESC`, `LIMIT N+1 OFFSET K`. The `LIMIT N+1` trick lets the caller compute `has_more` from a single query (if we got N+1 rows, trim to N and set `has_more = true`).
3. **NEW** `src/ai_workflow/tui/http_handlers/kanban_tags_list.zig` — thin handler: parse `?limit=` / `?offset=` query, call the model fn, return `{ tags, has_more }`. Standard thin-handler pattern (see `tasks_list.zig`).
4. **EDIT** `src/apps/desktop/src/api/index.ts` — `getKanbanTagSuggestions(ws, item, { limit?, offset? })` wrapping `apiFetch`. Returns `{ tags, has_more }`.
5. **NEW** `src/apps/desktop/src/composables/useKanbanTagSuggestions.ts` — composable that owns the lazy-load + pagination lifecycle: `ensureLoaded()`, `loadNextPage()`, `reset()`. Internally tracks `loaded: KanbanTagSuggestion[]`, `hasMore: boolean`, `loading: boolean`. Exposes a `triggerRef` sentinel that mounts at the bottom of the dropdown so callers can wire an `IntersectionObserver` to it.
6. **EDIT** `src/apps/desktop/src/stores/workspaces.ts` — slim wrapper that delegates to the composable (or the composable is used directly in the dialog; see "Architecture Decisions" for the final choice).
7. **EDIT** `src/apps/desktop/src/components/kanban/KanbanTagsInput.vue` — accept `:suggestions` (current loaded list), `:has-more`, `:loading-more` props. Render a small dropdown panel anchored below the input. IntersectionObserver on a scroll sentinel at the bottom triggers `loadNextPage` when visible. Keyboard nav (ArrowUp/Down/Enter/Esc), click-to-commit, case-insensitive prefix filter, hide when input has focus but no characters typed AND no existing chips (or show always when focus is on input).
8. **EDIT** `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` — mount the `useKanbanTagSuggestions` composable, pass the loaded list + flags + a `loadNextPage` callback to `<KanbanTagsInput>`. Reset on dialog open (the cache key includes `item.id` so opening a different kanban gets a fresh fetcher). Filter out chips already on the current task (the model can't know about an unsaved draft).
9. **NEW** test files — `kanban_tags_list_test.zig` (`has_more`, `offset`, `LIMIT N+1` behavior), `KanbanTagsInput.autocomplete.spec.ts` (dropdown + scroll trigger + "loading more" indicator), `useKanbanTagSuggestions.spec.ts` (lazy-load + pagination lifecycle).

**Tech Stack:** Zig 0.16 (backend), SQLite via `nalarcore.sqlite.SqliteBackend`, Vue 3 + TypeScript + Vitest (frontend). No new dependencies.

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-tag-autocomplete` on branch `worktree/kanban-tag-autocomplete`

## Global Constraints

- **Cross-platform** — every step must work on Linux, macOS, AND Windows. No `std.posix.*` direct calls; use `nalarcore.helpers.*` wrappers.
- **Zig 0.16 stdlib** — follow the existing thin-handler pattern in `tasks_list.zig`. Use `parseFromSliceLeaky` if any body parsing is needed (this GET endpoint takes only a query, no body, so it doesn't matter).
- **TDD** — every implementation step is preceded by a failing test step. Prefer behavioural tests over static-contract grep when feasible (per `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`).
- **No static-contract tests** — every test in this plan is behavioural. No `expect(source).toContain(...)` / `indexOf(u8, source, ...)` patterns.
- **Vue 3** — `bun run build` is the type-check (vue-tsc); `bunx vitest run` does NOT type-check. Run BOTH before declaring done.
- **Verification before completion** — `zig build test --summary all` + `zig build install:linux:system` + `rm -rf zig-out/bin && zig build` + `bun run build` + `bunx vitest run` must all pass before any task is marked complete.
- **No comments above `logger.infoFmt(...)` calls** (per `~/.config/nalar/memories/no-comments-on-logger-calls.md`).
- **End-to-end smoke** — final task includes a curl-based smoke test against port 8080 (NEVER 8081) to verify the suggestions endpoint paginates correctly.

## File Touch Map

| File | Action | Lines (est.) |
|---|---|---|
| `src/ai_workflow/tui/llm_history.zig` | EDIT | +80 (`listKanbanDistinctTags` with offset + tests) |
| `src/ai_workflow/tui/http_handlers/kanban_tags_list.zig` | NEW | ~140 (handler + useCase + limit/offset parsing) |
| `src/ai_workflow/tui/http_handlers/kanban_tags_list_test.zig` | NEW | ~240 (behavioural tests for pagination) |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | EDIT | +35 (`KanbanTagSuggestionResponse` + `has_more` + make fn) |
| `src/ai_workflow/tui/http_handlers/mod.zig` | EDIT | +1 (re-export) |
| `src/main.zig` | EDIT | +1 (route registration) |
| `src/ai_workflow/tui/test_runner.zig` | EDIT | +1 (register test) |
| `src/apps/desktop/src/api/index.ts` | EDIT | +35 (`getKanbanTagSuggestions` with pagination) |
| `src/apps/desktop/src/composables/useKanbanTagSuggestions.ts` | NEW | ~90 (lazy-load + pagination composable) |
| `src/apps/desktop/src/components/kanban/KanbanTagsInput.vue` | EDIT | +140 (suggestions prop + dropdown + scroll sentinel + keyboard nav) |
| `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | EDIT | +30 (mount composable + pass to input + filter) |
| `src/apps/desktop/src/__tests__/KanbanTagsInput.autocomplete.spec.ts` | NEW | ~280 (behavioural tests) |
| `src/apps/desktop/src/__tests__/useKanbanTagSuggestions.spec.ts` | NEW | ~180 (lazy + pagination tests) |

Total: ~13 files, ~4 NEW + ~9 EDIT. ~1280 lines net.

---

## Architecture Decisions

### Why lazy (fetch on focus, not on dialog open)

The dialog is opened by the user to edit a task. The user may not interact with the tag input at all (e.g., they're just renaming the task). Fetching the full suggestions list on every dialog open would be wasteful for non-tag-related edits. Lazy fetch on focus is the minimum-invasive option: a no-op for users who don't touch tags, an immediate suggestion list for users who do.

### Why server-side pagination (vs client-side "fetch all")

- A kanban with 500 distinct tags is rare but possible. Returning all 500 in one response is wasteful if the user only sees 8 (~99% of the payload is never rendered).
- Server-side pagination lets the SQL query stay bounded (`LIMIT N+1 OFFSET K`). Cheap per request.
- The frontend's pagination is lazy anyway (only fetches more on scroll), so the per-request cost is what matters.

### Why offset-based pagination (vs cursor-based)

`tasks_list.zig` uses cursor-based pagination because the underlying sort is by `updated_at` / `created_at` (single column, monotonic). For tag suggestions the sort is `(count DESC, last_used_at DESC)` — and the data is a small SET (distinct tags per kanban), so:

- The list of distinct tags is small (typically <100). Offset pagination performs fine.
- The order is stable enough within a single dialog session (a new tag added between two fetches would only shift the last positions, not break the user's scroll).
- Offset is simpler to implement and reason about (no cursor encode/decode).

If we ever see kanbans with thousands of distinct tags, we can revisit.

### Why `LIMIT N+1` for `has_more`

Single query, no second SQL roundtrip. Classical "fetch one extra row" trick: if the query returns N+1 rows, there's more; trim to N and set `has_more = true`. If it returns ≤N rows, `has_more = false`.

### Why a composable (vs a store action)

The lifecycle is per-component-instance: load on focus, scroll to load more, reset on dialog close. A composable owns the data + lifecycle while the component is mounted; on unmount, the data is GC'd. A store would persist the data across mounts, which is unnecessary (the dialog opens/closes frequently and the underlying data changes outside the dialog too — SSE-driven task updates).

If we later want a cross-dialog cache (e.g., "user opened the same kanban's task dialog twice in a row"), we can add a thin store wrapper that the composable checks first. For v1, the composable is enough.

### Why filter "already on this task" in the dialog (not the SQL)

The model returns ALL distinct tags for the kanban. The dialog filters out tags already on the current task (including the user's draft chips). Doing this in the SQL would require passing the current task's tag list as a query parameter — messier, and the user's draft chips aren't in the DB yet. Client-side filter is one line:

```ts
const filtered = suggestions.filter(s => !excludeLower.has(s.name.toLowerCase()))
```

### Why index `name` not `count` (no DB index)

The query is `GROUP BY je.value` (json_each expansion), so the GROUP BY operates on the expanded rows, not on a column index. An index on `tags` (TEXT) wouldn't help — SQLite doesn't index JSON-array contents. The query is also bounded by `workspace_item_id` (existing index on `t.id` covers it via the `WHERE t.workspace_item_id = ?` filter). For kanbans with <1000 tasks, the GROUP BY is fast enough.

---

## Tasks

### Chunk 1 — Backend: model fn + handler + endpoint

**Outcome:** `GET /api/workspaces/:ws/items/:item/kanban/tags?limit=8&offset=0` returns one page of distinct tags for the kanban, ordered by usage count DESC then by most-recent usage DESC. Includes `has_more` for pagination. Behavioural tests cover empty kanban, single-tag, frequency ordering, recency tie-breaker, limit clamping, offset pagination, malformed-tag-JSON defensive. ~10 Zig tests pass.

---

### Task 1.1 — Add `KanbanTagSuggestion` struct + model fn (TDD, red)

**File:** `src/ai_workflow/tui/llm_history.zig`

**Step 1.** After the `WorkspaceItemTaskInfo` struct (around line 3324, the `tags: []u8 = &.{},` field), add:

```zig
/// One distinct tag suggestion for a kanban's autocomplete dropdown
/// (plan docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md).
/// Returned by `listKanbanDistinctTags` ordered by frequency DESC then
/// recency DESC. The slice fields are heap-allocated from the passed
/// allocator; the caller frees via `KanbanTagSuggestion.deinit`.
pub const KanbanTagSuggestion = struct {
    /// The tag value as it appeared in some task's tags JSON array.
    /// First-occurrence casing wins (matches tags_validation.zig).
    name: []u8,
    /// Number of tasks on this kanban whose `tags` JSON array contains
    /// this value (after json_each expansion).
    count: u32,
    /// `updated_at` of the MOST RECENT task that uses this tag, in
    /// the same `YYYY-MM-DD HH:MM:SS` format the DB stores it in.
    /// Used as the tie-breaker for sort order. null = no task has
    /// this tag (shouldn't happen in normal flow).
    last_used_at: ?[]u8,

    pub fn deinit(self: KanbanTagSuggestion, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.last_used_at) |s| allocator.free(s);
    }
};

/// Result of a single page of tag suggestions. The caller KNOWS the
/// page size (`limit` arg) so it can detect `has_more` by comparing
/// `tags.len >= limit`. We also return `has_more` directly so the
/// HTTP handler doesn't need to know the limit it passed.
pub const KanbanTagSuggestionsPage = struct {
    tags: []KanbanTagSuggestion,
    has_more: bool,

    pub fn deinit(self: KanbanTagSuggestionsPage, allocator: std.mem.Allocator) void {
        for (self.tags) |t| t.deinit(allocator);
        allocator.free(self.tags);
    }
};
```

**Step 2.** Below the existing `listWorkspaceItemTasksWithCursor` (around line 3747), add the new fn signature with a stub that returns `error.NotImplemented`:

```zig
/// Returns one page of distinct tags on tasks belonging to the
/// given workspace item, ordered by frequency DESC then by
/// most-recent usage DESC. Used by the kanban task detail dialog
/// autocomplete dropdown. Pagination: caller passes `limit` (page
/// size) and `offset` (rows to skip). Returns `has_more=true` when
/// more rows exist past the requested page.
///
/// Defensive against malformed `tags` JSON: rows whose `tags` column
/// is not a valid JSON array (legacy / corrupted rows) are skipped
/// via `WHERE json_valid(tags) = 1 AND json_type(tags) = 'array'`.
///
/// Returns an empty page (not an error) when the kanban has no tags.
///
/// Implementation uses the `LIMIT N+1` trick to compute `has_more`
/// in a single SQL query: we fetch `limit + 1` rows; if we got back
/// `limit + 1` rows, there are more, so we trim to `limit` and set
/// `has_more = true`.
pub fn listKanbanDistinctTags(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    limit: u32,
    offset: u32,
) anyerror!KanbanTagSuggestionsPage {
    _ = allocator;
    _ = db;
    _ = workspace_item_id;
    _ = limit;
    _ = offset;
    return error.NotImplemented;
}
```

**Step 3.** Add behavioural tests in `src/ai_workflow/tui/llm_history_kanban_tags_test.zig` (sibling test file per project convention for `llm_history.zig` — see `llm_history_notification_test.zig`):

```zig
//! Behavioural tests for `llm_history.listKanbanDistinctTags`.
//! Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const llm_history = nalarcore.ai_mod.llm_history;
const sqlite = nalarcore.sqlite;

fn setupDbWithTags() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal schema: workspace_items + workspace_item_tasks with the
    // tags column (Migration 067). We don't run all 66 prior migrations
    // — the model fn doesn't depend on them.
    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT NOT NULL,
        \\  updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\  tags TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id) VALUES ('item_x', 'ws_x')", &.{});
    return .{ .db = db, .threaded = threaded };
}

fn insertTaskWithTags(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, id: []const u8, item_id: []const u8, tags_json: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES (?, ?, ?)",
        &.{ id, item_id, tags_json });
}

fn insertTaskWithTagsAndUpdatedAt(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    id: []const u8,
    item_id: []const u8,
    tags_json: []const u8,
    updated_at: []const u8,
) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags, updated_at) VALUES (?, ?, ?, ?)",
        &.{ id, item_id, tags_json, updated_at });
}

test "listKanbanDistinctTags returns empty page when kanban has no tasks" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), page.tags.len);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags returns empty page when tasks exist but none have tags" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "");
    try insertTaskWithTags(&s.db, alloc, "t2", "item_x", "");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), page.tags.len);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags returns single tag from one task" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"bug\"]");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page.tags.len);
    try testing.expectEqualStrings("bug", page.tags[0].name);
    try testing.expectEqual(@as(u32, 1), page.tags[0].count);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags orders by frequency DESC (most-used first)" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    // "bug" used by 3 tasks, "urgent" used by 2, "frontend" used by 1.
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"bug\",\"urgent\"]");
    try insertTaskWithTags(&s.db, alloc, "t2", "item_x", "[\"bug\",\"frontend\"]");
    try insertTaskWithTags(&s.db, alloc, "t3", "item_x", "[\"bug\",\"urgent\"]");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), page.tags.len);
    try testing.expectEqualStrings("bug", page.tags[0].name);
    try testing.expectEqual(@as(u32, 3), page.tags[0].count);
    try testing.expectEqualStrings("urgent", page.tags[1].name);
    try testing.expectEqual(@as(u32, 2), page.tags[1].count);
    try testing.expectEqualStrings("frontend", page.tags[2].name);
    try testing.expectEqual(@as(u32, 1), page.tags[2].count);
    try testing.expectEqual(false, page.has_more);
}

test "listKanbanDistinctTags breaks ties on recency (most-recently-used wins)" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertTaskWithTagsAndUpdatedAt(&s.db, alloc, "t1", "item_x", "[\"old-tag\"]", "2025-01-01 00:00:00");
    try insertTaskWithTagsAndUpdatedAt(&s.db, alloc, "t2", "item_x", "[\"new-tag\"]", "2026-12-31 23:59:59");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page.tags.len);
    try testing.expectEqualStrings("new-tag", page.tags[0].name);
    try testing.expectEqualStrings("old-tag", page.tags[1].name);
}

test "listKanbanDistinctTags respects the limit query" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    // 5 distinct tags but ask for limit=2.
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"a\",\"b\",\"c\",\"d\",\"e\"]");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page.tags.len);
    try testing.expectEqual(true, page.has_more);  // 5 > 2, so more available
}

test "listKanbanDistinctTags has_more=false when result fits in limit" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"a\",\"b\",\"c\"]");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), page.tags.len);
    try testing.expectEqual(false, page.has_more);  // 3 <= 8, no more
}

test "listKanbanDistinctTags paginates with offset (next page fetches distinct tags past the first page)" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    // Seed 5 distinct tags, all used once. Fetch in pages of 2.
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"a\",\"b\",\"c\",\"d\",\"e\"]");
    // Page 1 (offset=0, limit=2): expect first 2 of {a,b,c,d,e} (alphabetical-ish, depends on seed).
    const page1 = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 0);
    defer page1.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page1.tags.len);
    try testing.expectEqual(true, page1.has_more);
    const page1_names = [_][]const u8{ page1.tags[0].name, page1.tags[1].name };
    // Page 2 (offset=2, limit=2): expect next 2, distinct from page 1.
    const page2 = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 2);
    defer page2.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), page2.tags.len);
    try testing.expectEqual(true, page2.has_more);
    // Combined pages must contain all 5 distinct tags.
    const page3 = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 2, 4);
    defer page3.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page3.tags.len);  // last page has 1 tag
    try testing.expectEqual(false, page3.has_more);  // exhausted
    _ = page1_names;  // suppress unused warning
}

test "listKanbanDistinctTags filters by workspace_item_id (no cross-kanban leakage)" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id) VALUES ('item_y', 'ws_x')", &.{});
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"bug\"]");
    try insertTaskWithTags(&s.db, alloc, "t2", "item_y", "[\"different\"]");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page.tags.len);
    try testing.expectEqualStrings("bug", page.tags[0].name);
}

test "listKanbanDistinctTags skips rows with malformed tags JSON (defensive)" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try insertTaskWithTags(&s.db, alloc, "t1", "item_x", "[\"good\"]");
    try insertTaskWithTags(&s.db, alloc, "t2", "item_x", "not-a-json-array");
    const page = try llm_history.listKanbanDistinctTags(alloc, &s.db, "item_x", 8, 0);
    defer page.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), page.tags.len);
    try testing.expectEqualStrings("good", page.tags[0].name);
}
```

**Step 4.** Run the test, watch it fail:

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 30
# expect: 10 failures in llm_history_kanban_tags_test with "NotImplemented"
```

**Step 5.** Register the new test file in `src/ai_workflow/tui/test_runner.zig` (find `_ = @import("llm_history_...");` imports, add `_ = @import("llm_history_kanban_tags_test.zig");`).

**Step 6.** Commit the red step: `git add ... && git commit -m "test(kanban-tags): failing tests for listKanbanDistinctTags with offset"`.

### Task 1.2 — Implement `listKanbanDistinctTags` (TDD, green)

**File:** `src/ai_workflow/tui/llm_history.zig`

**Step 1.** Replace the stub with a real implementation:

```zig
pub fn listKanbanDistinctTags(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    limit: u32,
    offset: u32,
) anyerror!KanbanTagSuggestionsPage {
    // Defensive: clamp limit to a sane max even if the caller passes
    // a huge value. The handler also clamps but defense-in-depth.
    const clamped_limit: u32 = if (limit == 0) 1 else if (limit > 50) 50 else limit;

    // LIMIT N+1 trick: fetch one extra row so we can detect has_more
    // in a single query. If the result has <= N rows, has_more=false.
    const fetch_limit: u32 = clamped_limit + 1;

    // json_each() expands the `tags` JSON array into a virtual table
    // with one row per element. json_valid + json_type filter out
    // malformed/non-array rows (legacy / corrupted). GROUP BY value
    // counts per-tag usage. MAX(updated_at) is the recency tie-breaker.
    var q = try db.query(allocator,
        \\SELECT je.value AS tag, COUNT(*) AS cnt, MAX(t.updated_at) AS last_used
        \\FROM workspace_item_tasks t, json_each(t.tags) je
        \\WHERE t.workspace_item_id = ?
        \\  AND json_valid(t.tags) = 1
        \\  AND json_type(t.tags) = 'array'
        \\GROUP BY je.value
        \\ORDER BY cnt DESC, last_used DESC
        \\LIMIT ?
        \\OFFSET ?
    , &.{
        workspace_item_id,
        std.fmt.allocPrint(allocator, "{d}", .{fetch_limit}) catch "",
        std.fmt.allocPrint(allocator, "{d}", .{offset}) catch "",
    });
    defer q.deinit();

    var results: std.ArrayList(KanbanTagSuggestion) = .empty;
    errdefer {
        for (results.items) |r| r.deinit(allocator);
        results.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        var suggestion: KanbanTagSuggestion = .{
            .name = try allocator.dupe(u8, row.values[0]),
            .count = std.fmt.parseInt(u32, row.values[1], 10) catch 0,
            .last_used_at = if (row.values[2].len > 0)
                try allocator.dupe(u8, row.values[2])
            else
                null,
        };
        try results.append(allocator, suggestion);
    }

    // Apply the LIMIT N+1 trick: if we got back more than the
    // requested limit, truncate and set has_more = true.
    const has_more = results.items.len > clamped_limit;
    if (has_more) {
        // Drop the last (extra) row; we don't want to return it.
        const last = results.pop().?;
        last.deinit(allocator);
    }

    return KanbanTagSuggestionsPage{
        .tags = try results.toOwnedSlice(allocator),
        .has_more = has_more,
    };
}
```

**Step 2.** Note: `db.query` binds every arg as TEXT (per project memory `zig-sqlite-patterns.md`). The `fetch_limit` and `offset` u32 must be formatted to strings. The `catch ""` fallback is safe — SQLite coerces `""` to 0 in numeric contexts, returning zero rows. The handler clamps upstream anyway.

**Step 3.** Run the tests:

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 30
# expect: 10 new tests pass
```

**Step 4.** Commit: `git add ... && git commit -m "feat(kanban-tags): listKanbanDistinctTags paginates with offset + has_more"`.

### Task 1.3 — Wire the handler + route (TDD, red)

**File:** `src/ai_workflow/tui/http_handlers/kanban_tags_list.zig` (new) and `src/main.zig`

**Step 1.** Create the handler file with a stub. Mirror the structure of `tasks_list.zig:209`:

```zig
//! `GET /api/workspaces/:ws_id/items/:item_id/kanban/tags?limit=N&offset=K`.
//!
//! Returns one page of distinct tags from tasks belonging to the
//! given kanban workspace item, ordered by frequency DESC then
//! most-recent usage DESC. Powers the kanban task detail dialog's
//! tag autocomplete dropdown. Pagination is via `limit` + `offset`.
//!
//! Response: `{ tags: [{name, count, last_used_at}], has_more }`.
//!
//! Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const llm_history = ai_mod.llm_history;

const DEFAULT_LIMIT: u32 = 8;
const MAX_LIMIT: u32 = 50;

pub const KanbanTagsListError = error{
    OutOfMemory,
    DbError,
};

pub fn kanbanTagsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = ctx;
    _ = req;
    _ = res;
    return res.jsonResponse(.{
        .status_code = 501,
        .data = "{\"error\":\"not implemented\"}",
    });
}
```

**Step 2.** To make behavioural tests possible without booting the whole app, **extract a `useCase(allocator, db, input) ![]u8` function** at the top of the file (Task 1.4 will implement it). The handler is then a thin wrapper that parses query, calls useCase, returns the response — exactly the `tasks_list.zig:96` pattern.

**Step 3.** Add the route to `src/main.zig` (find the existing `/api/.../items/.../tasks` route via `git grep -n 'tasks' src/main.zig` — add the new route right after):

```zig
try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/kanban/tags", ai_mod.http_handlers.kanbanTagsListHandler);
```

**Step 4.** Commit the red scaffolding: `git add ... && git commit -m "test(kanban-tags): handler stub + route registration"`.

### Task 1.4 — Implement the handler's useCase (TDD, green)

**File:** `src/ai_workflow/tui/http_handlers/kanban_tags_list.zig`

**Step 1.** Replace the stub with the full handler. Mirror `tasks_list.zig`:

```zig
useCase input/output structs:

pub const KanbanTagsListInput = struct {
    workspace_item_id: []const u8,
    limit: u32,
    offset: u32,
};

pub const KanbanTagsListResult = []const u8; // pre-serialized JSON

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: KanbanTagsListInput,
) KanbanTagsListError!KanbanTagsListResult {
    const page = llm_history.listKanbanDistinctTags(
        allocator, db, input.workspace_item_id, input.limit, input.offset,
    ) catch return KanbanTagsListError.DbError;
    defer page.deinit(allocator);

    var response_suggestions: std.ArrayList(http_response.KanbanTagSuggestionResponse) = .empty;
    defer response_suggestions.deinit(allocator);

    for (page.tags) |s| {
        try response_suggestions.append(allocator, .{
            .name = s.name,
            .count = s.count,
            .last_used_at = s.last_used_at,
        });
    }

    return http_response.makeKanbanTagsListResponse(
        allocator,
        response_suggestions.items,
        page.has_more,
    );
}

pub fn kanbanTagsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }

    // Parse `limit` query param with clamping. Default 8, max 50.
    const limit_str = req.query.get("limit") orelse "8";
    const limit_parsed = std.fmt.parseInt(u32, limit_str, 10) catch DEFAULT_LIMIT;
    const limit: u32 = if (limit_parsed == 0)
        DEFAULT_LIMIT
    else if (limit_parsed > MAX_LIMIT)
        MAX_LIMIT
    else
        limit_parsed;

    // Parse `offset` query param. Default 0. No upper clamp (a
    // user-paginating past the end just gets an empty page).
    const offset_str = req.query.get("offset") orelse "0";
    const offset = std.fmt.parseInt(u32, offset_str, 10) catch 0;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const data = useCase(allocator, sqlite_db, .{
        .workspace_item_id = item_id,
        .limit = limit,
        .offset = offset,
    }) catch |err| {
        const status: u16 = switch (err) {
            KanbanTagsListError.DbError => 500,
            KanbanTagsListError.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            KanbanTagsListError.DbError => "Failed to fetch tag suggestions",
            KanbanTagsListError.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
```

**Step 2.** Add the response struct + make fn in `src/ai_workflow/tui/http_handlers/http_response.zig` (after the existing `WorkspaceItemTaskResponse` ~line 478):

```zig
/// One entry in the kanban tag suggestions dropdown. Returned by
/// `GET /api/workspaces/:ws/items/:item/kanban/tags` ordered by
/// frequency DESC, last_used_at DESC.
/// Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md
pub const KanbanTagSuggestionResponse = struct {
    name: []const u8,
    count: u32,
    last_used_at: ?[]const u8 = null,
};

pub const KanbanTagsListResponse = struct {
    tags: []const KanbanTagSuggestionResponse,
    /// True when more tags exist past this page. The frontend uses
    /// this to decide whether to render the scroll sentinel + load
    /// another page (or stop paginating).
    has_more: bool,
};

pub fn makeKanbanTagsListResponse(
    allocator: std.mem.Allocator,
    suggestions: []const KanbanTagSuggestionResponse,
    has_more: bool,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, KanbanTagsListResponse{
        .tags = suggestions,
        .has_more = has_more,
    }, .{});
}
```

**Step 3.** Create `src/ai_workflow/tui/http_handlers/kanban_tags_list_test.zig` with behavioural tests against the useCase:

```zig
//! Behavioural tests for `kanbanTagsListUseCase`.
//! Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const handler = @import("kanban_tags_list.zig");

fn setupDbWithTags() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT NOT NULL,
        \\  updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\  tags TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id) VALUES ('item_x', 'ws_x')", &.{});
    return .{ .db = db, .threaded = threaded };
}

test "useCase returns empty tags array + has_more=false for kanban with no tasks" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const result = try handler.useCase(testing.allocator, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 8,
        .offset = 0,
    });
    defer testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("tags").?.array.items.len == 0);
    try testing.expect(parsed.value.object.get("has_more").?.bool == false);
}

test "useCase paginates: limit=2 returns 2 tags + has_more=true when 5 distinct tags exist" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES ('t1', 'item_x', '[\"a\",\"b\",\"c\",\"d\",\"e\"]')", &.{});
    const result = try handler.useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 2,
        .offset = 0,
    });
    defer alloc.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.object.get("tags").?.array.items.len);
    try testing.expect(parsed.value.object.get("has_more").?.bool == true);
}

test "useCase returns has_more=false on the last page" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES ('t1', 'item_x', '[\"a\",\"b\",\"c\"]')", &.{});
    const result = try handler.useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x",
        .limit = 2,
        .offset = 2,  // skip past page 1 (a, b)
    });
    defer alloc.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("tags").?.array.items.len);
    try testing.expect(parsed.value.object.get("has_more").?.bool == false);
}

test "useCase combines with offset to skip past the first page" {
    var s = try setupDbWithTags();
    defer s.threaded.deinit();
    defer s.db.deinit();
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, tags) VALUES ('t1', 'item_x', '[\"a\",\"b\",\"c\",\"d\",\"e\"]')", &.{});
    const page1 = try handler.useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x", .limit = 2, .offset = 0,
    });
    defer alloc.free(page1);
    const page2 = try handler.useCase(alloc, &s.db, .{
        .workspace_item_id = "item_x", .limit = 2, .offset = 2,
    });
    defer alloc.free(page2);
    const p1 = try std.json.parseFromSlice(std.json.Value, alloc, page1, .{});
    defer p1.deinit();
    const p2 = try std.json.parseFromSlice(std.json.Value, alloc, page2, .{});
    defer p2.deinit();
    // p1[0].name must NOT equal p2[0].name (no overlap).
    const p1_name = p1.value.object.get("tags").?.array.items[0].object.get("name").?.string;
    const p2_name = p2.value.object.get("tags").?.array.items[0].object.get("name").?.string;
    try testing.expect(!std.mem.eql(u8, p1_name.?, p2_name.?));
}
```

**Step 4.** Register the test in `src/ai_workflow/tui/http_handlers/http_handlers_test_runner.zig` (find `_ = @import("tasks_list_test.zig");`).

**Step 5.** Run tests:

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 10
# expect: all kanban_tags_list_test + llm_history_kanban_tags_test pass
```

**Step 6.** Cross-compile:

```bash
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
```

**Step 7.** Commit: `git add ... && git commit -m "feat(kanban-tags): backend paginated endpoint with has_more"`.

### Task 1.5 — Live end-to-end smoke (Chunk 1)

**Step 1.** Build + start fresh server (port 8080, never 8081):

```bash
cd /home/ginwa/ginwaaitoolbox
rm -rf zig-out/bin
timeout 360 zig build install:linux:system
rm -rf /tmp/nalar-tags-smoke
env -i HOME=/tmp/nalar-tags-smoke PATH=$PATH \
  nohup ./zig-out/bin/nalar --port 8080 \
  > /tmp/nalar-tags-smoke.log 2>&1 < /dev/null &
disown 2>/dev/null
sleep 6
```

**Step 2.** Seed a kanban with 10 distinct tags (need > limit to see has_more):

```bash
WS=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces \
  -H 'content-type: application/json' -d '{"name":"tags-smoke"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

ITEM=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/kanban" \
  -H 'content-type: application/json' -d '{"name":"smoke-board","path":"/tmp"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["item"]["id"])')

# 10 distinct tags across 1 task
TAGS='["bug","urgent","frontend","backend","docs","feature","hotfix","refactor","test","ui"]'
curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/tasks" \
  -H 'content-type: application/json' \
  -d "{\"name\":\"task-1\",\"tags\":$TAGS}" > /dev/null
```

**Step 3.** Hit the endpoint with pagination:

```bash
# Page 1: limit=5, offset=0 → expect 5 tags + has_more=true
curl -sS "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/kanban/tags?limit=5&offset=0" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"len={len(d[\"tags\"])}, has_more={d[\"has_more\"]}")'
# expect: len=5, has_more=True

# Page 2: limit=5, offset=5 → expect 5 tags + has_more=false (last page)
curl -sS "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/kanban/tags?limit=5&offset=5" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"len={len(d[\"tags\"])}, has_more={d[\"has_more\"]}")'
# expect: len=5, has_more=False

# Past the end: limit=5, offset=10 → expect 0 tags + has_more=false
curl -sS "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/kanban/tags?limit=5&offset=10" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"len={len(d[\"tags\"])}, has_more={d[\"has_more\"]}")'
# expect: len=0, has_more=False

# limit clamped at MAX_LIMIT=50
curl -sS "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/kanban/tags?limit=99999" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"len={len(d[\"tags\"])}, has_more={d[\"has_more\"]}")'
# expect: len=10, has_more=False (all fit within cap)
```

**Step 4.** Cleanup: `pkill -f "nalar --port 8080"`.

---

## Chunk 2 — Frontend: composable + dropdown UI

**Outcome:** `KanbanTagsInput` shows a dropdown of suggestions when focused. The initial page is fetched lazily on first focus. Subsequent pages are fetched as the user scrolls (IntersectionObserver on a sentinel at the bottom of the dropdown). Click + keyboard nav + Escape all work. ~14 Vue tests pass.

### Task 2.1 — Add `getKanbanTagSuggestions` API wrapper (TDD, red)

**File:** `src/apps/desktop/src/api/index.ts`

**Step 1.** Add types + stub:

```ts
/** Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md */

export interface KanbanTagSuggestion {
  name: string
  count: number
  last_used_at: string | null
}

export interface KanbanTagSuggestionsResponse {
  tags: KanbanTagSuggestion[]
  has_more: boolean
}

export interface GetKanbanTagSuggestionsOptions {
  limit?: number
  offset?: number
}

export async function getKanbanTagSuggestions(
  workspaceId: string,
  itemId: string,
  options?: GetKanbanTagSuggestionsOptions,
): Promise<KanbanTagSuggestionsResponse> {
  // Stub — fails the test that asserts the URL shape.
  return { tags: [], has_more: false }
}
```

**Step 2.** Test file `src/apps/desktop/src/__tests__/apiKanbanTagSuggestions.spec.ts`:

```ts
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import * as api from '../api'

function mockFetchOnce(status: number, body: unknown) {
  fetchMock.mockResolvedValueOnce({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),
  } as Response)
}

describe('getKanbanTagSuggestions', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.resetAllMocks()
  })

  it('returns the tags + has_more from the response', async () => {
    mockFetchOnce(200, {
      tags: [{ name: 'bug', count: 3, last_used_at: '2026-12-31 23:59:59' }],
      has_more: true,
    })
    const result = await api.getKanbanTagSuggestions('ws_x', 'item_x')
    expect(result.tags).toHaveLength(1)
    expect(result.tags[0].name).toBe('bug')
    expect(result.has_more).toBe(true)
  })

  it('hits /api/.../kanban/tags with default limit=8 and offset=0', async () => {
    mockFetchOnce(200, { tags: [], has_more: false })
    await api.getKanbanTagSuggestions('ws_x', 'item_x')
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('/api/workspaces/ws_x/items/item_x/kanban/tags?limit=8&offset=0'),
      expect.any(Object),
    )
  })

  it('passes through limit and offset when provided', async () => {
    mockFetchOnce(200, { tags: [], has_more: false })
    await api.getKanbanTagSuggestions('ws_x', 'item_x', { limit: 20, offset: 8 })
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('limit=20&offset=8'),
      expect.any(Object),
    )
  })

  it('returns empty + has_more=false on non-2xx (graceful degradation)', async () => {
    mockFetchOnce(500, { error: 'internal' })
    const result = await api.getKanbanTagSuggestions('ws_x', 'item_x')
    expect(result.tags).toEqual([])
    expect(result.has_more).toBe(false)
  })
})
```

**Step 3.** Verify the stub fails: `timeout 60 bunx vitest run src/__tests__/apiKanbanTagSuggestions.spec.ts` — expect failures.

**Step 4.** Commit: `git add ... && git commit -m "test(api): failing tests for getKanbanTagSuggestions with pagination"`.

### Task 2.2 — Implement `getKanbanTagSuggestions` (TDD, green)

**File:** `src/apps/desktop/src/api/index.ts`

**Step 1.** Replace the stub:

```ts
export async function getKanbanTagSuggestions(
  workspaceId: string,
  itemId: string,
  options?: GetKanbanTagSuggestionsOptions,
): Promise<KanbanTagSuggestionsResponse> {
  const limit = options?.limit ?? 8
  const offset = options?.offset ?? 0
  const url = `/api/workspaces/${encodeURIComponent(workspaceId)}/items/${encodeURIComponent(itemId)}/kanban/tags?limit=${limit}&offset=${offset}`
  // Graceful degradation: a 5xx returns empty + has_more=false so a
  // broken server doesn't block the user from typing tags.
  try {
    const res = await apiFetch<KanbanTagSuggestionsResponse>(url, { method: 'GET' })
    return {
      tags: res.tags ?? [],
      has_more: res.has_more ?? false,
    }
  } catch {
    return { tags: [], has_more: false }
  }
}
```

**Step 2.** Verify: `timeout 60 bunx vitest run src/__tests__/apiKanbanTagSuggestions.spec.ts` — expect 4 tests pass.

**Step 3.** Type-check: `timeout 60 node node_modules/vue-tsc/bin/vue-tsc.js --build`.

**Step 4.** Commit: `git add ... && git commit -m "feat(api): getKanbanTagSuggestions with pagination + has_more"`.

### Task 2.3 — Create the `useKanbanTagSuggestions` composable (TDD, red)

**File:** `src/apps/desktop/src/composables/useKanbanTagSuggestions.ts` (new)

**Step 1.** Stub the composable:

```ts
/**
 * Lazy-load + paginated tag suggestions for a kanban.
 *
 * Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md
 *
 * Lifecycle:
 *   - `ensureLoaded()` — fetches the first page if not yet loaded.
 *   - `loadNextPage()` — fetches the next page (appends to internal list).
 *   - `reset()` — clears the internal list (used when the dialog closes).
 *
 * The fetched list is exposed as readonly `tags`. `hasMore` and
 * `loading` are exposed for UI to render a "Loading more..." indicator.
 *
 * The composable does NOT trigger fetches automatically — the caller
 * (KanbanTagsInput) is responsible for calling `ensureLoaded()` on
 * focus and `loadNextPage()` from an IntersectionObserver on the
 * scroll sentinel. This keeps the composable testable and the
 * "when to fetch" logic in the component.
 */
import { ref, type Ref } from 'vue'
import { getKanbanTagSuggestions, type KanbanTagSuggestion } from '../api'

export interface UseKanbanTagSuggestionsOptions {
  limit?: number
}

export function useKanbanTagSuggestions(
  workspaceId: string,
  itemId: string,
  options?: UseKanbanTagSuggestionsOptions,
) {
  const limit = options?.limit ?? 8
  const tags: Ref<KanbanTagSuggestion[]> = ref([])
  const hasMore = ref(false)
  const loading = ref(false)
  const loaded = ref(false)

  async function ensureLoaded(): Promise<void> {
    // Stub.
  }

  async function loadNextPage(): Promise<void> {
    // Stub.
  }

  function reset(): void {
    tags.value = []
    hasMore.value = false
    loading.value = false
    loaded.value = false
  }

  return { tags, hasMore, loading, loaded, ensureLoaded, loadNextPage, reset }
}
```

**Step 2.** Test file `src/apps/desktop/src/__tests__/useKanbanTagSuggestions.spec.ts`:

```ts
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { useKanbanTagSuggestions } from '../composables/useKanbanTagSuggestions'
import * as api from '../api'

describe('useKanbanTagSuggestions', () => {
  beforeEach(() => {
    vi.resetAllMocks()
  })

  it('ensureLoaded() fetches the first page via the API', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'bug', count: 3, last_used_at: null }],
      has_more: true,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledWith('ws_x', 'item_x', { limit: 8, offset: 0 })
    expect(c.tags.value).toHaveLength(1)
    expect(c.hasMore.value).toBe(true)
    expect(c.loaded.value).toBe(true)
  })

  it('loadNextPage() appends the next page when has_more was true', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions')
      .mockResolvedValueOnce({
        tags: [{ name: 'a', count: 1, last_used_at: null }],
        has_more: true,
      })
      .mockResolvedValueOnce({
        tags: [{ name: 'b', count: 1, last_used_at: null }],
        has_more: false,
      })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    await c.loadNextPage()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(2)
    expect(api.getKanbanTagSuggestions).toHaveBeenNthCalledWith(2, 'ws_x', 'item_x', { limit: 8, offset: 8 })
    expect(c.tags.value).toHaveLength(2)
    expect(c.tags.value[0].name).toBe('a')
    expect(c.tags.value[1].name).toBe('b')
    expect(c.hasMore.value).toBe(false)
  })

  it('loadNextPage() is a no-op when has_more is false (no extra fetch)', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: false,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    await c.loadNextPage()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(1)
  })

  it('loadNextPage() is a no-op while another loadNextPage is in flight (no double-fetch)', async () => {
    let resolveFirst!: (v: any) => void
    let resolveSecond!: (v: any) => void
    vi.spyOn(api, 'getKanbanTagSuggestions')
      .mockReturnValueOnce(new Promise((r) => { resolveFirst = r }) as any)
      .mockReturnValueOnce(new Promise((r) => { resolveSecond = r }) as any)
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    // First call sets has_more=true so loadNextPage is allowed.
    resolveFirst({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: true,
    })
    await c.ensureLoaded()
    // Fire two loadNextPage simultaneously; only one should hit the API.
    const p1 = c.loadNextPage()
    const p2 = c.loadNextPage()
    resolveSecond({
      tags: [{ name: 'b', count: 1, last_used_at: null }],
      has_more: false,
    })
    await Promise.all([p1, p2])
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(2)  // 1 from ensureLoaded + 1 from loadNextPage
  })

  it('ensureLoaded() does NOT re-fetch on subsequent calls when already loaded', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: false,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    await c.ensureLoaded()
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(1)
  })

  it('reset() clears the loaded list so ensureLoaded() can start fresh', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: false,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    expect(c.tags.value).toHaveLength(1)
    c.reset()
    expect(c.tags.value).toHaveLength(0)
    expect(c.loaded.value).toBe(false)
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(2)
  })

  it('loading flag is true while a fetch is in flight', async () => {
    let resolveFetch!: (v: any) => void
    vi.spyOn(api, 'getKanbanTagSuggestions').mockReturnValueOnce(
      new Promise((r) => { resolveFetch = r }) as any,
    )
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    const p = c.ensureLoaded()
    expect(c.loading.value).toBe(true)
    resolveFetch({ tags: [], has_more: false })
    await p
    expect(c.loading.value).toBe(false)
  })

  it('returns empty + has_more=false on API failure (graceful degradation)', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockRejectedValue(new Error('boom'))
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    expect(c.tags.value).toEqual([])
    expect(c.hasMore.value).toBe(false)
    expect(c.loading.value).toBe(false)
  })
})
```

**Step 3.** Verify the stub fails: `timeout 60 bunx vitest run src/__tests__/useKanbanTagSuggestions.spec.ts` — expect failures.

**Step 4.** Commit: `git add ... && git commit -m "test(composable): failing tests for useKanbanTagSuggestions"`.

### Task 2.4 — Implement the composable (TDD, green)

**File:** `src/apps/desktop/src/composables/useKanbanTagSuggestions.ts`

**Step 1.** Replace the stubs:

```ts
import { ref, type Ref } from 'vue'
import { getKanbanTagSuggestions, type KanbanTagSuggestion } from '../api'

export interface UseKanbanTagSuggestionsOptions {
  limit?: number
}

export function useKanbanTagSuggestions(
  workspaceId: string,
  itemId: string,
  options?: UseKanbanTagSuggestionsOptions,
) {
  const limit = options?.limit ?? 8
  const tags: Ref<KanbanTagSuggestion[]> = ref([])
  const hasMore = ref(false)
  const loading = ref(false)
  const loaded = ref(false)
  // Guard against double-fetches triggered by the IntersectionObserver
  // firing rapidly while a previous fetch is still in flight.
  let inFlight = false

  async function fetchPage(offset: number): Promise<void> {
    if (inFlight) return
    inFlight = true
    loading.value = true
    try {
      const page = await getKanbanTagSuggestions(workspaceId, itemId, {
        limit,
        offset,
      })
      tags.value = [...tags.value, ...page.tags]
      hasMore.value = page.has_more
      loaded.value = true
    } catch {
      // Graceful: a failed fetch leaves the list as-is; the user
      // can still type tags manually. has_more stays false so the
      // IntersectionObserver stops firing.
      hasMore.value = false
    } finally {
      loading.value = false
      inFlight = false
    }
  }

  async function ensureLoaded(): Promise<void> {
    if (loaded.value) return
    await fetchPage(0)
  }

  async function loadNextPage(): Promise<void> {
    if (!hasMore.value || inFlight) return
    await fetchPage(tags.value.length)
  }

  function reset(): void {
    tags.value = []
    hasMore.value = false
    loading.value = false
    loaded.value = false
  }

  return { tags, hasMore, loading, loaded, ensureLoaded, loadNextPage, reset }
}
```

**Step 2.** Verify: `timeout 60 bunx vitest run src/__tests__/useKanbanTagSuggestions.spec.ts` — expect 8 tests pass.

**Step 3.** Type-check: `timeout 60 node node_modules/vue-tsc/bin/vue-tsc.js --build`.

**Step 4.** Commit: `git add ... && git commit -m "feat(composable): useKanbanTagSuggestions lazy-load + pagination"`.

### Task 2.5 — Add suggestions dropdown to `KanbanTagsInput` (TDD, red)

**File:** `src/apps/desktop/src/components/kanban/KanbanTagsInput.vue`

**Step 1.** Add `suggestions`, `hasMore`, `loadingMore`, `onLoadMore` props + dropdown state:

```ts
const props = withDefaults(
  defineProps<{
    modelValue: string[]
    testId?: string
    /** Plan: ...autocomplete.md — list of pre-fetched tag names for
     *  the dropdown. Filtered by the input's typed prefix. */
    suggestions?: string[]
    /** True when more pages are available (drives the "Loading more…" indicator). */
    hasMore?: boolean
    /** True while a next-page fetch is in flight. */
    loadingMore?: boolean
    /** Fires when the scroll sentinel becomes visible. Parent should
     *  call its composable's loadNextPage(). */
    onLoadMore?: () => void
  }>(),
  {
    testId: 'kanban-tags-input',
    suggestions: () => [],
    hasMore: false,
    loadingMore: false,
    onLoadMore: undefined,
  },
)
```

**Step 2.** Add the dropdown state + filtered list:

```ts
const isFocused = ref(false)
const highlightedIndex = ref<number>(-1)

const filteredSuggestions = computed<string[]>(() => {
  if (!isFocused.value) return []
  const draft = draftInput.value.trim().toLowerCase()
  const filtered = props.suggestions.filter((s) => {
    if (!draft) return true
    return s.toLowerCase().startsWith(draft)
  })
  const modelLower = new Set(props.modelValue.map((t) => t.toLowerCase()))
  return filtered.filter((s) => !modelLower.has(s.toLowerCase()))
})

const showDropdown = computed<boolean>(
  () => isFocused.value && filteredSuggestions.value.length > 0,
)
```

**Step 3.** Add focus/blur/keydown handlers:

```ts
function onFocus() {
  isFocused.value = true
  highlightedIndex.value = -1
}

function onBlur() {
  // Delay closing so click events on dropdown items can fire first.
  setTimeout(() => {
    isFocused.value = false
    highlightedIndex.value = -1
  }, 150)
  commitDraft()
}

function commitSuggestion(suggestion: string) {
  emit('update:modelValue', [...props.modelValue, suggestion])
  draftInput.value = ''
  highlightedIndex.value = -1
  isFocused.value = false
}

function moveHighlight(direction: 1 | -1) {
  const max = filteredSuggestions.value.length - 1
  if (max < 0) return
  if (highlightedIndex.value === -1) {
    highlightedIndex.value = direction === 1 ? 0 : max
  } else {
    highlightedIndex.value = Math.max(0, Math.min(max, highlightedIndex.value + direction))
  }
}

function onKeydown(event: KeyboardEvent) {
  if (event.key === 'Enter' || event.key === ',') {
    event.preventDefault()
    if (highlightedIndex.value >= 0 && filteredSuggestions.value[highlightedIndex.value]) {
      commitSuggestion(filteredSuggestions.value[highlightedIndex.value])
    } else {
      commitDraft()
    }
  } else if (event.key === 'Backspace' && draftInput.value.length === 0 && props.modelValue.length > 0) {
    removeTag(props.modelValue.length - 1)
  } else if (event.key === 'ArrowDown') {
    event.preventDefault()
    moveHighlight(1)
  } else if (event.key === 'ArrowUp') {
    event.preventDefault()
    moveHighlight(-1)
  } else if (event.key === 'Escape') {
    if (showDropdown.value) {
      event.preventDefault()
      isFocused.value = false
      highlightedIndex.value = -1
    }
  }
}
```

**Step 4.** Add the dropdown template (with scroll sentinel at the bottom):

```vue
<div class="relative">
  <div
    class="flex flex-wrap items-center gap-1.5 px-2 py-1.5 rounded-lg"
    :class="hasError ? 'border border-red-500/60' : 'border border-[--color-border]'"
    style="background-color: var(--semantic-sidebar-bg);"
    :data-testid="`${props.testId}-container`"
  >
    <!-- existing chips -->
    <input
      v-model="draftInput"
      @keydown="onKeydown"
      @focus="onFocus"
      @blur="onBlur"
      @input="onInput"
      type="text"
      :placeholder="props.modelValue.length === 0 ? 'Add tags (letters, digits, hyphens)…' : ''"
      :data-testid="`${props.testId}-field`"
      class="flex-1 min-w-[120px] bg-transparent outline-none text-sm"
      style="color: var(--semantic-text);"
    />
  </div>
  <div
    v-if="showDropdown"
    class="absolute z-50 mt-1 w-full rounded-lg shadow-lg overflow-hidden"
    style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
    :data-testid="`${props.testId}-suggestions`"
  >
    <ul class="max-h-48 overflow-y-auto py-1">
      <li
        v-for="(suggestion, idx) in filteredSuggestions"
        :key="suggestion"
        class="px-3 py-1.5 cursor-pointer text-sm transition-colors duration-100"
        :class="idx === highlightedIndex ? 'bg-violet-500/20' : ''"
        :style="{ color: 'var(--semantic-text)' }"
        :data-testid="`${props.testId}-suggestion-${suggestion}`"
        @mousedown.prevent="commitSuggestion(suggestion)"
        @mouseenter="highlightedIndex = idx"
      >
        {{ suggestion }}
      </li>
      <!-- Scroll sentinel — invisible 1px div that fires
           IntersectionObserver when visible. Parent attaches the
           observer in onMounted. Hidden when no more pages exist. -->
      <li
        v-if="props.hasMore"
        ref="scrollSentinel"
        :data-testid="`${props.testId}-suggestions-sentinel`"
        class="h-px"
      />
    </ul>
    <!-- "Loading more…" indicator. Shown when the scroll sentinel
         is visible AND a fetch is in flight. -->
    <div
      v-if="props.loadingMore"
      class="px-3 py-1.5 text-xs text-center"
      style="color: var(--semantic-text-dim);"
      :data-testid="`${props.testId}-suggestions-loading`"
    >
      Loading more…
    </div>
  </div>
  <div v-if="hasError" class="mt-1 text-[11px]" style="color: rgb(248, 113, 113);" :data-testid="`${props.testId}-error`" role="alert">
    {{ errorMessage }}
  </div>
</div>
```

**Step 5.** Add the IntersectionObserver lifecycle:

```ts
import { onBeforeUnmount, onMounted, ref as vueRef, watch } from 'vue'

const scrollSentinel = vueRef<HTMLElement | null>(null)
let observer: IntersectionObserver | null = null

function attachObserver() {
  if (!scrollSentinel.value || observer) return
  // Lazy-load the next page when the sentinel scrolls into view.
  // `rootMargin: 0px 0px 100px 0px` triggers ~100px BEFORE the sentinel
  // reaches the bottom of the visible area, so the next page arrives
  // by the time the user hits the very bottom.
  observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          props.onLoadMore?.()
        }
      }
    },
    { rootMargin: '0px 0px 100px 0px' },
  )
  observer.observe(scrollSentinel.value)
}

function detachObserver() {
  if (observer) {
    observer.disconnect()
    observer = null
  }
}

// Re-attach when the sentinel ref changes (e.g. when the dropdown
// re-mounts after a filter change hides + shows it).
watch(scrollSentinel, () => {
  detachObserver()
  attachObserver()
})

onMounted(() => {
  attachObserver()
})

onBeforeUnmount(() => {
  detachObserver()
})
```

**Step 6.** Add tests in `src/apps/desktop/src/__tests__/KanbanTagsInput.autocomplete.spec.ts` (full file below):

```ts
import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import KanbanTagsInput from '../components/kanban/KanbanTagsInput.vue'

describe('KanbanTagsInput — autocomplete dropdown', () => {
  beforeEach(() => {})

  it('does not show the dropdown when there are no suggestions', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: [] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(false)
  })

  it('shows the dropdown when focused and suggestions are provided', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent', 'frontend'] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(true)
  })

  it('filters suggestions by case-insensitive prefix', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent', 'bugfix', 'frontend'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'BUG'
    await input.trigger('input')
    await input.trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bugfix"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(false)
  })

  it('hides suggestions that are already chips on the task', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: ['bug'], suggestions: ['bug', 'urgent', 'frontend'] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(true)
  })

  it('clicking a suggestion commits it as a tag and closes the dropdown', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent'] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    await wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').trigger('mousedown')
    await nextTick()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['bug']])
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(false)
  })

  it('ArrowDown + Enter commits the highlighted suggestion', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    await input.trigger('focus')
    await nextTick()
    await input.trigger('keydown', { key: 'ArrowDown' })
    await input.trigger('keydown', { key: 'Enter' })
    await nextTick()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['bug']])
  })

  it('Escape closes the dropdown but does NOT commit a draft', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'partial'
    await input.trigger('input')
    await input.trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(true)
    await input.trigger('keydown', { key: 'Escape' })
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(false)
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
  })

  it('hides the dropdown after blur (delayed close so clicks can fire)', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug'] },
    })
    const input = wrapper.find('[data-testid="kanban-tags-input-field"]')
    await input.trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(true)
    await input.trigger('blur')
    await new Promise((r) => setTimeout(r, 200))
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(false)
  })

  it('Enter without a highlight still commits the typed draft (existing behavior)', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'custom-tag'
    await input.trigger('input')
    await input.trigger('focus')
    await input.trigger('keydown', { key: 'Enter' })
    await nextTick()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['custom-tag']])
  })

  // ─── Pagination tests ──────────────────────────────────────────────────

  it('renders the scroll sentinel when hasMore is true', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: {
        modelValue: [],
        suggestions: ['bug'],
        hasMore: true,
        loadingMore: false,
      },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions-sentinel"]').exists()).toBe(true)
  })

  it('does NOT render the scroll sentinel when hasMore is false', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: {
        modelValue: [],
        suggestions: ['bug'],
        hasMore: false,
        loadingMore: false,
      },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions-sentinel"]').exists()).toBe(false)
  })

  it('renders the "Loading more…" indicator when loadingMore is true', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: {
        modelValue: [],
        suggestions: ['bug'],
        hasMore: true,
        loadingMore: true,
      },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions-loading"]').exists()).toBe(true)
  })

  it('IntersectionObserver fires onLoadMore when the scroll sentinel is visible', async () => {
    // jsdom doesn't trigger IntersectionObserver by default,
    // so we stub the constructor to call the callback with
    // isIntersecting=true synchronously.
    const originalIO = globalThis.IntersectionObserver
    let capturedCb: IntersectionObserverCallback | null = null
    let capturedOpts: IntersectionObserverInit | null = null
    ;(globalThis as any).IntersectionObserver = class MockIntersectionObserver {
      constructor(cb: IntersectionObserverCallback, opts?: IntersectionObserverInit) {
        capturedCb = cb
        capturedOpts = opts ?? null
      }
      observe() {}
      disconnect() {}
    }

    const onLoadMore = vi.fn()
    try {
      const wrapper = mount(KanbanTagsInput, {
        props: {
          modelValue: [],
          suggestions: ['bug', 'urgent'],
          hasMore: true,
          loadingMore: false,
          onLoadMore,
        },
      })
      await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
      await nextTick()
      // Fire the observer callback as if the sentinel is visible.
      capturedCb?.(
        [{ isIntersecting: true } as IntersectionObserverEntry],
        null as any,
      )
      expect(onLoadMore).toHaveBeenCalledTimes(1)
      // Verify the rootMargin config (100px preload).
      expect(capturedOpts?.rootMargin).toBe('0px 0px 100px 0px')
    } finally {
      ;(globalThis as any).IntersectionObserver = originalIO
    }
  })
})
```

The `IntersectionObserver` global mocking is the key bit — jsdom doesn't implement it, so we mock it. The mock captures the callback + opts so the test can simulate the sentinel becoming visible.

Import `vi` from vitest at the top of the file:
```ts
import { describe, it, expect, beforeEach, vi } from 'vitest'
```

**Step 7.** Run tests, watch them fail: `timeout 60 bunx vitest run src/__tests__/KanbanTagsInput.autocomplete.spec.ts` — expect failures on the dropdown / sentinel / loading indicator / IO trigger.

**Step 8.** Commit: `git add ... && git commit -m "test(kanban-tags): failing autocomplete dropdown + scroll pagination tests"`.

### Task 2.6 — Implement the dropdown in `KanbanTagsInput` (TDD, green)

**File:** `src/apps/desktop/src/components/kanban/KanbanTagsInput.vue`

**Step 1.** Wire everything together (the previous task was scaffolding + tests). Update the template:
- Add `onMounted` / `onBeforeUnmount` lifecycle hooks for the IntersectionObserver.
- Pass `props.onLoadMore` only when `hasMore` is true (defensive — the sentinel isn't rendered when `hasMore` is false).
- Make sure focus/blur/keydown handlers are wired.

**Step 2.** Run:
```bash
timeout 60 bunx vitest run src/__tests__/KanbanTagsInput.autocomplete.spec.ts
# expect: 14 tests pass
```

**Step 3.** Run the full Vitest suite to confirm no regressions:
```bash
timeout 180 bunx vitest run
# expect: previous pass count + 14 new tests
```

**Step 4.** Type-check:
```bash
timeout 60 node node_modules/vue-tsc/bin/vue-tsc.js --build
# expect: clean
```

**Step 5.** Commit: `git add ... && git commit -m "feat(kanban-tags): autocomplete dropdown with lazy-load + scroll pagination"`.

### Task 2.7 — Wire the composable into the dialog

**File:** `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue`

**Step 1.** Mount the composable and pass the loaded data to the input:

```ts
import { useKanbanTagSuggestions } from '../../composables/useKanbanTagSuggestions'

const tagSuggestions = useKanbanTagSuggestions(
  // props.workspaceId is a new optional prop the parent sets
  // (existing tests pass '' which gracefully degrades — no fetch).
  props.workspaceId ?? '',
  // props.task?.workspace_item_id for edit mode; '' for create mode
  // (the composable handles empty item_id gracefully).
  props.task?.workspace_item_id ?? '',
)
```

**Step 2.** Add the lazy-load trigger on focus:

```ts
// In the existing watcher that resets + fills the form on dialog show:
watch(
  () => [props.show, props.task?.id, props.mode] as const,
  async ([show, _taskId, _mode]) => {
    if (!show) return
    // ... existing form reset + fill code ...
    // At the end of the watcher, after the focus call:
    tagSuggestions.reset()
    if (props.task && props.workspaceId) {
      // Don't await — let the fetch happen in the background. The
      // dropdown only opens when the user focuses the input, which
      // is itself a separate trigger.
      void tagSuggestions.ensureLoaded()
    }
  },
  { immediate: true },
)
```

**Step 3.** Add a filtered computed (excludes already-on-this-task tags):

```ts
const filteredTagSuggestions = computed<string[]>(() => {
  const excludeLower = new Set(tags.value.map((t) => t.toLowerCase()))
  return tagSuggestions.tags.value
    .map((s) => s.name)
    .filter((n) => !excludeLower.has(n.toLowerCase()))
})
```

**Step 4.** Update the `<KanbanTagsInput>` binding:

```vue
<KanbanTagsInput
  ref="tagsInputRef"
  v-model="tags"
  :suggestions="filteredTagSuggestions"
  :has-more="tagSuggestions.hasMore.value"
  :loading-more="tagSuggestions.loading.value"
  :on-load-more="tagSuggestions.loadNextPage"
  :test-id="isCreateMode ? 'kanban-task-detail-create-tags' : 'kanban-task-detail-tags'"
/>
```

**Step 5.** Add a new prop `workspaceId?: string` to the dialog (defaulted to `''`). The parent (`KanbanView.vue`) already knows the workspace id and passes it down — add the prop binding in the parent too. Verify the parent's render of the dialog includes the new `:workspace-id` prop.

**Step 6.** Add tests `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.autocomplete.spec.ts`:

```ts
describe('KanbanTaskDetailDialog — tag autocomplete wiring', () => {
  it('mounts the composable with the dialog task item id', async () => {
    // mount the dialog with a fake task; verify the composable was
    // called with the right workspace + item ids (via mock factory)
  })

  it('filters out tags already on the current task from the suggestions', async () => {
    // task.tags = ["bug"]; composable returns ["bug","urgent","frontend"]
    // expect KanbanTagsInput receives :suggestions=["urgent","frontend"]
  })

  it('does not fetch in create mode (no task exists yet)', async () => {
    // mount with mode='create'; expect ensureLoaded NOT called
  })

  it('resets the composable on dialog close + reopen', async () => {
    // open + close + reopen; ensureLoaded called twice
  })

  it('forwards loadNextPage to the input via onLoadMore', async () => {
    // mount; verify the input's onLoadMore callback calls the composable's loadNextPage
  })
})
```

**Step 7.** Run tests, watch fail, then implement the wiring. Run again, expect pass.

**Step 8.** Commit: `git add ... && git commit -m "feat(kanban-task-detail): wire tag suggestions composable into the dialog"`.

### Task 2.8 — Final verification + smoke (full plan)

**Step 1.** Backend:
```bash
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 10
timeout 180 zig build install:linux:system
rm -rf zig-out/bin
timeout 360 zig build
```

**Step 2.** Cross-compile:
```bash
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
```

**Step 3.** Frontend:
```bash
cd src/apps/desktop
timeout 180 node node_modules/vue-tsc/bin/vue-tsc.js --build
timeout 180 bunx vitest run 2>&1 | tail -n 20
timeout 180 bun run build 2>&1 | tail -n 20
```

**Step 4.** Live end-to-end smoke (combines Chunks 1 + 2):

```bash
cd /home/ginwa/ginwaaitoolbox
rm -rf zig-out/bin
timeout 360 zig build install:linux:system
rm -rf /tmp/nalar-tags-final
env -i HOME=/tmp/nalar-tags-final PATH=$PATH \
  nohup ./zig-out/bin/nalar --port 8080 \
  > /tmp/nalar-tags-final.log 2>&1 < /dev/null &
disown 2>/dev/null
sleep 6

WS=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces \
  -H 'content-type: application/json' -d '{"name":"final-smoke"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
ITEM=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/kanban" \
  -H 'content-type: application/json' -d '{"name":"final-board","path":"/tmp"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["item"]["id"])')

# Seed 12 distinct tags
TAGS='["a","b","c","d","e","f","g","h","i","j","k","l"]'
curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/tasks" \
  -H 'content-type: application/json' \
  -d "{\"name\":\"t-1\",\"tags\":$TAGS}" > /dev/null

# Page 1 (limit=5, offset=0): expect 5 tags + has_more=true
curl -sS "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/kanban/tags?limit=5&offset=0" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"page1: len={len(d[\"tags\"])}, has_more={d[\"has_more\"]}, names={[t[\"name\"] for t in d[\"tags\"]]}")'

# Page 2 (limit=5, offset=5): expect 5 more distinct tags + has_more=true
curl -sS "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/kanban/tags?limit=5&offset=5" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"page2: len={len(d[\"tags\"])}, has_more={d[\"has_more\"]}, names={[t[\"name\"] for t in d[\"tags\"]]}")'

# Page 3 (limit=5, offset=10): expect 2 tags + has_more=false
curl -sS "http://127.0.0.1:8080/api/workspaces/$WS/items/$ITEM/kanban/tags?limit=5&offset=10" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"page3: len={len(d[\"tags\"])}, has_more={d[\"has_more\"]}")'

pkill -f "nalar --port 8080"
```

**Step 5.** Manual UX verification (open the desktop app):
1. Open a kanban with > 8 distinct tags on existing tasks.
2. Click a task → open the detail dialog.
3. Click into the Tags input → dropdown should appear with the first 8 tags.
4. Scroll to the bottom of the dropdown → "Loading more…" indicator appears, then 8 more tags load.
5. Continue scrolling until all tags are loaded → "Loading more…" disappears.
6. Type a few characters → filtered suggestions (no extra fetch).
7. Click a suggestion → chip appears, dropdown closes.
8. Reopen the dialog → process repeats (no stale state).

**Step 6.** Commit: `git add ... && git commit -m "test: end-to-end verification of lazy + paginated kanban tag autocomplete"`.

---

## Reference

- **Plan:** `docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md` (this file)
- **Prior feature:** `docs/superpowers/plans/2026-07-28-kanban-task-tags.md` (the v1 tags feature that this plan extends)
- **Component:** `src/apps/desktop/src/components/kanban/KanbanTagsInput.vue`
- **Dialog:** `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue`
- **Composable:** `src/apps/desktop/src/composables/useKanbanTagSuggestions.ts` (new)
- **Model:** `src/ai_workflow/tui/llm_history.zig::listKanbanDistinctTags` (new)
- **Handler:** `src/ai_workflow/tui/http_handlers/kanban_tags_list.zig` (new)
- **Route:** `GET /api/workspaces/:ws/items/:item/kanban/tags?limit=N&offset=K` (new)
- **Memories:**
  - `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md` (no grep tests)
  - `~/.config/nalar/memories/no-comments-on-logger-calls.md` (no decorative comments above log calls)
  - `~/.config/nalar/memories/migration-registration-trap.md` (register in allMigrations AND test the registration)
  - `.nalar/memories/nalar-backend-architecture.md` (HTTP handler thin-wrapper, per-request arena, parseFromSliceLeaky)
  - `.nalar/memories/nalar-frontend-patterns.md` (apiFetch mock needs text() + Pinia; vue-tsc IS the type-check)
  - `.nalar/memories/zig-sqlite-patterns.md` (db.exec/query bind TEXT only; empty slice → NULL)
  - `.nalar/memories/vue-3-virtual-scroller-reactive-scrollability.md` (IntersectionObserver on scroll sentinels — same pattern as the kanban virtual scroller)