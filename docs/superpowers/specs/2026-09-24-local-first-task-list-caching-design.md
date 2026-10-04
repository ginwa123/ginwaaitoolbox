# Local-first task-list caching design

**Date:** 2026-09-24

## Goal

Make every task-list fetch local-first: paint the last-known tasks from IndexedDB immediately, then revalidate the same request shape with the existing backend task-list endpoint and merge the returned rows by task id.

## Scope

The feature covers every current `getTasks()` path:

- workspace initialization for non-kanban items;
- kanban initialization, independently per column;
- kanban refreshes triggered by SSE task events;
- kanban search and sort refreshes;
- older-page loading, which remains network-backed and writes newly loaded rows through to the cache;
- task create, update, delete, move, pin, and review-state mutations, which update or evict cached rows where applicable.

The backend is unchanged. No new route, query parameter, response field, or server-side cache is introduced.

## Current architecture

The frontend already has the generic `BaseSyncEngine` and IndexedDB store used by chat and session lists:

- `ChatEngineDb` paints cached messages and revalidates the existing message endpoint.
- `SessionEngineDb` paints cached session rows per workspace and revalidates the existing session endpoint.
- `IndexedDbStore` uses the shared `pabrik-sync` database and an in-memory fallback when IndexedDB is unavailable.

Task fetching has four production paths in `workspaces.ts`:

1. non-kanban task fan-out in `loadWorkspaceItems`;
2. per-column kanban prefetch in `loadWorkspaceItems`;
3. `fetchKanbanTasks` for initial/refresh/search/sort fetches;
4. `loadMoreTasksForColumn` for older pages.

## Design

### 1. Task cache row and context

Add `TaskEngineDb` under `src/apps/desktop/src/sync/`, following `SessionEngineDb` and `ChatEngineDb`.

A cached row contains:

- `id`: task id;
- `sortKey`: the wire `updated_at` string, with an empty-string fallback;
- `raw`: the complete server task object, preserving fields needed by all task consumers.

The cache context isolates every request shape that can change the result set. A stable serialized context key includes:

- workspace id;
- workspace item id;
- column id, or a board-wide sentinel;
- normalized search query;
- normalized sort field;
- normalized direction.

`updated_at` is the local ordering key, not a backend delta cursor. It is used to keep cached task rows stable and to merge same-id server responses.

### 2. Cache-first/revalidate sequence

For every first-page task request:

1. read the newest cached rows for the exact request context;
2. paint them into the workspace item immediately;
3. request the same page from the existing `getTasks()` endpoint;
4. merge returned rows by task id, preferring the fresh server row;
5. persist the merged cache context;
6. leave painted rows in place if the request fails.

The existing `has_more` and `next_cursor` values remain per-column pagination metadata. The cache does not reinterpret `next_cursor` as a sync cursor.

For older-page loading:

1. send the existing `cursor` unchanged;
2. append deduplicated rows to the visible item;
3. write those rows into the same cache context;
4. update only the existing per-column pagination state.

### 3. Store integration

Add a store helper that builds a `TaskRequest` context and applies cached/fresh rows to a `WorkspaceItem`.

Use the helper in:

- non-kanban initialization;
- per-column kanban initialization;
- `fetchKanbanTasks` refreshes, search, and sort changes;
- SSE-triggered refreshes through `fetchKanbanTasks`.

`loadMoreTasksForColumn` remains network-only and writes through to the cache. It never overwrites the first-page cache with an older page.

Successful task mutations mirror the existing local state and also update/evict the relevant cache contexts. Deletes and moves remove stale copies. Human-touch events continue to patch the in-memory row without a list request; the cache row is patched/evicted consistently as well.

### 4. IndexedDB migration

Bump `pabrik-sync` to the next schema version and add a `tasks` object store. The upgrade callback creates every known store so whichever engine opens the database first leaves a complete schema. Existing message/session caches remain readable.

The task store uses the existing `by_ctx_sort` compound index and the `sync_state` namespace. IndexedDB failures remain advisory: the in-memory engine path continues to work.

## Data-flow examples

### Non-kanban workspace item

1. The item loads from the backend.
2. Cached rows for the workspace/item/board-wide context are painted immediately.
3. The existing task-list request revalidates the same page.
4. Fresh rows replace same-id cached rows; other cached rows remain available.
5. The merged result is persisted.

### Kanban column

1. The column list loads.
2. Each column has an independent cache context.
3. Cached rows for that column paint immediately.
4. The existing per-column request revalidates the same page.
5. Existing `columnPagination` state is updated with the response's older-page cursor.
6. Older pages are fetched only through `loadMoreTasksForColumn` and are persisted as additional cache rows.

## Error handling and invariants

- A cache miss never blocks the network request.
- A network failure never replaces a painted cache with an empty array.
- A fresh response never removes an unrelated task in another column.
- A fresh row replaces the cached row with the same id.
- Pagination cursor state remains independent from cache ordering.
- Search and sort contexts never receive rows from another context.
- Cached task payloads remain full wire-shaped objects.

## Testing strategy

### Frontend unit tests

- Task row mapping preserves the complete wire object and `updated_at` sort key.
- Context keys isolate workspace, item, column, query, and sort combinations.
- Cold cache requests the existing page and persists returned rows.
- Warm cache paints immediately and revalidates the same request shape.
- Same-id rows replace cached values.
- Failed revalidation keeps cached rows.
- Older-page responses append/write through without replacing the first-page cache.
- Non-kanban and per-column initialization use the cache-first helper.
- Existing API URL tests remain unchanged and green.
- Mutation paths keep cache and visible store coherent.

### Functional verification

Use the isolated Python functional harness for any HTTP/wire verification. It boots a fresh pabrik binary with an isolated temporary HOME and a free port other than 8081. Replay the existing frontend task-list URL and verify its response shape and cache-facing timestamps. Do not start a live server manually or use port 8081.

## Rollout and compatibility

The backend and API contract are unchanged. Existing callers continue to use `getTasks()`. The cache is advisory and can be cleared safely. If IndexedDB is unavailable, the in-memory fallback preserves current behavior.

## Non-goals

- Backend caching or a backend delta query.
- Replacing per-column pagination.
- Adding a new task-list route or response field.
- Caching single-task detail responses.
- Changing task search, pinned-task ordering, or backend timestamp semantics.
- Using localStorage for task payloads; the task cache follows the existing IndexedDB sync engine.
