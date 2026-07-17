# Frontend Error Logs Backend Table — Design

**Date:** 2026-07-17
**Status:** Approved (brainstorming session task_1784214681060)
**Branch:** `worktree/frontend-error-logs`
**Migration:** `Migration063AddFrontendLogs`

## Problem

Frontend (nalar-desktop webapp) exceptions currently only land in browser
DevTools. When the user reports "the chat broke" or "the page froze", we have
no persistent record to diagnose from — especially after a page reload or
route change, when the last (and usually most diagnostic) error is gone.

We want unhandled frontend exceptions to be captured into a backend SQLite
table so devs can query them via `curl` / `sqlite3` after the fact, without
needing browser DevTools.

## Goals (in scope)

1. Capture **uncaught JS exceptions** (`window.error`)
2. Capture **unhandled promise rejections** (`window.unhandledrejection`)
3. Capture **existing `console.error` and `console.warn` calls** in the
   codebase (zero migration needed — the existing call sites become free
   instrumentation)
4. Send captured events to a new backend POST endpoint, persisted in a
   `logs` table
5. Expose a read-only GET endpoint to dump rows as JSON for `curl` /
   scripts
6. Survive page unload (most common lost-error scenario): use
   `navigator.sendBeacon` on `pagehide`

## Non-goals (out of scope)

- A UI viewer in the desktop app — `curl` / `sqlite3` only (V2 decision)
- Capturing `console.log/info/debug` — too high volume, not diagnostic
- PII scrubbing of error messages — defer until we have a real PII incident
- Auto-purge / retention policy — match the rest of the codebase (no
  retention), revisit if the table balloons
- Per-session rate-limiting — the 250ms debounce + 50-entry queue cap is
  sufficient defense for the expected error rate

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ Frontend (nalar-desktop webapp)                              │
│                                                              │
│  window.error ─┐                                             │
│  unhandledrej. ├─→ frontendLogClient (module) ─→ POST /api/logs
│  console.error │                              ├── fetch() (normal)
│  console.warn ─┘                              └── sendBeacon() on pagehide
│                                                              │
│  (Original console.* / window behavior still happens —       │
│   DevTools output is preserved.)                             │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Backend (nalar)                                              │
│                                                              │
│  POST /api/logs ─→ handlers/frontend_log_post.zig            │
│                    ├─ Validate (level, kind, message)       │
│                    ├─ INSERT INTO logs (...)                 │
│                    └─ 204 No Content on success              │
│                                                              │
│  GET  /api/logs ─→ handlers/frontend_log_get.zig             │
│                    ├─ Query by level/limit/since             │
│                    └─ JSON: { logs: [...], count: N }       │
│                                                              │
│  Migration063 ─→ src/migrations/migration.zig                │
│                    ├─ CREATE TABLE logs (...)                │
│                    └─ CREATE INDEX idx_logs_created_at       │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
                     SQLite (agent.db)
```

---

## Backend: schema + endpoints

### Migration: `Migration063AddFrontendLogs`

Appends to `src/migrations/migration.zig` after `Migration062AddTaskDescription`.
The migration struct follows the existing project pattern (named struct with
`name: []const u8`, `version: u32`, `up: fn (...) anyerror!void`), and is
registered in `MigrationManager.all` at the bottom of the file.

```sql
CREATE TABLE IF NOT EXISTS logs (
  id TEXT PRIMARY KEY,             -- "log_<microseconds>", matches project convention
  created_at INTEGER NOT NULL,     -- microseconds (matches existing tables)
  level TEXT NOT NULL,             -- 'error' | 'warn' | 'info' | 'debug'
  kind TEXT NOT NULL,              -- 'window_error' | 'unhandled_rejection' | 'console_error' | 'console_warn'
  message TEXT NOT NULL,           -- primary human-readable message
  stack TEXT,                      -- nullable; set on window_error when available
  source TEXT,                     -- nullable; file URL for window.onerror
  line INTEGER,                    -- nullable; line number for window.onerror
  route_path TEXT,                 -- nullable; current Vue route
  session_id TEXT,                 -- nullable; current chat session_id if any
  count INTEGER NOT NULL DEFAULT 1 -- dedup counter (incremented if same key in 1s)
);
CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level);
```

**Design notes:**

- `id` = `"log_<microseconds>"` matches the project's id convention
  (`session_<ts>`, `worker_<ts>`, `routine_<ts>`, etc.). Microsecond
  timestamps are unique enough for this volume.
- `count` lets a tight loop of `console.error` collapse to a single row with
  `count=50` instead of 50 rows. Dedup key = `(kind, message, stack)` within
  a 1-second window. Implementation: in the POST handler, if a row with the
  same `kind + message + stack` and `created_at >= now - 1s` exists, run
  `UPDATE logs SET count = count + 1 WHERE id = ?` instead of `INSERT`.
- `route_path` and `session_id` are nullable — an error during page startup
  has no session yet.
- No `tags` JSON column — the `kind` discriminator handles the four cases
  we have today. Adding more kinds later → add a `log_tags` table (YAGNI).
- `idx_logs_created_at DESC` is the primary read path (most recent first).
- `idx_logs_level` supports `WHERE level = ?` filtering without a scan.

### Handler: `POST /api/logs`

New file: `src/ai_workflow/tui/http_handlers/frontend_log_post.zig`
Registered in the HTTP router (matches the thin-wrapper pattern documented in
project memory `nalar-http-handler-thin-wrapper-pattern`).

**Request body:**
```json
{
  "level": "error",
  "kind": "console_error",
  "message": "Failed to fetch initial workers: ...",
  "route_path": "/app?view=task",
  "session_id": "session_xyz"
}
```

For `kind=window_error`, also accepts optional `stack`, `source`, `line`.

**Responses:**
- `204 No Content` on success
- `400` + `{ "error": "..." }` on validation failure:
  - missing `level` / `kind` / `message`
  - invalid `level` value (must be `error`, `warn`, `info`, or `debug`)
  - invalid `kind` value (must be `window_error`, `unhandled_rejection`,
    `console_error`, or `console_warn`)

**Insertion logic:**

1. Parse JSON body via `parseFromSliceLeaky` (project convention)
2. Validate required fields
3. Compute `id` = `"log_<microseconds>"`
4. Dedup check: `SELECT id FROM logs WHERE kind = ? AND message = ? AND
   IFNULL(stack,'') = IFNULL(?,'') AND created_at >= ?` (now - 1s) — if a
   row matches, run `UPDATE logs SET count = count + 1 WHERE id = ?` and
   return 204
5. Otherwise `INSERT INTO logs (...) VALUES (...)`
6. Return 204

### Handler: `GET /api/logs`

New file: `src/ai_workflow/tui/http_handlers/frontend_log_get.zig`

**Query parameters (all optional):**

| Param | Type | Default | Notes |
|---|---|---|---|
| `level` | string | (no filter) | Filter by exact level |
| `kind` | string | (no filter) | Filter by exact kind |
| `session_id` | string | (no filter) | Filter by session_id |
| `since` | integer (microseconds) | (no filter) | `WHERE created_at >= since` |
| `limit` | integer | 100 | Capped at 1000 |

**Response:**
```json
{
  "logs": [
    {
      "id": "log_1784226123400123",
      "created_at": 1784226123400123,
      "level": "error",
      "kind": "console_error",
      "message": "Failed to fetch initial workers: ...",
      "route_path": "/app?view=task",
      "session_id": "session_xyz",
      "count": 1,
      "stack": null,
      "source": null,
      "line": null
    }
  ],
  "count": 1
}
```

Order: most recent first (`ORDER BY created_at DESC`).

### Backend error handling

- DB write fails (locked, full disk): POST returns 500, frontend logs to
  `console.warn` and drops the batch. Backend logs the failure to existing
  `std.log.err` (dev sees it server-side).
- Explicit guard against recursive loops: a logging failure does NOT itself
  try to log.

---

## Frontend: capture + transport

### New file: `src/apps/desktop/src/helpers/frontendLogClient.ts`

Single module that exposes `installFrontendLogClient({ endpoint, getContext })`.
Returns an unregister handle (for tests + HMR cleanup).

**Public surface:**

```ts
export interface FrontendLogContext {
  /** Returns the current Vue route path (e.g. "/app?view=task"), or null at startup. */
  getRoutePath: () => string | null
  /** Returns the active chat session_id, or null. */
  getSessionId: () => string | null
}
export interface FrontendLogClientOptions {
  endpoint: string           // "/api/logs"
  getContext: () => FrontendLogContext
  /** Override for tests; defaults to window. */
  target?: Window
}
export interface FrontendLogClientHandle {
  /** Detach all listeners + restore the original console.error/warn. */
  close(): void
}
export function installFrontendLogClient(opts: FrontendLogClientOptions): FrontendLogClientHandle
```

**Internals:**

- `level: 'error' | 'warn' | 'info' | 'debug'` is always set to `'error'` for
  `window.error` and `unhandledrejection`. For console, it tracks the patched
  method (`console.error` → `error`, `console.warn` → `warn`).
- `kind` is set based on which listener fired.
- `message` is `String(error.message || error)`. For
  `unhandledrejection`, `message = String(reason)`.
- The queue is a plain `Array<LogEvent>` with a `push` + `splice(0, N)` flush.
  Capped at 50 entries. On overflow: drop oldest 25, emit one `warn` event
  with `message = '[frontendLog] queue overflow, dropped N events'`, count
  starts at the new warn event.
- Debounce: 250ms timer. New events reset the timer. When the timer fires,
  flush the queue.
- Flush shape: POST a JSON body `{ events: [...] }` (one batch). On
  `pagehide` / `beforeunload`, the *last batched event* is sent via
  `navigator.sendBeacon('/api/logs', blob)` — a single beacon, not a batch
  (beacon body is limited to ~64KB; we keep one event to be safe).

**Capture paths:**

1. `window.error`: `kind = 'window_error'`. Includes `stack`, `source`,
   `line` from the `ErrorEvent` (all optional).
2. `window.unhandledrejection`: `kind = 'unhandled_rejection'`. Includes
   `stack` if the rejection reason is an `Error`.
3. `console.error` monkey-patch: `kind = 'console_error'`. The patch wraps
   the original method: `originalError.apply(console, args)` is called FIRST
   so DevTools output is preserved. The forwarded event reads
   `args[0]` for `message` and stringifies `args.join(' ')` if there are
   multiple args.
4. `console.warn` monkey-patch: same shape, `kind = 'console_warn'`.
5. `console.log / info / debug`: NOT patched (B2 decision).

**Wire-up in `main.ts`** (4 lines, runs BEFORE `app.mount('#app')`):

```ts
import { installFrontendLogClient } from './helpers/frontendLogClient'

const logCtx: FrontendLogContext = {
  getRoutePath: () => null,
  getSessionId: () => null,
}
installFrontendLogClient({ endpoint: `${API_BASE}/logs`, getContext: () => logCtx })
// logCtx is exposed on (window as any).__nalarLogCtx for App.vue to mutate.
;(window as unknown as { __nalarLogCtx: FrontendLogContext }).__nalarLogCtx = logCtx
```

**Context refresh in `App.vue`** (after `useRoute()` + `useNavigationStore()`):

```ts
import { useRoute } from 'vue-router'
import { useNavigationStore } from './stores/navigation'

const route = useRoute()
const navigationStore = useNavigationStore()
const logCtx = (window as unknown as { __nalarLogCtx: FrontendLogContext }).__nalarLogCtx
if (logCtx) {
  logCtx.getRoutePath = () => `${route.path}${route.fullPath}`
  logCtx.getSessionId = () => navigationStore.activeChatId ?? null
}
```

This way the route/session are correctly captured **after** App.vue mounts.
Before App.vue mounts, `getContext()` returns `null` for both — the
frontend still logs, just without context.

### Frontend error handling

- POST fails (network blip, server down): one `console.warn` per dropped
  batch; drop the batch, don't retry, don't block the page.
- `navigator.sendBeacon` is fire-and-forget — no callback, no failure path.
  We trust the browser to deliver it (or not) on unload.

---

## Testing strategy

### Backend tests

**`src/ai_workflow/tui/http_handlers/frontend_log_post_test.zig`** (7 tests,
static-contract + behavioral):

1. Happy path: valid payload → 204 + row exists in DB
2. Missing `level` → 400 + DB row count unchanged
3. Missing `kind` → 400 + DB row count unchanged
4. Missing `message` → 400 + DB row count unchanged
5. Invalid `level` value (e.g. `'critical'`) → 400
6. Invalid `kind` value → 400
7. `count` dedup: same `kind + message + stack` twice within 1s →
   `count = 2` in a single row

**`src/ai_workflow/tui/http_handlers/frontend_log_get_test.zig`** (4 tests):

1. Recent-first ordering: insert 3 rows at different timestamps, GET returns
   them DESC
2. `level=error` filter: 1 error + 1 warn inserted, GET returns only the
   error
3. `limit` cap: insert 5 rows, GET `limit=2` returns 2 rows
4. `since` filter: insert 2 rows, GET `since=<timestamp between>` returns 1

**`src/migrations/migration_063_test.zig`** (2 tests):
1. `Migration063AddFrontendLogs.up` runs on a fresh DB → table exists,
   columns match schema
2. Re-running on a DB that already has the table → no-op (CREATE TABLE IF
   NOT EXISTS)

### Frontend tests

**`src/apps/desktop/src/__tests__/frontendLogClient.spec.ts`** (~10 tests):

1. `window.error` with `ErrorEvent` → POST body has
   `kind: 'window_error'`, `stack`, `source`, `line` populated when
   present
2. `window.unhandledrejection` with `Error` reason → POST body has
   `kind: 'unhandled_rejection'`, `message: String(error.message)`
3. `console.error(...)` after monkey-patch → POST body has
   `kind: 'console_error'`; the original `console.error` was still called
   (spy assertion)
4. `console.warn(...)` → POST body has `kind: 'console_warn'`
5. `console.log / info / debug` → NOT POSTed (zero POSTs in spy)
6. 100 fast `console.error` calls within 1 frame → exactly 1 POST (250ms
   debounce coalesces them), the batched event has `count: 100`
7. `pagehide` event → uses `navigator.sendBeacon`, NOT `fetch` (mock both,
   assert `sendBeacon` called with `endpoint` URL and a `Blob` body)
8. Failed POST (mock `fetch` rejects) → `console.warn` is called once,
   batch is dropped, no retry
9. In-memory queue overflow: 60 events pushed → drops oldest 25, emits
   one overflow warn, total queue size = 35 events
10. `getContext()` callback is called for each event → route/session are
    read fresh on every flush

### E2E smoke test (manual recipe in commit message)

```bash
# 1. Start the server (port 8080)
./zig-out/bin/nalar --port 8080 &

# 2. POST a synthetic error
curl -X POST -H 'Content-Type: application/json' \
  -d '{"level":"error","kind":"console_error","message":"synthetic test","route_path":"/app"}' \
  http://127.0.0.1:8080/api/logs

# 3. GET recent errors
curl 'http://127.0.0.1:8080/api/logs?level=error&limit=10' | jq .

# 4. Open the desktop app and trigger an actual error (e.g. load a chat
#    with a stale session_id, watch the console.error path fire). Then
#    re-run step 3 to see the real entry.
```

---

## File-touching summary

**New files (5):**
- `src/migrations/migration.zig` — add `Migration063AddFrontendLogs` struct
  + register in `MigrationManager.all` (EDIT, not new file)
- `src/ai_workflow/tui/http_handlers/frontend_log_post.zig` — POST handler
- `src/ai_workflow/tui/http_handlers/frontend_log_get.zig` — GET handler
- `src/ai_workflow/tui/http_handlers/frontend_log_post_test.zig`
- `src/ai_workflow/tui/http_handlers/frontend_log_get_test.zig`
- `src/migrations/migration_063_test.zig`
- `src/apps/desktop/src/helpers/frontendLogClient.ts` — capture + transport
- `src/apps/desktop/src/__tests__/frontendLogClient.spec.ts`

**Edited files (3):**
- `src/ai_workflow/tui/http_handlers/mod.zig` — register the 2 new handlers
- `src/apps/desktop/src/main.ts` — install the log client + expose `logCtx`
- `src/apps/desktop/src/App.vue` — wire `route` + `activeChatId` to `logCtx`

**Estimated LoC:** ~600-800 lines (Zig backend ~400, TypeScript frontend
~250, tests included).

---

## Risks & open issues

1. **Recursive logging**: if the backend `INSERT INTO logs` itself fails
   and triggers another log, we could loop. Mitigated by the
   backend-side guard ("logging failures do not themselves log"). The
   frontend never sees backend errors that warrant re-logging.

2. **PII in error messages**: `console.error('Failed to save note:', note)`
   would put user content in the DB. Out of scope for v1; revisit if a real
   PII incident occurs.

3. **Storage growth**: unbounded table. Matches the rest of the codebase
   (no auto-purge anywhere). Revisit if `agent.db` balloons.

4. **Page reload loses the queued batch's non-final events**: the 250ms
   debounce means up to 250ms of events could be lost on a hard reload
   that doesn't fire `pagehide` synchronously. The browser spec guarantees
   `pagehide` fires before unload, so this is bounded — but worth noting.

---

## Reference

- Migration pattern: `Migration062AddTaskDescription` (most recent precedent)
- Thin-wrapper HTTP handler pattern: project memory
  `nalar-http-handler-thin-wrapper-pattern`
- Custom HTTP server arena allocator: project memory
  `custom-http-server-per-request-arena`
- Frontend SSE pattern (relevant to bus ownership): not directly used here
  but the `console.error` patches will include some SSE-related warns