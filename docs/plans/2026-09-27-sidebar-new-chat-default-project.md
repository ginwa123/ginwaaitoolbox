# Plan: **New Chat** in the sidebar (desktop) and the drawer (Android) — rooted at each workspace's default project

**Task:** `task_1790528102260_4` — *add new menu on top left sidebar, name New Chat, the new chat will be create a new session, the session is workspace items agent mode, but every workspace will be have project default, project default root will home users*
**Status:** ✅ **implemented** on `worktree/add-new-menu-on-top-left-sidebar-name-new-chat-1790528098609` — Q1/Q2 answered ("okey": build the plan's recommendations), both reversible
**Wireframe:** `docs/plans/2026-09-27-sidebar-new-chat-wireframe.html`
**Worktree:** `.worktree/worktrees_agent_new_chat_sidebar`
**Scope:** desktop (Vue) **+** Android (Kotlin) — one backend, two clients

---

## What implementation found that this plan did not

Two things the plan predicted as *risks* turned out to be real, and one was
only findable the way the plan said to verify.

### 1. A pre-existing use-after-free in the cwd chain (fixed in `d943d1dd`)

`resolveCwdFromTaskOrItem` (`session_create.zig`) returned `row.values[N]`
while a `defer row.deinit(alloc)` freed those very slices on return. The caller
received a dangling pointer, read whatever landed in the freed memory, found it
was not an absolute path, and fell through to `createSandbox`.

So **a session created against a project with a real `path` persisted a
per-session temp dir as its cwd** — no error, no log line, and a value that
looks completely plausible, because a sandbox path *is* a valid absolute path.
The runtime `ctx.cwd` was resolved on a separate path and was often right, so
the chat appeared to work while the stored row said something else.

This is the strongest possible argument for the plan's insistence on the
functional harness: a unit test of the handler cannot see a use-after-free in a
sibling helper, and the symptom passes every structural assertion. The cwd test
in §"The point of the whole thing" is what caught it.

### 2. `zig build test` does not reach every file

The test root never reached `workspace_items_get.zig`, so `zig build test` was
**green while the executable did not compile** — four errors in
`workspace_items_default.zig` (`SystemFolder` is
`pabrikcore.system_folder.SystemFolder`; `db.query`'s `argv` is
`[]const []const u8` so `.{}` cannot infer a length; `WorkspaceItemGetResponse`
has no `position`). Fixed in `d943d1dd`.

**Build the binary before declaring a backend change done.** `zig build test`
alone is not sufficient evidence that anything compiles.

### 3. The invariant legitimately changes exact item counts

Four existing functional tests asserted exact counts, and "a workspace with
nothing in it" is no longer a reachable state. Each was updated to account for
the default **by flag** rather than by a positional slice or a loosened bound —
`workspace_items_test.py` is the instructive one, where a `[:7]` slice had
started comparing the wrong seven ids the moment the reorder pushed the default
off the top, and would have kept passing while testing nothing.

---

## The invariant everything else serves

> **Every workspace has a default project. If we look for one and don't find it, we create it before doing anything else.**

That is the load-bearing rule of this design, and human review confirmed it. Four consequences shape every step below:

1. **"Default" is a property of the data, not a UI convention.** A new workspace, an API-created workspace, a workspace that predates this feature — all of them have a default project.
2. **No surface may have a "no default project" branch.** A client that renders "pick a project" has failed the invariant. The answer to "which project is the default" is never "none".
3. **The list endpoint is where the miss is caught** (D12). `GET /api/workspaces/:ws/items` — which both clients already call — ensures the default exists, so neither client has to *know* that defaults can be missing. The invariant is enforced once, server-side, on the read both clients already make.
4. **Creation must be idempotent**, because the lookup runs from several places at once (list, workspace create, New Chat tap, double-tap). A partial unique index — not a convention — is what makes that safe.

---

## Goal

One sentence: add a **New Chat** action to the top-left of the Vue sidebar **and** to the Android navigation drawer that — with one tap and no picking — creates a new chat session inside the active workspace's **default project**, where the default project is a `workspace_items` row of `item_type = 'agent'` whose `path` is the user's home directory.

---

## The three facts that make this small

### 1. A chat *is* a task. There is no session-create call to write — on either platform.

Migration 052 dropped `workspace_item_tasks.session_id`. The invariant is **`workspace_item_tasks.id == sessions.id`**, and both clients namespace it as a chat id (`StandardTaskChatView.vue:62-70`; `ProjectChat.id` per `ProjectsModels.kt:53-61`).

So "create a new session" is exactly:

- Vue: `workspacesStore.addTask(workspaceId, itemId, { name: 'New Chat' })`
- Android: `HomeViewModel.createTask(itemId, CreateTaskRequest.StandardChat("New Chat"))` → `POST /api/workspaces/{ws}/items/{item}/tasks`

The `sessions` row itself is created lazily on the first chat message by `POST /api/llm/session` (`src/http_handlers/session_create.zig:423`).

### 2. **Both** clients already own a complete, working "new chat in project X" flow.

| | Vue | Android |
|---|---|---|
| The helper | `Sidebar.vue:845-873 createAndOpenStandardChat(ws, itemId)` | `HomeViewModel.createTask(itemId, request)` — `HomeViewModel.kt:985` |
| Called from | the project rows' `+` button | `CreateTaskRow` inside an expanded project — `RecentsSidebar.kt:608` |
| Ends in | `router.replace(buildTaskAppUrl(...))` | `_createdChat.tryEmit(id)` → `PabrikNavGraph.kt:386-403` navigates |
| Double-tap guard | `isNavigatingToTask` | `creatingTaskInProjectId != null` — `HomeViewModel.kt:991` |

**Neither client reimplements a create flow.** Each new action resolves an `itemId` and calls the flow that is already there. On Vue that also means the repo's "every view switch must update the browser URL" rule is satisfied for free — the button is an *action*, and the URL change is its consequence.

### 3. `cwd` needs zero plumbing.

Neither client sends a `cwd`. The server falls through to `resolveCwdFromTaskOrItem` (`src/http_handlers/session_create.zig:467-499`):

```zig
//   1. workspace_item_tasks.cwd   → "" (never set by this flow)
//   2. workspace_items.path       → the default project's path == $HOME
//   3. createSandbox(...)         → per-session TMPDIR
```

So **"project default root is the user's home" is expressed by a single `path` value on one row.** No new request field, no new resolution step, no migration of the cwd chain. This is also why the Android chat route can keep taking a single `sessionId` argument (`PabrikRoutes.CHAT`) — the client never needs to know the cwd.

---

## Confirmed decisions

| # | Question | Answer |
|---|---|---|
| **D1** | Default project's `item_type`? | **`'agent'`** — the task's "agent mode". It is also the only type whose create action skips the type picker on **both** clients (`Sidebar.vue:892-903`; `createTaskStartDecision` at `CreateTaskFlow.kt:40-50` returns `Create` for `AGENT`, `NotAllowed` for `ROUTINE`, `Pick` otherwise). So the default project's New Chat is one synchronous call with no dialog. |
| **D2** | Default project's `name`? | **`"Project Default"`** — the task's words. Freely renameable; the `is_default` flag is what both clients follow, not the name. |
| **D3** | Its `path`? | **`$HOME`**, resolved **server-side** by `system_folder.getHomeDirectory` (`src/modules/system_folder/system_folder.zig:85-110`, the existing `HOME` → `USERPROFILE` → `HOMEDRIVE`+`HOMEPATH` chain). A client never resolves it — a browser does not know the server user's home, and the Android app has no endpoint that returns it. |
| **D4** | Desktop placement? | **A full-width row under the 48 px header, above Recents.** Most discoverable "top left" position and the ChatGPT/Claude convention. A button inside the header row would collide with the collapse chevron, which is absolutely positioned at `top-16` (`Sidebar.vue:1339`). |
| **D5** | Android placement? | **In the drawer's `Column`, between the workspace dropdown and the stale-data notice — deliberately *outside* the `LazyColumn`.** See "The `chatRegionEndIndex` trap" in Step 9b. |
| **D6** | One default per workspace — how enforced? | **`is_default` column + a partial UNIQUE index** (`WHERE is_default = 1`). "At most one" becomes a *database* invariant, so a concurrent double-tap cannot produce two. A bare column would only be a convention. |
| **D7** | New workspaces | **Create the default eagerly** inside `POST /api/workspaces`, so the Projects section shows it from the first paint. Failure is **non-fatal** — a workspace without a default is recoverable by the list ensure, whereas failing the whole create would leave the user with no workspace at all. |
| **D8** | Pre-existing workspaces | **No data migration.** The list-side ensure (D12) covers them on the next read, and a backfill would need `$HOME` resolved at migration time, which migrations deliberately avoid. |
| **D9** | A brand-new chat does not appear in Recents | **Accept it — parity with the existing `+`.** `task_create.zig` only INSERTs a `sessions` row when `is_auto_retry_until_stop` is present. The new chat shows under the project immediately and in Recents after the first message — exactly what both clients' existing `+` do today. Making it appear sooner would diverge the two entry points. |
| **D10** | Platforms | ✅ **Desktop and Android** (human). One backend, two clients. |
| **D11** | "Create it if not found" | ✅ **The invariant at the top of this document.** |
| **D12** | Where is the miss caught? | ✅ **The items *list* endpoint creates the default as a side effect** (human, Q4). `GET /api/workspaces/:ws/items` ensures it. Both clients already call that endpoint, so **neither client needs a "does the default exist?" branch at all** — the client code reduces to a pure find. |
| **D13** | Does the Android drawer close on New Chat? | ✅ **Yes** (human, Q3). The per-project `+` deliberately stays open; a *top-level* action that leaves the reader staring at a still-open drawer while the chat loads behind it is worse. |

### D12 — what was accepted, and what it obliges us to handle

A GET that writes is a real trade and it is worth being explicit about what it buys and what it costs, because both are permanent:

**Buys:** the invariant is enforced in exactly one place, on a read both clients already make. Zero client-side ensure logic, zero extra round trip, and a legacy workspace is healed the moment anyone opens it.

**Costs, each of which becomes an obligation:**
- A list read can now fail to produce the invariant, and must not turn that into a failed read. → the ensure inside the list is **best-effort and non-fatal**; the list still returns 200 with the items it found.
- `GET /api/workspaces/does-not-exist/items` must **not** create an orphan item. Today `useCaseList` does **not** 404 on a missing workspace — it just returns an empty array — so there is no existence check to lean on. → the ensure must be **explicitly gated** on a workspace-existence probe (Step 4). This is the single easiest way to get D12 wrong, and it is why the list handler gets its own step rather than a footnote.
- A prefetch, a monitor, or a crawler hitting the endpoint can now trigger a create. Inherent to the decision; nothing to do but know it.

### Open questions I am **not** deciding for you

- **Q1 — Should the default project be deletable?** A partial unique index prevents *two* defaults, not zero. If the user deletes the only default, the next list misses and re-creates one — which is the invariant working as designed, but it *looks* like a bug to a user who just deleted a project. Alternative: refuse the delete (`409`) with "this is the default project". **I lean toward refusing to delete**, but the invariant tolerates either and this is a product call.
- **Q2 — Should `+ Add Item` offer a "Default" option?** I propose **no** — the default is system-owned, not user-created. Confirm.

---

## Non-goals

- No new `sessions` endpoint, no change to the task/session identity model.
- No `cwd` field on the create-task request, and no change to the chat route's arity on either client.
- No change to either client's existing per-project `+` button, its picker, or the create flow it calls.
- No change to auto-rename-on-first-message; a new chat is titled `"New Chat"` until then, as today.
- No per-workspace *selection* of which project is the default (the default is the implicit one, always).
- No `is_default` on kanban/folder/design/routine items — only agent items may carry it. Enforced in the **service** layer, not by a schema CHECK (see Step 1).
- No data migration to backfill defaults. D12 covers legacy workspaces on read.
- No change to the "no `+` in ChatsList" decision from the 2026-09-22 revamp (`ChatsList.vue:916-921`).
- **No change to the list endpoint's status codes.** Today `GET .../items` returns 200 + `[]` for an unknown workspace; D12 keeps that. Adding a 404 would be a wire-contract change no caller asked for.

---

## Step 1 — Migration 094: `workspace_items.is_default`

**File:** `src/migrations/migration.zig` — append after `Migration093AddOwnerColumns` (`migration.zig:4963`), register in `allMigrations` at `migration.zig:2006`.

```zig
pub const Migration094AddDefaultProjectToWorkspaceItems = struct {
    pub const version: u32 = 94;
    pub const name = "add_default_project_to_workspace_items";

    pub fn up(db: *sqlite.SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // NOT NULL DEFAULT 0 is what SQLite allows when adding a column to an
        // existing table, and it backfills every pre-existing row to 0 with no
        // table rewrite.
        try db.exec(allocator,
            \\ALTER TABLE workspace_items ADD COLUMN is_default INTEGER NOT NULL DEFAULT 0
        , &[_][]const u8{});

        // At most one default per workspace, enforced by the database. The WHERE
        // clause is what makes this a *partial* index: ordinary rows
        // (is_default = 0) are never compared, so a workspace still holds
        // unlimited non-default projects.
        //
        // Scoped to workspace_id alone, NOT (workspace_id, user_id):
        // workspace_items has no user_id column. Items inherit their owner
        // through workspaces.user_id (Migration 093), and two owners can never
        // share one workspaces row — so there is no cross-owner default to
        // collide, and a per-workspace index is the correct grain.
        try db.exec(allocator,
            \\CREATE UNIQUE INDEX IF NOT EXISTS idx_workspace_items_default_per_workspace
            \\ON workspace_items(workspace_id) WHERE is_default = 1
        , &[_][]const u8{});

        // Lookup index: ensure() filters on both columns.
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_workspace_items_default_lookup
            \\ON workspace_items(workspace_id, is_default)
        , &[_][]const u8{});
    }
};
```

**Four inline Zig tests** (the file's standing convention — mirror the `Migration093` block at `migration.zig:5957-6046`):

1. The column exists and every pre-existing row reads `is_default = 0`.
2. Re-running `.up` is idempotent.
3. A second `is_default = 1` row in the same workspace is rejected by the partial unique index; a second default in a **different** workspace is accepted.
4. `Migration094` is present in `allMigrations`.

**Why no CHECK constraint on `item_type`.** `workspace_items.item_type` is a plain `TEXT NOT NULL` with no CHECK (`migration.zig:468`), and the generic create handler writes an arbitrary caller-supplied string (`workspace_items_create.zig:78-83`). Adding a CHECK now would reject unknown types that handler currently accepts. The "agent items only" rule lives in the service layer.

---

## Step 2 — `ensureDefaultProject` service

**New file:** `src/http_handlers/workspace_items_default.zig`

The single implementation of the invariant. Idempotent: returns the workspace's default project, **creating it if the lookup finds nothing**. Three callers — the list handler (D12), the POST endpoint (Step 3), and workspace create (Step 5).

```zig
pub const DefaultProject = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    path: []const u8,   // == $HOME
    position: i64,
    created: bool,      // true = this call created it
};

pub fn ensureDefaultProject(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    environment: *std.process.Environ.Map,
    config_tools: ?[]const []const u8,   // live config.json tools checklist
) EnsureDefaultProjectError!DefaultProject
```

Flow:

1. `SELECT id, name, path, position FROM workspace_items WHERE workspace_id = ? AND is_default = 1` → a row returns it with `created = false`. **Fast path — one indexed read, no writes.** This is the "found" branch.
2. Miss. Resolve `const home = try system_folder.getHomeDirectory(allocator, environment)`. An **empty or non-absolute** home is a hard error (`HomeNotFound`), *not* a silent `""` — see the `openDirAbsolute` abort note at `src/helpers/db_path.zig:36-43`. A default project with `path = ''` would fall through to `createSandbox` and the agent would run in a temp dir, which is worse than a visible error. This is the "not found → create" branch.
3. In one transaction (same tx-reentrancy rule as the agent create — the tx holds the backend mutex, so every statement must go through `tx`):
   - `INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, is_default, created_at, updated_at) VALUES (?, ?, 'agent', 'Project Default', ?, <fresh>, 1, datetime('now'), datetime('now'))`, fresh position = `COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1` so the default lands at the **top** of the list.
   - `INSERT INTO agents (id, workspace_item_id) VALUES (?, ?)` with the **same** id — the 1-1 invariant enforced by `agents.workspace_item_id UNIQUE` (Migration 078).
   - `tools_equipped.seedDefaultAgentTools(allocator, .{ .tx = &tx }, item_id, config_tools)` so the default is immediately usable as an agent.
4. **Race guard:** the partial unique index makes a concurrent second insert fail on a constraint. Catch it, `ROLLBACK`, re-run step 1, return the winner's row. This is what makes a double-tap safe — and with D12 it now matters on *every* list read, not just on a tap.
5. Commit, then re-read the inserted position (the `readInsertedPosition` pattern from `workspace_items_create_kanban.zig`).

**Six inline Zig tests:**

1. First call on an empty workspace creates it: `item_type == 'agent'`, `path == $HOME`, `is_default == 1`, an `agents` sibling row exists, `agent_tools` seeded.
2. **Second call returns the same id with `created = false` and creates no second row** — the invariant's idempotence, and the most important test in the file.
3. Two workspaces each get their own default.
4. A workspace whose default already exists returns it even alongside other agent items.
5. Missing/empty `HOME` returns `HomeNotFound` and **writes nothing** (the miss branch must not leave a half-made row).
6. The race fallback returns the winner's row instead of erroring.

---

## Step 3 — The explicit POST endpoint (cold-start fallback)

D12 means clients normally already have the default. This endpoint exists for the one case they don't: **the app was open when the migration ran**, so its loaded list predates the `is_default` column. Without it, New Chat would be a no-op until a manual refetch.

**Registration — `src/main.zig`, insert at line 688** (immediately before the `items` block, so the literal sits with the other workspace-level routes):

```zig
// Idempotent: returns the workspace's default project, creating it
// (item_type='agent', path=$HOME) when there is none. This is the cold-start
// fallback — GET .../items (Step 4) already ensures the default on the normal
// path, so most clients never call this. Distinct segment count from every
// /api/workspaces/:workspace_id/items* route, so it cannot be shadowed by a
// param sibling — see the static contract test in Step 8b.
try authed.post("/api/workspaces/:workspace_id/default-project", ai_mod.http_handlers.workspaceDefaultProjectHandler);
```

**Route-order analysis** (the AGENTS.md rule — `matchRoute` walks routes in registration order): the new route is **3 segments** (`/api/workspaces/:workspace_id/default-project`). Every existing 3+ segment route under `/api/workspaces` starts with `/api/workspaces/:workspace_id/items` (`main.zig:688-824`) — a **literal `items` in position 4**, where the new route has a literal `default-project`. No collision is possible, and no `POST /api/workspaces/:workspace_id/:param` route exists at all. Step 8b adds a test so a future sibling cannot silently shadow it.

**Handler — in `workspace_items_default.zig`:**

- **No body.** `POST` with an empty body, because this is a command ("give me the default"), not a resource creation. A body would tempt a `name`/`path` override, and D2/D3 fix both.
- Success: **200** `{ "project": { …item… }, "created": bool }` when it already existed, **201** when this call created it. Same wrapped-envelope shape as `CreateAgentResponseFull` (`workspace_items_create_agent.zig:75-79`).
- Errors: empty `workspace_id` → 400; unknown workspace → 404; `HomeNotFound` → 500 with a body that does **not** echo the path. Unlike the list-side ensure (Step 4), this endpoint **does** surface errors — an explicit call that cannot satisfy the invariant is worth a 500.
- **Owner scoping:** registered under `authed`, so the existing per-user middleware applies. The ensure `SELECT` filters by the **derived owner**, never a `user_id` from a body — the same discipline as Migration 093.

---

## Step 4 — The items list creates the default on a miss (D12)

**File:** `src/http_handlers/workspace_items_get.zig` — `workspaceItemsListHandler` / `useCaseList` (lines 20-51).

This is the step that makes D12 safe, so it carries the two obligations from the D12 section.

```zig
// D12: every workspace has a default project, and the list read is where both
// clients already look for it. So the list ensures it.
//
// Two rules make this safe:
//
//  1. GATED ON EXISTENCE. `useCaseList` does not 404 on an unknown workspace —
//     it returns []. Without an explicit probe, this ensure would create an
//     orphan workspace_items row for a workspace that does not exist. Probe
//     first, and skip the ensure when it misses.
//  2. NON-FATAL. A read that cannot write (read-only caller, a lost race we
//     could not recover, an unwritable home) must still return 200 with the
//     items it found. Failing the whole list because a *suggested* project
//     could not be created is a far worse outcome than one missing row, which
//     the very next read will try to heal again.
```

Order inside the handler:

1. `workspace_id` present? (already there, line 27) else 400 — unchanged.
2. **Existence probe**: `SELECT 1 FROM workspaces WHERE id = ?`. Missing → skip the ensure entirely and fall through to the existing 200 + `[]`. **Do not change the status code** — see Non-goals.
3. `ensureDefaultProject(...) catch |err| { std.log.warn(...); }` — **swallow every error.**
4. `useCaseList(...)` as today, returning 200.

Because the ensure runs before the list, the default row is visible in that same response — the client never has to make a second call to see it.

**Also required here:** `listWorkspaceItems` must select `is_default` and `makeWorkspaceItemListObjectResponse` must serialize it, so the field both clients' pure-find depends on is actually on the wire. (`llm_history.WorkspaceItemInfo` and `http_response.zig` — `workspace_items_get.zig:52-76` shows the single-item variant that must gain the field too.)

**Six inline Zig tests on the handler:**

1. A workspace with **no** items, listed once → 200, exactly one item, `is_default = 1`, `item_type = 'agent'`, `path == $HOME`.
2. Listing the same workspace **again** → still exactly one default, and `created` stayed `false` (no second row).
3. **An unknown workspace id → 200 with `[]` and zero `workspace_items` rows created.** This is the orphan guard; it is the single most important test in this step.
4. A workspace that already has ordinary projects keeps them **and** gains exactly one default, sorted to the top.
5. When `ensureDefaultProject` fails, the list still returns **200** with the projects it found.
6. The response includes `is_default` on every row (0 for ordinary, 1 for the default).

---

## Step 5 — Eager creation on workspace create

**File:** `src/http_handlers/workspaces_create.zig:118-141`. `createWorkspace` currently writes **only** the `workspaces` row. Add a non-fatal `ensureDefaultProject` call right after the INSERT, so the Projects section shows the default on first paint rather than after the first refetch.

Inline tests: (1) after `workspacesCreate`, the workspace has exactly one item — `item_type = 'agent'`, `path` = the test's `$HOME`, `is_default = 1`; (2) a failing ensure still returns **201** and leaves the workspace usable.

---

## Step 6 — Shared wire shape

Both clients parse the same response, so pin it down once:

```jsonc
// POST /api/workspaces/{ws}/default-project
// 201 when this call created it, 200 when it already existed
{
  "project": {
    "id": "item_1790…", "workspace_id": "ws_…", "item_type": "agent",
    "name": "Project Default", "path": "/home/ginwa", "position": 0,
    "is_default": 1
  },
  "created": true
}
```

`is_default` appears on **every** item in `GET /api/workspaces/{ws}/items` — that is the field both clients' pure find depends on, and per D12 the list is where it is guaranteed present.

---

## Step 7 — Desktop (Vue) client

### 7a. Store
**`src/apps/desktop/src/stores/workspaces.ts`**

1. `WorkspaceItem` — add `is_default?: number` (0/1), commented with Migration 094.
2. `api/index.ts` — `getOrCreateDefaultProject(workspaceId)` → `{ project: WorkspaceItem, created: boolean }` (the cold-start fallback).
3. New action `ensureDefaultProject(workspaceId): Promise<WorkspaceItem | undefined>` — **now mostly a pure find, thanks to D12**:
   - Find the item in `workspaces.value` with `is_default === 1` → return it. **This is the normal path** and it costs no network.
   - Else `await api.getOrCreateDefaultProject(workspaceId)`, `unshift` the item into the workspace's `items`, return it. This branch only runs when the loaded list predates the migration.
   - On failure, log and return `undefined` — following the `addTask` convention (`workspaces.ts:1502-1592`). The button then shows an error and **does not** navigate. It must not fabricate a local item with a fake id.

### 7b. The button
**`src/apps/desktop/src/components/shell/Sidebar.vue`** — a 40 px full-width row between the header `</div>` (line 1425) and `<nav>` (line 1428), i.e. *above* `ChatsList`.

```
┌────────────────────────────────┐
│ ⌄ My Workspace      Settings ⏻ │  ← existing header (48 px)
├────────────────────────────────┤
│  ✎  New Chat                    │  ← NEW row (40 px)
├────────────────────────────────┤
│  CHATS                    ⋮     │
```

Expanded: `✎ New Chat`, left-aligned, same weight as the `Settings` button (`text-xs font-medium`, `var(--semantic-text-dim)`) with a hover state. Deliberately **not** a violet filled pill — the 2026-09-22 revamp moved the whole sidebar to a bare-text treatment and a heavy button would fight it.

Collapsed (64 px): icon-only, `aria-label="New Chat"`, `title="New Chat"`, mirroring the existing `WorkspaceSwitcher collapsed` prop. **A 64 px rail must not drop the only always-visible chat affordance**; the word does not fit, so the icon carries the label. `data-testid="sidebar-new-chat-button"` in both states.

```ts
// Clicking New Chat creates a chat under the workspace's default project
// (an agent-mode item rooted at $HOME), then navigates to it. The default is
// in the store already on the normal path — the list read ensures it (D12) —
// so this is a pure find plus a local create.
const handleNewChat = async () => {
  const workspaceId = workspacesStore.activeWorkspaceId
  if (!workspaceId) return   // button disabled in this state
  if (isCreatingChat.value) return
  isCreatingChat.value = true
  try {
    const project = await workspacesStore.ensureDefaultProject(workspaceId)
    if (!project) return
    await createAndOpenStandardChat(workspaceId, project.id)
  } finally {
    isCreatingChat.value = false
  }
}
```

Guards: `isCreatingChat` disables the row and shows a spinner (two fast clicks would create two chats — the partial unique index protects the *project*, not the *chat*); `:disabled="!activeWorkspaceId || isCreatingChat"` with `title="Select a workspace first"`, because a chat cannot exist without a workspace and quietly creating one from a sidebar click would be a surprising side effect.

**The collapse-chevron collision — must not be skipped.** The chevron is `absolute -right-2.5 top-16 z-20` (`Sidebar.vue:1339`), pinned 64 px from the top. A 40 px row underneath pushes content to 88 px, so the chevron would sit **on top of** the New Chat row and swallow clicks. Change `top-16` → `top-24` (96 px) — 8 px clear, both states.

**URL contract:** satisfied by `createAndOpenStandardChat`'s `router.replace(buildTaskAppUrl(...))` → `/app/{ws}/projects/{defaultId}/chat/{taskId}`. Deep-linkable, refresh-safe, Back/Forward-correct. **No local `ref` holds "which chat is open".**

---

## Step 8 — Desktop tests

### 8a. Zig — inline (Steps 1, 2, 4, 5)
Per repo convention, same file as the impl. The lists are in each step.

### 8b. Zig — static route contract
New test reading `src/main.zig`: (1) the route is registered; (2) it appears **before** any `POST /api/workspaces/:workspace_id/:param` sibling — the `run_all_agents.zig:641-673` anti-shadowing precedent.

### 8c. Vitest — `src/apps/desktop/src/__tests__/Sidebar.newChat.spec.ts`
Modelled on `Sidebar.agentDirectChat.spec.ts`:
1. Click → `ensureDefaultProject(activeWorkspaceId)` then `addTask(ws, defaultId, { name: 'New Chat' })`.
2. `router.replace` target is exactly `/app/{ws}/projects/{defaultId}/chat/{task}`.
3. **D12 case:** the store already holds an `is_default === 1` item → **`api.getOrCreateDefaultProject` is not called at all**.
4. The cold case: the loaded list predates the migration → the endpoint is called once, its item is `unshift`ed, and the chat opens.
5. No active workspace → button disabled; click is a no-op; neither store action runs.
6. Double click → exactly one `addTask`.
7. `ensureDefaultProject` returns `undefined` → **no** navigation, no fabricated local item.
8. Collapsed state renders the icon with `aria-label="New Chat"`.

### 8d. Functional — `tests/functional/sidebar_new_chat_default_project_test.py`
**Use the harness. Do not curl a live server.** `tests/functional/harness.py` boots a fresh binary on a free port in 8080–8199 (**never 8081** — that server stays up) with `HOME` pointed at an isolated tmpdir, and reaps both on exit. That matters here specifically: the whole feature is defined by *where the home directory lands*, and a server started with the real `$HOME` cannot assert it.

1. `POST /api/workspaces` → the response items contain exactly one `is_default = 1`, `item_type = 'agent'`, `path == harness HOME`.
2. `POST .../default-project` twice → same `id`; `GET .../items` still shows exactly one default. **The invariant, asserted over the wire.**
3. **D12 end-to-end:** delete every item of a workspace (or hand-build a legacy workspace with none via SQL), then `GET .../items` → the response **contains** the default, `path == harness HOME`. This is the one test that fails loudly if Step 4 is wired wrong.
4. **The orphan guard, over the wire:** `GET /api/workspaces/ws_does_not_exist/items` → `200 []`, and a follow-up `GET /api/workspaces` shows no workspace was invented.
5. `POST .../items/:default_id/tasks {"name":"New Chat"}` → 201, `workspace_item_id` is the default project.
6. **The cwd assertion** — the point of D3: create the task, `POST /api/llm/session` with an empty `cwd_session`, assert the resulting `cwd` is the harness `HOME` and **not** a `/tmp` sandbox path. This is the assertion that catches a wrong `path`, and it is why this file exists instead of a unit test.

---

## Step 9 — Android client

**The Android app has no notion of a default project today.** It knows `ProjectSummary(id, workspaceId, itemType, name, path)` (`projects/ProjectsModels.kt:23-38`) and nothing else.

### 9a. Model + parser
`projects/ProjectsModels.kt` — add `val isDefault: Boolean = false` to `ProjectSummary`, defaulting to `false` so the many existing test fixtures keep compiling. Parse it in `ProjectsApi.parseItems` (`:94-120`), which already keeps unknown `item_type`s and maps JSON `null` to `""` — `is_default` maps to `isDefault = (it == 1)`.

Add `ProjectsApi.defaultProjectPath(workspaceId)` (mirroring `itemsPath` at `:55-61`) and `ProjectsClient.getOrCreateDefaultProject(workspaceId)` for the cold-start fallback. The app is **cookie-only auth** (`ProjectsClient.createTask` at `:64-101` sets the session cookie, no `Authorization` header) — the new call must do the same.

### 9b. The drawer row
**Placement — `recents/RecentsSidebar.kt`, `SidebarBody` (`:291`), immediately after the `WorkspaceDropdown` call (ends ~line 355) and before the stale-data notice block (~line 357).**

> **The `chatRegionEndIndex` trap.** The drawer's paging trigger is a pure function over list indices — `chatRegionEndIndex(visibleChatCount, recentsExpanded)` at `RecentsSidebar.kt:137-146`, with a hard-coded `RECENTS_HEADER_ROWS = 1` (`:117`) asserting how many rows sit above the chats *inside* the `LazyColumn`*. **Any row added inside the `LazyColumn` shifts every chat index and silently breaks that arithmetic** — a full-page fetch would arm a screen early, and it fails in a way no layout test sees. The `Column` above the `LazyColumn` is index-safe, and it is where the workspace dropdown — the only existing non-scrolling control — already lives.
>
> The row is placed **before** the conditional stale-data notice, not after, so its position does not shift when a refresh fails.

**Wiring** — `shell/RecentsDrawer.kt:28 RecentsDrawerContent` is the single wiring point (its KDoc says so explicitly: two call sites exist, the shell drawer and the chat route's hamburger, and a second copy of this wiring would be a second copy of every drawer bug). One new param there, forwarded to `RecentsSidebar` — never edit the two call sites.

**Visual** — copy `CreateTaskRow` (`projects/CreateTaskUi.kt:63`): a `Surface(onClick=…, enabled = !isBusy)` with `Icons.Filled.Add` and a `labelLarge` `PabrikAccent` label, plus a `testTag`. **Do not copy its parameter name** — it is called `projectName` but every caller passes the **id** (`RecentsSidebar.kt:609`), which is why the tag reads `create_task_row_item_abc`. Copy the shape, not the name. Prefer a pencil glyph over a `+` so it is visually distinct from the per-project `+` that means "add to *this* project".

**Disabled state** — reuse the existing global guard `creatingTaskInProjectId != null` (`HomeViewModel.kt:991`). It is global rather than per-project, and that is correct: one create at a time is the right semantic, and a second "New Chat" row from one intent is exactly what that guard exists for.

### 9c. The ViewModel action
`recents/HomeViewModel.kt` — a new `newChat()` beside `createTask` (`:985`):

```kotlin
// Resolve the workspace's default project and create a Standard Chat inside
// it. D12 means the project is already in `uiState.projects` on the normal
// path — the items read ensures it — so the happy path makes no extra request.
fun newChat() {
    val state = _uiState.value
    val workspaceId = state.selectedWorkspaceId ?: return
    if (state.creatingTaskInProjectId != null) return   // the existing guard
    viewModelScope.launch {
        val project = defaultProjectId(state.projects)
            ?: projectsClient.getOrCreateDefaultProject(workspaceId).getOrNull()?.project
        if (project == null) { /* surface taskCreateError, do not navigate */ return@launch }
        // Hand off to the existing flow — the double-tap guard, the
        // force-expand, the Room write-through and the _createdChat emit all
        // live in there.
        createTask(project.id, CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
    }
}
```

`defaultProjectId(projects)` is a **pure internal function** next to `selectWorkspaceId` (`HomeViewModel.kt:1188`), so it is unit-testable without Compose — the same reason that function exists.

**Navigation needs no new code** (D13 changes only *when* the drawer closes, not *how* the chat opens). `_createdChat.tryEmit(created.id)` (`:1072`) is already collected at `PabrikNavGraph.kt:386-403`, which selects, opens, and navigates with `popUpTo(SHELL)`. **Do not call `navigate` yourself.** The one addition D13 needs is a drawer-dismissal hook threaded through `RecentsDrawerContent` the way `onOpenAllChats` already is, wired to the modal sheet's `closeDrawer` (`MobileHomeScreen.kt:170-178`), which is only reachable from there. Firing it *before* navigating (so the drawer is gone while the chat screen mounts) is what makes the close feel instant rather than like a flicker.

### 9d. Android tests
JUnit 4 + Robolectric (`app/build.gradle.kts:93,100`); `androidTest/` compiles but **has never been run** — no CI emulator job — so JVM/Robolectric is the tier that actually gates.

1. `test/…/projects/DefaultProjectTest.kt` — **new.** Pure: `defaultProjectId` finds the `isDefault` item, returns null for none, ignores ordinary projects, tolerates a list of zero. Plus `ProjectsApi.parseItems` reading `is_default` 1/0/absent, and `defaultProjectPath` / the new client's cookie header.
2. `CreateTaskTest.kt` — add a case beside `CreateTaskStartDecisionTest` (`:246`): the resolved default project is `item_type == "agent"`, so `createTaskStartDecision` returns `Create` and **no picker is opened** — the whole point of D1.
3. **new** `HomeViewModel` cases: `newChat()` with the default already in `uiState.projects` issues **no** extra request and one `createTask`; with none present it calls the fallback endpoint first, then `createTask`; when that fails, it surfaces an error and **does not** navigate; two taps produce one POST.
4. `test/…/recents/RecentsSidebarSectionsTest.kt` (Robolectric, `:44`) — **new cases:** the row is displayed, its testTag is stable, it is disabled while a create is in flight, and **D13**: tapping it dismisses the drawer.
5. `test/…/recents/ChatRegionEndIndexTest.kt` — **unchanged, and that is the assertion.** It must keep passing untouched; a failure there means the row was put in the wrong place.
6. Test build: the default JDK is openjdk 27 and Gradle 8.10.2's Kotlin DSL fails on it — use Temurin 21 (`JAVA_HOME=/tmp/jdk/jdk-21.0.12.1+1 ./gradlew :app:testDebugUnitTest`).

---

## Step 10 — Rollout / risk

| Risk | Likelihood | Mitigation |
|---|---|---|
| **The list creates an orphan item for a nonexistent workspace** | **high if Step 4 is done casually** | The existence probe (Step 4.2) + the functional orphan test (8d.4). `useCaseList` does not 404 today, so there is nothing to lean on |
| The list 500s when it cannot write | medium | The ensure is swallowed (Step 4.3); a read must not fail because a *suggested* row could not be added. Asserted by Step 4's test 5 |
| The row goes inside the Android `LazyColumn` and breaks `chatRegionEndIndex` | high if unnoticed | Step 9b's placement rule; the existing `ChatRegionEndIndexTest` stays green |
| A user deletes the only default → it silently reappears | medium | **Q1.** The invariant tolerates it; whether it *reads* as a bug is a product call |
| Two rapid taps create two chats | low | Vue `isCreatingChat`; Android reuses `creatingTaskInProjectId`; both covered |
| A New Chat tap hits the fallback endpoint before the workspace is known | low | Button disabled with no active workspace on Vue; `selectedWorkspaceId ?: return` on Android |
| `getHomeDirectory` returns `""` on a POSIX host with `HOME=""` | low | Step 2 step 2 rejects empty/non-absolute **before any write** |
| A future `POST /api/workspaces/:ws/:param` route shadows the fallback | low | 8b static contract test |
| A prefetch/probe hitting the list triggers a create | accepted | Inherent to D12. Nothing to do but know it |
| `path = $HOME` surprises a user expecting the repo cwd | low | The name "Project Default" plus the path on the project row make it legible. The alternative — seed from the last-touched project — makes the default non-deterministic and would make functional test 8d.6 impossible to write. **Not proposed.** |

**Migration safety:** `ALTER TABLE … ADD COLUMN … NOT NULL DEFAULT 0` is an O(1) metadata change in SQLite — no table rewrite, no lock on existing rows. The partial index is built once over `workspace_items` (one row per project). Fully reversible by dropping the indexes; the column can be left in place harmlessly.

---

## Files to touch

**Backend**
| File | Change |
|---|---|
| `src/migrations/migration.zig` | `Migration094AddDefaultProjectToWorkspaceItems` + registration + 4 inline tests |
| `src/http_handlers/workspace_items_default.zig` | **new** — `ensureDefaultProject` + POST handler + 6 inline tests |
| `src/http_handlers/workspace_items_get.zig` | **the D12 ensure** — existence probe, non-fatal ensure, + 6 inline tests |
| `src/http_handlers/mod.zig` | export the handler (follow `mod.zig:173`) |
| `src/http_handlers/http_response.zig` | `is_default` on the item list + single-item responses; the default-project envelope |
| `src/agentic_loop/llm_history.zig` | `listWorkspaceItems` selects `is_default`; `WorkspaceItemInfo.is_default` |
| `src/models/workspace_item.zig` | `is_default` on the model + `init` (its header comment's migration list is already stale — fix it while here) |
| `src/main.zig` | one route registration at line 688 + static contract test |
| `src/http_handlers/workspaces_create.zig` | non-fatal ensure after the workspace INSERT |

**Desktop (Vue)**
| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | `getOrCreateDefaultProject` (cold-start fallback) |
| `src/apps/desktop/src/stores/workspaces.ts` | `WorkspaceItem.is_default` + `ensureDefaultProject` |
| `src/apps/desktop/src/components/shell/Sidebar.vue` | the new row, `handleNewChat`, chevron `top-16` → `top-24` |
| `src/apps/desktop/src/__tests__/Sidebar.newChat.spec.ts` | **new** — 8 cases |

**Android (Kotlin)**
| File | Change |
|---|---|
| `…/projects/ProjectsModels.kt` | `ProjectSummary.isDefault` |
| `…/projects/ProjectsApi.kt` | `parseItems` reads `is_default`; `defaultProjectPath` builder |
| `…/projects/ProjectsClient.kt` | `getOrCreateDefaultProject` (cookie auth) |
| `…/recents/HomeViewModel.kt` | `defaultProjectId` (pure) + `newChat()` |
| `…/recents/RecentsSidebar.kt` | the New Chat row in the `Column`, not the `LazyColumn` |
| `…/shell/RecentsDrawer.kt` | one new param, forwarded |
| `…/shell/PabrikNavGraph.kt` | wire the row (no new route) |
| `…/shell/MobileHomeScreen.kt` | **D13** drawer-dismissal hook, threaded like `onOpenAllChats` |
| `…/test/…/projects/DefaultProjectTest.kt` | **new** — pure + wire tests |
| `…/test/…/projects/CreateTaskTest.kt` | agent-default-skips-the-picker case |
| `…/test/…/recents/RecentsSidebarSectionsTest.kt` | **new** — row present / disabled / dismisses the drawer |

**Docs**
| File | Change |
|---|---|
| `docs/plans/2026-09-27-sidebar-new-chat-wireframe.html` | the wireframe — desktop panels **+** the Android drawer panel |
