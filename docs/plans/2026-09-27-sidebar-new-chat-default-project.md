# Plan: Top-left sidebar **New Chat**, rooted at each workspace's default project

**Task:** `task_1790528102260_4` — *add new menu on top left sidebar, name New Chat, the new chat will be create a new session, the session is workspace items agent mode, but every workspace will be have project default, project default root will home users*
**Status:** 📋 **proposed** — awaiting human review before implementation
**Wireframe:** `docs/plans/2026-09-27-sidebar-new-chat-wireframe.html`
**Worktree:** `.worktree/worktrees_agent_new_chat_sidebar`

---

## Goal

One sentence: add a **New Chat** button to the top-left of the Vue sidebar that — with one click and no picking — creates a new chat session inside the active workspace's **default project**, where the default project is a `workspace_items` row of `item_type = 'agent'` whose `path` is the user's home directory, and every workspace is guaranteed to have exactly one.

---

## The three things that make this small

Before reading the plan body, these are the three facts that collapse the work from "new subsystem" to "one button + one migration + one endpoint".

### 1. A chat *is* a task. There is no session-create call to write.

Migration 052 dropped `workspace_item_tasks.session_id`. The invariant is **`workspace_item_tasks.id == sessions.id`**, and the frontend namespaces it as `chat-<taskId>` (`StandardTaskChatView.vue:62-70`).

So "create a new session" is exactly `workspacesStore.addTask(workspaceId, itemId, { name: 'New Chat' })`. The `sessions` row is created lazily on the first chat message by `POST /api/llm/session` (`src/http_handlers/session_create.zig:423`).

### 2. The new-chat helper already exists and already navigates.

`Sidebar.vue:845-873 createAndOpenStandardChat(workspaceId, itemId)` is the canonical implementation, used today by the project rows' `+` button. It sets the `isNavigatingToTask` race guard, calls `addTask`, and ends in `router.replace(buildTaskAppUrl(...))` → `/app/{ws}/projects/{item}/chat/{task}`.

**The new menu does not reimplement this. It resolves a `itemId` and calls it.** That also means the repo's "every view switch must update the browser URL" rule is satisfied for free — the button is an *action*, and the URL change is a consequence of the action.

### 3. `cwd` needs zero plumbing.

`createAndOpenStandardChat` sends no `cwd`. The server falls through to `resolveCwdFromTaskOrItem` (`src/http_handlers/session_create.zig:467-499`):

```zig
//   1. workspace_item_tasks.cwd   → "" (never set by this flow)
//   2. workspace_items.path       → the default project's path == $HOME
//   3. createSandbox(...)         → per-session TMPDIR
```

So **"project default root is the user's home" is expressed by a single `path` value on one row.** No new request field, no new resolution step, no migration of the cwd chain.

---

## Confirmed decisions (need human sign-off before code)

| # | Question | Proposal | Why |
|---|---|---|---|
| **D1** | What is the default project's `item_type`? | **`'agent'`** | The task states *agent mode*. It is also the only type whose `+` already short-circuits the picker straight to a Standard Chat (`Sidebar.vue:892-903`) and whose main view is a config surface rather than a board. |
| **D2** | What is the default project's `name`? | **`"Project Default"`** | The task's words. Shown in the Projects list; the user may rename it freely. |
| **D3** | What is its `path`? | **`$HOME`**, resolved server-side by `system_folder.getHomeDirectory` | Already implemented with the `HOME` → `USERPROFILE` → `HOMEDRIVE`+`HOMEPATH` chain (`src/modules/system_folder/system_folder.zig:85-110`). The frontend must never resolve it — a browser does not know the server user's home. |
| **D4** | Where does the button live? | **A full-width row directly under the 48 px header, above `ChatsList`** | The most discoverable "top-left" position and the ChatGPT/Claude convention. The alternative (a button inside the header row next to `Settings`) collides with the collapse chevron, which is absolutely positioned at `top-16` (`Sidebar.vue:1339`). |
| **D5** | One default per workspace — how enforced? | **`is_default` column + a partial UNIQUE index** | A partial index (`WHERE is_default = 1`) makes "at most one" a *database* invariant, so a concurrent double-click cannot produce two defaults. A bare column would only be a convention. |
| **D6** | A brand-new chat does not appear in the Recents list | **Accept it — parity with the existing `+`** | `task_create.zig` only INSERTs a `sessions` row when `is_auto_retry_until_stop` is present. The new chat shows in the project's task list immediately and in Recents after the first message — identical to what the project `+` does today. Making it appear in Recents would mean diverging the two entry points. **If you want it in Recents immediately, say so — that is a one-line backend change plus a decision to make `+` behave the same way.** |
| **D7** | Which workspaces get a default? | **All of them, created eagerly on `POST /api/workspaces`**, and lazily ensured on first New Chat click | Eager creation means the default project is visible in the Projects list from the start. The lazy `ensure` covers workspaces that already exist (pre-migration rows, the shared `user_system` sentinel workspace, API-created workspaces). |

### Open questions I am **not** deciding for you

- **Q1 — Should the default project be deletable?** A partial unique index prevents *two* defaults, not zero. If the user deletes the only default, the next New Chat click silently re-creates one. Alternative: refuse to delete (`409`) with a "this is the default project" message. **I lean toward refusing to delete** — a default that reappears after deletion is surprising. Needs a decision.
- **Q2 — Should `+ Add Item` create a second default?** No. The Add-Item menu must not offer a "Default" option; the default is a system-owned row, not a user-created one. Confirm.
- **Q3 — Android parity?** The Android drawer (`src/apps/android_mobile`) has its own create-chat flow. This plan is **desktop only**. Confirm, or say so now and I will scope it in.

---

## Non-goals

- No new `sessions` endpoint, no change to the task/session identity model.
- No `cwd` field on the create-task request — the existing fallback chain already lands on `$HOME`.
- No change to the existing project-row `+` button, its picker, or `createAndOpenStandardChat` itself.
- No change to auto-rename-on-first-message; a new chat is titled `"New Chat"` until then, as today.
- No per-workspace *selection* of which project is the default (the default is the implicit one, always).
- No `is_default` on kanban/folder/design/routine items — only agent items may carry it. (Enforced by a CHECK constraint — see Step 1.)
- No Android/mobile work. See Q3.
- No change to the "no `+` in ChatsList" decision from the 2026-09-22 revamp (`ChatsList.vue:916-921`); this button lives in the sidebar shell, not the Recents list.

---

## Step 1 — Migration 094: `workspace_items.is_default`

**File:** `src/migrations/migration.zig` (append after `Migration093AddOwnerColumns`, `migration.zig:4963`; register in `allMigrations` at `migration.zig:2006`).

```zig
pub const Migration094AddDefaultProjectToWorkspaceItems = struct {
    pub const version: u32 = 94;
    pub const name = "add_default_project_to_workspace_items";

    pub fn up(db: *sqlite.SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // NOT NULL DEFAULT 0 is what SQLite allows when adding a column
        // to an existing table, and backfills every pre-existing row to 0
        // without a table rewrite.
        try db.exec(allocator,
            \\ALTER TABLE workspace_items ADD COLUMN is_default INTEGER NOT NULL DEFAULT 0
        , &[_][]const u8{});

        // At most one default per workspace, enforced by the database.
        // The WHERE clause is what makes this a *partial* index: ordinary
        // rows (is_default = 0) are never compared, so a workspace can
        // hold unlimited non-default projects.
        try db.exec(allocator,
            \\CREATE UNIQUE INDEX IF NOT EXISTS idx_workspace_items_default_per_workspace
            \\ON workspace_items(workspace_id) WHERE is_default = 1
        , &[_][]const u8{});

        // Lookup index: the ensure() SELECT filters on both columns.
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_workspace_items_default_lookup
            \\ON workspace_items(workspace_id, is_default)
        , &[_][]const u8{});
    }
};
```

**Also required** (the file's standing convention — see the `Migration093` block at `migration.zig:5957-6046`): four inline Zig tests

1. The column exists and every pre-existing row reads `is_default = 0`.
2. Re-running `.up` is idempotent (`ALTER TABLE` guard / `IF NOT EXISTS`).
3. A second `is_default = 1` row for the same workspace is rejected by the partial unique index; a second default in a *different* workspace is accepted.
4. `Migration094` is present in `allMigrations`.

**A CHECK constraint on `item_type` — and why I do not propose one.** `workspace_items.item_type` is a plain `TEXT NOT NULL` with **no** CHECK (`migration.zig:468`), and the generic create handler writes an arbitrary caller-supplied string (`workspace_items_create.zig:78-83`). Adding a CHECK now would reject unknown types the existing handler currently accepts. The type restriction is therefore enforced in the **service** layer (Step 2), not the schema.

---

## Step 2 — `ensureDefaultProject` service

**New file:** `src/http_handlers/workspace_items_default.zig`

Idempotent. Returns the workspace's default project, creating it if absent. Mirrors `workspace_items_create_agent.zig:129-160` for the insert triple (item row + agent sibling + tool seed) so a default project is byte-for-byte as usable as a hand-made agent.

```zig
pub const DefaultProject = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    path: []const u8,   // == $HOME
    position: i64,
    created: bool,      // true = this call created it (drives the 201 vs 200)
};

pub fn ensureDefaultProject(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    environment: *std.process.Environ.Map,
    config_tools: ?[]const []const u8,  // live config.json tools checklist
) EnsureDefaultProjectError!DefaultProject
```

Flow:

1. `SELECT id, name, path, position FROM workspace_items WHERE workspace_id = ? AND is_default = 1` → if a row, return it with `created = false`. **Fast path — one read, no writes.**
2. Else resolve `const home = try system_folder.getHomeDirectory(allocator, environment)`. An **empty or non-absolute** home is a hard error (`HomeNotFound` → HTTP 500), *not* a silent `""` — see the `openDirAbsolute` abort note in `src/helpers/db_path.zig:36-43`. A default project with `path = ''` would fall through to `createSandbox` and the agent would run in a temp dir, which is worse than an error.
3. In one transaction (same tx-reentrancy rule as the agent create — the tx holds the backend mutex, so every statement must go through `tx`):
   - `INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, is_default, created_at, updated_at) VALUES (?, ?, 'agent', 'Project Default', ?, <fresh position>, 1, datetime('now'), datetime('now'))`, where fresh position = `COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1` so the default lands at the **top** of the Projects list.
   - `INSERT INTO agents (id, workspace_item_id) VALUES (?, ?)` with the **same** id — the 1-1 invariant enforced by `agents.workspace_item_id UNIQUE` (Migration 078).
   - `tools_equipped.seedDefaultAgentTools(allocator, .{ .tx = &tx }, item_id, config_tools)` so the default project is immediately usable as an agent.
4. **Race guard:** the partial unique index makes a concurrent second insert fail with a constraint error. Catch it, `ROLLBACK`, re-run step 1, and return the winner's row. This is what makes double-clicking "New Chat" safe.
5. Commit, re-read the inserted position (the `readInsertedPosition` pattern from `workspace_items_create_kanban.zig`).

**Inline Zig tests** (same file, per repo convention):

1. First call on an empty workspace creates it; `item_type == 'agent'`, `path == $HOME`, `is_default == 1`, an `agents` sibling row exists, and `agent_tools` is seeded.
2. Second call returns the **same id** with `created = false` and creates no second row.
3. Two workspaces each get their own default.
4. A workspace whose default already exists returns that one even when other agent items exist.
5. Missing/empty `HOME` returns `HomeNotFound` and writes nothing.
6. The id generator cannot collide under concurrency (the partial unique index is the real guard; this proves the fallback path works).

---

## Step 3 — Route + handler

**Registration — `src/main.zig`, insert at line 688** (immediately before the `items` block, so the literal sits with the other workspace-level routes):

```zig
// Idempotent: returns the workspace's default project, creating it
// (item_type='agent', path=$HOME) on first call. Distinct segment
// count from every /api/workspaces/:workspace_id/items* route, so it
// cannot be shadowed by a param sibling — see the static contract
// test in Step 7.
try authed.post("/api/workspaces/:workspace_id/default-project", ai_mod.http_handlers.workspaceDefaultProjectHandler);
```

**Route-order analysis (the AGENTS.md rule):** `matchRoute` walks routes in registration order. The new route is **3 segments** (`/api/workspaces/:workspace_id/default-project`). Every existing 3+ segment route under `/api/workspaces` starts with `/api/workspaces/:workspace_id/items` (`main.zig:688-824`), i.e. a **literal `items` in position 4**, where the new route has a literal `default-project`. They cannot collide. There is no `POST /api/workspaces/:workspace_id/:param` route at all. Step 7 adds a test that asserts this statically so a future sibling cannot silently shadow it.

**Handler — in `workspace_items_default.zig`:**

- Body: none. `POST` with an empty body, because this is a command ("give me the default"), not a resource creation. A body would tempt a `name`/`path` override, and the whole point of D2/D3 is that they are fixed.
- Success: **200** with `{ "project": { …item… }, "created": bool }` when it already existed, **201** when this call created it. Mirrors the wrapped-envelope shape of `CreateAgentResponseFull` (`workspace_items_create_agent.zig:75-79`) so the frontend can destructure one way regardless of the type it is.
- Errors → existing status codes: empty `workspace_id` → 400; unknown workspace → 404; `HomeNotFound` → 500 with a body that does **not** echo the path.
- Owner scoping: the route is registered under `authed`, so the existing per-user middleware applies. The `ensure` SELECT must filter by the **derived owner**, not trust a `user_id` from the body — same discipline as Migration 093.

---

## Step 4 — Hook eager creation into workspace create

**File:** `src/http_handlers/workspaces_create.zig:118-141`

`createWorkspace` currently writes **only** the `workspaces` row. Add a second step right after the INSERT: call `ensureDefaultProject` for the freshly created id.

- Failure policy: **non-fatal.** A workspace that exists but whose default was not created yet is fully recoverable — the lazy ensure on the next New Chat click fixes it. Failing the whole `POST /api/workspaces` because a home dir could not be resolved would be strictly worse: the user would have no workspace at all.
- Log at `warn`, return 201 as today.

Inline test: after `workspacesCreate`, the workspace has exactly one `workspace_items` row, `item_type = 'agent'`, `path` = the test's `$HOME`, `is_default = 1`.

---

## Step 5 — Frontend: store action

**File:** `src/apps/desktop/src/stores/workspaces.ts`

1. `WorkspaceItem` interface — add `is_default?: number` (0/1) with a comment naming Migration 094. The backend returns it on every items read, so the field must be in the interface for TS.
2. `api/index.ts` — add `getOrCreateDefaultProject(workspaceId)` calling the new endpoint, returning `{ project: WorkspaceItem, created: boolean }`.
3. New store action `ensureDefaultProject(workspaceId: string): Promise<WorkspaceItem | undefined>`:
   - Find the item already in `workspaces.value` with `is_default === 1` (the workspace list is already loaded) and return it — **no network call** in the common case. This keeps the button instant.
   - Otherwise `await api.getOrCreateDefaultProject(workspaceId)`, `unshift` the item into the workspace's `items` (so the Projects list shows it without a refetch), and return it.
   - Reuses the `addTask` failure convention (`workspaces.ts:1502-1592`): on API failure, log and return `undefined` — the button then shows a toast and does **not** navigate. It must not fabricate a local item with a fake id.
4. `addWorkspace` (`workspaces.ts:1418-1441`) — nothing to change; the backend already created the default and the response's `items` array will carry it.

---

## Step 6 — Frontend: the sidebar button

**File:** `src/apps/desktop/src/components/shell/Sidebar.vue`

**Placement:** a new 40 px full-width row between the header `</div>` (line 1425) and `<nav>` (line 1428), i.e. *above* `ChatsList`.

```
┌────────────────────────────────┐
│ ⌄ My Workspace      Settings ⏻ │  ← existing header (48 px)
├────────────────────────────────┤
│  ✎  New Chat                    │  ← NEW row (40 px)
├────────────────────────────────┤
│  CHATS                    ⋮     │
│  …                             │
```

**Expanded state:** `✎ New Chat`, left-aligned, same typographic weight as the `Settings` button (`text-xs font-medium`, `var(--semantic-text-dim)`), with a hover state. This deliberately avoids a heavy filled button — the 2026-09-22 revamp moved the whole sidebar to a bare-text treatment and a violet pill here would fight it.

**Collapsed state (64 px):** the same row renders as a centred icon-only button, `aria-label="New Chat"`, `title="New Chat"`. **A 64 px sidebar must not drop the only always-visible chat affordance** — but the word "New Chat" cannot fit, so the icon carries the label in the tooltip. This mirrors the `WorkspaceSwitcher collapsed` prop pattern already in the header.

**Data-testid:** `sidebar-new-chat-button` (both states), following `sidebar-settings-button` / `sidebar-logout-button`.

**Handler — the whole thing:**

```ts
// Clicking New Chat creates a chat under the workspace's default
// project (an agent-mode item rooted at $HOME), then navigates to it.
// The default is ensured server-side on first use, so this is one call
// on the common path — the item is usually already in the store.
const handleNewChat = async () => {
  const workspaceId = workspacesStore.activeWorkspaceId
  if (!workspaceId) return   // button is disabled in this state (below)
  if (isCreatingChat.value) return  // double-click guard
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

**Guards:**

- `isCreatingChat` ref — disables the button and shows a spinner for the duration. Two fast clicks would create two chats; the partial unique index protects the *project*, not the *chat*.
- `:disabled="!workspacesStore.activeWorkspaceId || isCreatingChat"` — with **no active workspace** the button is disabled and carries `title="Select a workspace first"`. Creating a chat is impossible without a workspace, and silently creating one would be a surprising side effect of a sidebar click.

**Collapse-chevron collision — must not be skipped.** The chevron is `absolute -right-2.5 top-16 z-20` (`Sidebar.vue:1339`), i.e. pinned 64 px from the sidebar top. The new row ends at 48 + 40 = 88 px, so the chevron would sit **on top of the New Chat row**. Change `top-16` → `top-24` (96 px) — 8 px clear of the row, in both states.

**URL contract:** satisfied by `createAndOpenStandardChat`'s `router.replace(buildTaskAppUrl(...))` → `/app/{ws}/projects/{defaultId}/chat/{taskId}`. Deep-linkable, refresh-safe, Back/Forward-correct. **No local `ref` holds "which chat is open".**

---

## Step 7 — Tests

### 7a. Zig — inline (migration + service + handler), per repo convention
See Steps 1, 2, 4 for the specific test list. All in the same file as the impl.

### 7b. Zig — static route contract
New test asserting, by reading `src/main.zig`:
1. `POST /api/workspaces/:workspace_id/default-project` is registered.
2. It appears **before** any `POST /api/workspaces/:workspace_id/:param` sibling (a future one must not shadow it) — the `run_all_agents.zig:641-673` anti-shadowing precedent.

### 7c. Vitest — `src/apps/desktop/src/__tests__/Sidebar.newChat.spec.ts`
Modelled on `Sidebar.agentDirectChat.spec.ts`. Asserts:
1. Click → `ensureDefaultProject(activeWorkspaceId)` called, then `addTask(ws, defaultId, { name: 'New Chat' })`.
2. `router.replace` target is exactly `/app/{ws}/projects/{defaultId}/chat/{task}`.
3. The store already has an `is_default === 1` item → `api.getOrCreateDefaultProject` is **not** called.
4. No active workspace → button disabled; click is a no-op; neither store action runs.
5. Double click → exactly one `addTask` (the `isCreatingChat` guard).
6. `ensureDefaultProject` returns `undefined` (API failed) → **no** navigation, no fabricated local item.
7. Collapsed state renders the icon button with `aria-label="New Chat"`.

### 7d. Functional — `tests/functional/sidebar_new_chat_default_project_test.py`

**Use the harness. Do not curl a live server.** `tests/functional/harness.py` boots a fresh binary on a free port in 8080–8199 (**never 8081** — that server must stay up) with `HOME` pointed at an isolated tmpdir, and reaps both on exit. This matters here specifically because the whole feature is defined by *where the home directory lands* — a manual server started with the real `$HOME` cannot assert that.

Tests:
1. `POST /api/workspaces` → the response items contain exactly one `is_default = 1`, `item_type = 'agent'`, `path == harness HOME`.
2. `POST .../default-project` twice → same `id`, and `GET .../items` still shows exactly one default.
3. `POST .../items/:default_id/tasks {"name":"New Chat"}` → 201, and the row's `workspace_item_id` is the default project.
4. The **cwd** assertion — the whole point of D3: create the task, then `POST /api/llm/session` for it with an empty `cwd_session` and assert the resulting `cwd` is the harness `HOME`, **not** a `/tmp` sandbox path. This is the assertion that would have caught a wrong `path` and is the reason the plan uses the functional harness rather than a unit test.
5. Delete the default project → per Q1, either 409 (recommended) or a clean re-create on the next ensure. **Locked in by the Q1 decision.**

---

## Step 8 — Rollout / risk

| Risk | Likelihood | Mitigation |
|---|---|---|
| A user deletes the only default → it silently reappears | medium | **Q1** — refuse to delete with 409. Decide before merge. |
| Two rapid New Chat clicks create two chats | low | `isCreatingChat` ref (Step 6) + vitest case 5 |
| `path = $HOME` surprises a user who expected the repo cwd | low | The name **"Project Default"** plus the path shown in the project row make it legible. Alternative: seed the default with the *last-touched project path* — **not proposed**: it makes the default non-deterministic, which would make the functional test above impossible to write. |
| Pre-migration workspaces have no default until first click | certain (by design) | Lazy ensure covers it; Step 4 only helps new workspaces |
| A future `POST /api/workspaces/:ws/:param` route shadows this one | low | 7b static contract test |
| `getHomeDirectory` returns `""` on a POSIX host with `HOME=""` | low | Step 2 step 2 rejects empty/non-absolute **before** any write |

**Migration safety:** `ALTER TABLE ... ADD COLUMN ... NOT NULL DEFAULT 0` is an O(1) metadata change in SQLite — no table rewrite, no lock on existing rows. The partial index is built once over `workspace_items` (small — one row per project). The migration is additive and fully reversible by dropping the indexes; the column can be left in place harmlessly.

---

## Files to touch

| File | Change |
|---|---|
| `src/migrations/migration.zig` | `Migration094AddDefaultProjectToWorkspaceItems` + registration + 4 inline tests |
| `src/http_handlers/workspace_items_default.zig` | **new** — `ensureDefaultProject` + HTTP handler + inline tests |
| `src/http_handlers/mod.zig` | export the handler (follow `mod.zig:173` pattern) |
| `src/main.zig` | one route registration at line 688 + static contract test |
| `src/http_handlers/workspaces_create.zig` | non-fatal ensure after the workspace INSERT |
| `src/apps/desktop/src/api/index.ts` | `getOrCreateDefaultProject` |
| `src/apps/desktop/src/stores/workspaces.ts` | `WorkspaceItem.is_default` + `ensureDefaultProject` action |
| `src/apps/desktop/src/components/shell/Sidebar.vue` | the new row, `handleNewChat`, chevron `top-16` → `top-24` |
| `src/apps/desktop/src/__tests__/Sidebar.newChat.spec.ts` | **new** — 7 cases |
| `tests/functional/sidebar_new_chat_default_project_test.py` | **new** — 5 cases |
| `docs/plans/2026-09-27-sidebar-new-chat-wireframe.html` | the wireframe (this PR) |
