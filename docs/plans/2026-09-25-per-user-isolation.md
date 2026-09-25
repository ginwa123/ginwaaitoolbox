# Plan: per-user isolation — workspaces, sessions, settings (sub-project 3: enforcement)

## Goal

One sentence: make every user-owned DB row, every push channel, and every browser storage slot belong to exactly one authenticated user, so that user A can never see, mutate, or be distracted by user B's workspaces, sessions, chats, workers, terminals, or settings — while `--auth`-off behaviour stays byte-identical.

This is **sub-project 3 of 4** from `docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md` ("RBAC enforcement"). Sub-project 1 (schema, M077) and sub-project 2 (auth: `--auth`, `create-admin`, `auth_sessions`, `users.config_json`) have landed. Sub-project 4 (frontend) is partially in — `LoginView.vue` exists, but no client state is account-scoped.

## The short answer (what the user asked)

> "we have a table users — how to make user A not interfere another user B? workspace, session, settings etc?"

Fixing **one** layer is not enough. There are five independent layers, and today **all five** are broken:

| # | Layer | Today | Where |
|---|---|---|---|
| L1 | Identity reaches the handler | validated, then **discarded** | `src/http_handlers/auth_middleware.zig:60-61` |
| L2 | Rows are stamped with an owner on write | `user_id` column exists, **never written** | `src/http_handlers/workspaces_create.zig:119`, `src/http_handlers/session_create.zig:390` |
| L3 | Reads are filtered by owner | **global** `SELECT` | `src/http_handlers/workspaces_list.zig:84`, `src/agentic_loop/llm_history.zig:346` |
| L4 | Push channels are scoped | channels are **family-level**, not per-resource | `src/http_handlers/unified_events_sse.zig:10-16,357-359` |
| L5 | Browser storage is account-scoped | every key is origin/window-global; logout clears nothing | `src/apps/desktop/src/stores/workspaces.ts:225-230`, `src/apps/desktop/src/sync/IndexedDbStore.ts:10` |

Concrete A↔B interference that exists **right now** with `--auth` on (each is a test in the plan's §Test plan):

1. **B sees A's workspace list.** `workspaces_list.zig:84` has no `WHERE`; B's sidebar shows A's workspace names.
2. **B can open A's chat.** `GET /api/session/:id` / `/api/llm/session/:id/messages` are keyed by raw session id only (`src/agentic_loop/llm_history.zig:530,1672`); any id is readable by any authenticated user.
3. **B's browser receives A's live events.** `/api/events?channels=sessions` subscribes to a family routing key (`unified_events_sse.zig:357-359`), so A's session renames, worker progress, kanban moves, and LLM tokens are pushed to B's EventSource.
4. **A's UI state leaks into B's session on the same browser.** `nalar-active-workspace`, `active-chat-id`, `nalar-workspaces:v1`, and IndexedDB `nalar-sync` are never namespaced and never cleared on logout (`stores/workspaces.ts:1176-1207,1363-1369`; `helpers/authMe.ts:109-116`).
5. **Settings are the one thing already correct** — `users.config_json` is per-user via a server-side cookie lookup (`src/modules/config/UserConfigStore.zig:24-27`) — **except** for one live bug: the background `add_mcp_server` tool resolves the owner from `sessions.user_id` (`src/agentic_loop/tools_exec_add_mcp_server.zig:343-349`), which is never written, so it writes MCP servers to the sentinel `user_system` row for every user.

## Non-goals (v1)

- **No filesystem / OS sandbox — deferred, see D9.** `bash`, `terminal/ws`, `read_file`, `list_directory`, `/api/git/*`, `/api/files/download` all run as the OS user against caller-supplied paths. Per-user isolation of *pull-request-able* code paths is DB/browser isolation; host-level confinement (per-user chroot/uid) is a separate item, explicitly deferred by the user on 2026-09-25, and must be documented as a boundary rather than silently assumed safe.
- **No tenant/company layer.** `user_companies` / `user_company_members` (M077) stay unused; ownership is personal-first.
- **No RBAC role checks** beyond ownership. `users.role` stays decorative — `admin` has no extra powers over another user's rows (approved 2026-09-25, D8).
- **No sharing / team collaboration, no JWT/OAuth, no login UI work.**
- **No attempt to make the browser a security boundary.** L5 is UX hygiene (stop B inheriting A's view); the security boundary is server-side (L1–L4).

---

## Decision log

- **2026-09-25 (user, approved):** the open questions are answered — legacy data is shared, `admin` gets no cross-user visibility, new rows are private while legacy rows stay shared (writes included), filesystem scope deferred. Locked in "Decisions resolved by the user" below; implementation may proceed on these.
- **2026-09-25 (this plan):** enforcement is scoped to three ownership **roots** + transitive ownership, not a `user_id` column on all 40 tables. §Design D1.
- **2026-09-25 (this plan):** legacy pre-auth rows (owner `user_system`) stay visible to every authenticated user — a local-first upgrade must not make the existing user's data vanish. §Design D2. This matches the unmerged worker branch and deliberately overrides the M077 spec's stricter `WHERE user_id = current_user` reading.
- **2026-09-25 (this plan):** identity is re-resolved per request from the `nalar_session` cookie via a shared helper; **kabelweb is not modified**. §Design D3.
- 2026-08-21 (prior, `docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md:484`): "Personal-first (Option A). workspaces belong to users, not companies."
- 2026-08-21 (prior, same doc `:17`): sub-project 1 was schema-only; "no permission checks, no frontend changes."
- **2026-09-25 (user, approved):** the unmerged `worker.user_id` branch (`1aa1d97c`, which also declares `version = 92`) is **not** being merged. Its scope therefore folds into this plan: W0's migration claims **093** and adds `worker.user_id` itself, and W2.4 implements the worker queries here. No dependency, no renumbering of anyone else's branch — the branch is a **design reference only**. §Design D6, §W2.4.

### Decisions resolved by the user (2026-09-25) — implementation may proceed on these

1. **Legacy data policy: SHARED.** `user_system` / `NULL` / `''` rows stay visible to every authenticated user (D2 as written). Strict personal ownership is rejected.
2. **`admin` does NOT see other users' data.** No role-based bypass in v1; the owner predicate applies to every user including admins. §Design D8.
3. **New workspaces are stamped to their creator; legacy rows stay shared — including writes.** A logged-in user creating a workspace gets it privately; pre-auth rows remain visible *and mutable* by all authenticated users (exactly what the visibility clause does). If read-only legacy is wanted later, that is a small extra predicate — noted, not implemented.
4. **Filesystem scope: DEFERRED, not decided.** Recorded as an open boundary in §Design D9; this sub-project neither fixes nor claims it. Revisit as its own item.
5. **The unmerged `worker.user_id` branch is NOT merged.** Its scope folds into this plan instead of arriving as a dependency: W0's migration 093 adds `worker.user_id` (+ index + backfill), and W2.4 writes the worker queries here. The branch's code is a design reference only — nothing is rebased, nothing is inherited, nothing waits on it. **W0 can start immediately.**

Consequence of (1)+(3): the shared bucket only shrinks — rows created after this lands are always private. The migration doc-comment must say so, because a future reader will otherwise assume the sentinel is a permanent junk drawer.

---

## Design

### D1 — Ownership model: three roots, transitive ownership

Stamp the owner on the **roots** only:

| root | owner column | status |
|---|---|---|
| `workspaces` | `workspaces.user_id` | column exists (M077, `src/migrations/migration.zig:4228-4234`), never written |
| `sessions` | `sessions.user_id` | column exists (M077, `:4237-4243`), never written |
| `worker` | `worker.user_id` | column does **not** exist on main; created by this plan's migration 093 (D6) — not inherited from anywhere |

Everything else is reachable through a root and inherits its owner:

```
workspaces ─┬─ workspace_items ─┬─ workspace_item_tasks ─┬─ kanban
            │                   │                       └─ sessions (task chat) ─ llm_history, worker,
            │                   │                                                  session_plan, session_skills,
            │                   │                                                  session_queue_messages, session_* ...
            │                   ├─ design_pages ─ design_page_elements
            │                   └─ agents ─┬─ agent_knowledge
            │                              ├─ agent_tools
            │                              └─ agent_system_prompt
            └─ workspace_routines
sessions (plain chat) ── llm_history, worker, session_*, background_process
```

**Why not denormalize `user_id` onto all 40 tables:** ownership can only be changed through a root, so a per-table copy can rot (drift) and needs 40 backfills + 40 write-path edits. Authorization becomes "may this request see the root?" — one join, one helper. If a later feature needs per-child sharing, denormalize then.

**Consequence to accept:** every handler must resolve the root of the resource it touches. A handler that only knows a child id must join up to the root (`workspace_items JOIN workspaces`) — the join is indexed and cheap.

### D2 — Legacy visibility: the shared-sentinel clause

Generalise the unmerged worker branch's clause into one shared constant:

```
(x.user_id IS NULL OR x.user_id = '' OR x.user_id = 'user_system' OR x.user_id = ?)
```

- `NULL` / `''` → rows created by a build that predates this work, or rows the writer failed to stamp; treat as legacy, not as "owned by nobody".
- `'user_system'` → the M077 backfill target for every pre-auth row (`src/migrations/migration.zig:4285-4290`).
- `?` → the requesting user's id.
- Legacy rows are visible to **all** authenticated users (matching `1aa1d97c`'s `worker_visibility_clause`), so enabling `--auth` on an existing install shows the same data as before.

**Important asymmetry:** anything a user *creates* after this lands is stamped with their real id and is private. The shared bucket only ever shrinks. Document that in the plan and in the migration comment.

When `--auth` is **off**, the resolver returns `'user_system'`, so the clause is always true and behaviour is unchanged (this is what keeps the ~40 existing functional tests green).

### D3 — Identity propagation: resolve per request, don't touch kabelweb

Verified constraints (kabelweb pinned at `7e97a09ea9e01cec0fe1d46e54aedce76852f7b1`, `build.zig.zon:30-32`):

- `HttpContext` = `{ allocator, io, client_id, allowed_origins }` — **no user field** (`kabelweb src/server/http_parser.zig:7-18`).
- `HandlerFn` signature is `(ctx, req, res)` — no place to add a principal argument (`kabelweb src/server/router.zig:31-38`).
- `MiddlewareFn` returns an `HttpResponse` and passes `ctx`/`req` **by value**; the framework's own docs say to derive a new value via builder methods (`kabelweb src/server/router.zig:55-71`).
- `req.session` **is** a stable per-request pointer (`session: *Session = undefined`, `kabelweb src/server/http_parser.zig:145`; wired by the listen loop at `kabelweb src/server/http_server.zig:967-968`), so middleware *could* stash identity there — **but** `Session.set` requires a wired `ContextStore` and returns `error.NoContextStore` otherwise (`http_parser.zig:299-306`), and its documented semantics are a **cookie round-trip flash bag** ("Store a string value for the next request … the redirect helper serialises pending values into a cookie"). Putting an identity there would leak it into a client-visible cookie on any redirect. Rejected.

**Chosen mechanism** (design precedent: `1aa1d97c:src/http_handlers/auth_common.zig:98-122` — that branch is **not** merged (D6), so the helper is re-implemented here rather than inherited):

```zig
/// Resolve the owning user id for this request. Never reads the body.
/// - auth off                     -> "user_system"
/// - no / invalid / expired cookie -> "user_system"
/// - valid cookie                  -> the session's user id (owned copy)
pub fn resolveRequestUserId(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    auth_enabled: bool,
    headers: anytype,
) ![]const u8;
```

plus

```zig
pub const owner_visibility_clause =
    "(x.user_id IS NULL OR x.user_id = '' OR x.user_id = 'user_system' OR x.user_id = ?)";
```

Cost: one extra indexed lookup per request in auth mode (`auth_sessions.token_hash` is the PK, `src/migrations/migration.zig:4824`). 181 of 185 handlers need it — **do not** edit all 181 in one PR; migrate by route family (W2) and keep a ratchet test that lists the still-unscoped routes (W6).

**Rule to add to `AGENTS.md`** (there is no such rule today; the closest is `read_workspace_session.zig:11-21`, "a client-supplied id would be a spoofing vector"): the owner is **always** server-derived from the `nalar_session` cookie and never accepted from a request body, query, or header. A frontend-supplied `user_id` must be rejected or ignored, and a functional test must assert that a spoofed body `user_id` is ignored.

### D4 — Not-found discipline

A request for a resource the caller cannot see returns **404**, not 403 — so B cannot probe for the existence of A's workspace/session ids. Ownership failure is indistinguishable from "id does not exist". Add this to the wire-contract tests.

### D5 — `--auth` off = unchanged

Every scoping change is written as "resolver + clause"; with auth off the resolver yields `user_system`, the clause matches everything, and no filter is applied (skip the `WHERE` entirely rather than binding a sentinel, where convenient, so query plans and existing tests don't shift).

### D6 — Migration numbers: this plan owns 093 (no dependency)

- **92 is taken on main**: `Migration092AddUserConfigJson` (`version = 92`, name `add_user_config_json`, `src/migrations/migration.zig:4920-4934`, from `d73d9511`).
- The branch that *also* declared `version = 92` (`1aa1d97c`, name `add_user_id_to_worker`) is **not being merged** (user decision 2026-09-25). There is therefore no collision to arbitrate and nothing to wait for — but also nothing to inherit.

⇒ **This workstream claims version 093** and owns the entire `worker` owner column itself: `addColumnIfMissing(worker.user_id TEXT)` + `idx_worker_user_id` + the `NULL → 'user_system'` backfill (mirroring M077 `:4285-4290`), in the same migration as the `workspaces`/`sessions` backfill.

`MigrationManager` applies by `version >` (`migration.zig:1597`) with **no duplicate-version guard** — a clash is silently skipped, never an error. So before registering anything, prove the number is free across *all* branches, not just main:

```bash
git log --all -G 'version: u32 = 9[23]' -- src/migrations/migration.zig
```

This is the only failure mode in this plan that produces no error message, so it is a checklist item, not a note.

**Verified 2026-09-25 (this plan):** 93 is free. `rg -o "version: u32 = [0-9]+" src/migrations/migration.zig | sort -n | tail` tops out at **92** on main, and only two commits in the whole repo touch 92/93 — `d73d9511` (the landed `add_user_config_json`) and `1aa1d97c` (the branch that is not being merged). No commit declares 93.

### D7 — Where settings live (answer to "settings")

| artifact | scope | mechanism | verdict |
|---|---|---|---|
| LLM profiles / MCP servers / operational flags | **per user** | `users.config_json` via `UserConfigStore.zig:24-27,49-60`; handlers resolve the cookie themselves (`nalar_config_get.zig:19-33`, `nalar_config_put.zig:42-58`) | ✅ correct — make it the template |
| `config.json` on disk (`$XDG_CONFIG_HOME/nalar/config.json`, `Config.zig:2567-2570`) | global per OS account | used when auth is off; process config still initialised from it (`main.zig:180`) | auth-mode API path already bypasses it (`user_config_test.py::test_auth_put_leaves_config_file_untouched`); the background/CLI path still reads it — see W4 |
| browser `settings-*` localStorage (legacy store) | browser profile | `src/apps/desktop/src/stores/settings.ts:5-73` | legacy, no production call site; delete or namespace (W5) |
| `agent.db` | **one global file per OS account** (`src/helpers/db_path.zig:4-44`, opened at `main.zig:216-221`) | all users share one DB → ownership must be row-level | the reason D1/D2 exist; a per-user DB file is explicitly **not** the plan (it would break cross-user workspace sharing later and double the migration surface) |

### D8 — No `admin` bypass (approved 2026-09-25)

`users.role = 'admin'` grants **no** cross-user read or write. The owner predicate is applied identically for every authenticated user, admins included. Deliberate: the authorization rule stays a single predicate with no role branch — a role branch is the classic hiding place for a bypass bug — and it matches "personal-first" from the M077 spec. RBAC over other users' rows is a later sub-project with its own spec.

Test consequence, and a free win: `nalar create-admin` is the only way to make a user, and it creates `role = 'admin'`. So the two-user functional tests **are** admin-vs-admin tests — `test_workspaces_list_is_per_user` with both users created via `create-admin` already asserts "no admin bypass". Say so in the test docstrings rather than adding a separate case.

### D9 — Filesystem scope: deferred boundary (approved 2026-09-25, unresolved)

Not addressed by this sub-project. `bash`, `terminal/ws`, `read_file`, `list_directory`, `/api/git/*`, `/api/files/download` run as the OS user against caller-supplied paths, so a second user on the same machine can still read files by path. This is neither a regression introduced here nor something fixed here. It must be stated in `README.md` as a known boundary so "per-user isolation" is never read as "sandboxed". A future item decides between per-user OS uid/chroot, a workspace-root allowlist for the file tools, or accepting the boundary (single-operator machine, multiple browser users).

---

## Workstreams

Each workstream is independently shippable and has its own acceptance test. Order matters: W0 → W1 → W2 → W3 → W5, with W4 and W6 interleaved.

### W0 — identity primitive + migration hygiene

1. `src/http_handlers/auth_common.zig`: add `resolveRequestUserId` + `owner_visibility_clause` (+ a `freeRequestUserId` if ownership is transferred, mirroring `freeSessionLookup`). Add a `Principal { id: []const u8, shared: bool }` if call sites want the shared flag.
2. Add `src/http_handlers/auth_common_test.zig` cases (or inline `test` blocks per repo convention): auth off → `user_system`; missing cookie → `user_system`; invalid/expired cookie → `user_system`; valid cookie → the user's id; **owned copy** (freed by the caller, no aliasing into the lookup).
3. Register the new migration as **093** (D6) and own the `worker.user_id` column + index + backfill in it. Nothing is renumbered and nothing is inherited — that branch is not being merged. Run the D6 all-branches version check first.
4. Document the **decided** legacy-visibility policy (D2: shared — approved 2026-09-25) in the migration doc-comment so the next reader doesn't re-litigate it, including the point that the shared bucket only shrinks.

**Acceptance:** `zig build test` green; new unit tests cover the 5 resolver cases.

### W1 — stamp the owner on every write (roots)

| writer | change |
|---|---|
| `src/http_handlers/workspaces_create.zig:117-123` | `INSERT INTO workspaces (id, name, position, created_at, updated_at, user_id) …` with the resolved owner |
| `src/http_handlers/session_create.zig:390-392` | add `user_id` to the `INSERT OR IGNORE INTO sessions` column list |
| `src/agentic_loop/llm_history.zig:1411` | same, for the other session-creation path |
| `src/agentic_loop/update_worker.zig` | stamp `worker.user_id`, never downgrade a real owner to `user_system` |
| `src/root.zig` (`EmitRunAgentInput`) | thread `user_id` into worker creation — the background worker has **no** HTTP request, so the owner must ride along from the enqueuing request (§W3) |
| `src/agentic_loop/tools_exec_add_mcp_server.zig:343-349` | **fix the live bug**: once `sessions.user_id` is actually written, this resolves correctly; add a regression test (2 users → 2 config rows) |
| `src/migrations/migration.zig` | new migration **`Migration093AddOwnerColumns`** (`version = 93`, D6): `addColumnIfMissing` `worker.user_id TEXT` + `idx_worker_user_id`, then backfill `workspaces.user_id` / `sessions.user_id` / `worker.user_id` where NULL → `'user_system'` (idempotent, mirrors M077 `:4285-4290`). No FKs (project convention: `PRAGMA foreign_keys` is deliberately off — `migration_072_test.zig:156-164`). |
| `src/models/worker.zig` | carry the `user_id` field; default `user_system` so pre-auth/legacy callers keep compiling and behaving identically |

**Acceptance (python functional, two cookies):** create workspace as A → `SELECT user_id` is A's id (assert via a subsequent scoped read); create session as A → same; B's `add_mcp_server` run writes B's row, not `user_system`.

### W2 — scope the reads (by route family)

Do these in separate commits so review is tractable. Every change is the same shape: resolve owner → add `AND <owner_visibility_clause>` (or a `JOIN … WHERE`) → 404 when the resource is not visible.

1. **workspaces** — `workspaces_list.zig:84,131,161,219` (list + the 3 count/batch queries), `workspace_get.zig:69`, `workspace_update.zig`, `workspace_delete.zig:43`, `workspaces_reorder.zig:367`.
2. **workspace items / tasks / kanban / design** — `workspace_items_get.zig:45-60`, the item create/update/delete/reorder handlers, `kanban_model.zig` queries, `design_*` handlers. Each must resolve the workspace root and check it before returning children.
3. **sessions / llm history** (the biggest leak) — `llm_history.zig:164-191,225,346-358,405,530-552,1672-1700,2780,2924-2932`, `session_list.zig:66`, `session_get.zig`, `session_messages_get.zig:285-290`, queue/plan/skills/background-process handlers. `session_list.zig:68-96` already derives its workspace scope **server-side** — keep that, and add the owner predicate at the same place.
4. **workers** — `worker_list.zig:43-52`, `worker_get.zig`, `start_agent.zig`, `run_all_agents.zig`, plus a new `getWorkerBySessionIdForUser`. **Written here — nothing to inherit**: the branch that had them is not merged (D6), so `1aa1d97c` is a reference for the query shape only. Depends on the 093 column from W0/W1; worker scoping is *not* optional, or B still sees A's running workers in `/api/workers`.
5. **terminals** — `terminal_create.zig:69` (in-memory sessions have no owner) + the REST/WS surface; add an owner field and reject cross-user attach.
6. **misc** — `/api/skills*`, `/api/memories*` (cwd-scoped today; workspace ownership makes them transitively owned once the workspace is checked), `/api/files/download.zig:139`, `/api/git/*`.

**Ratchet test (W6)** prevents regression: a static Zig test enumerating the route table and asserting each ownership-sensitive route resolves an owner (grep-based contract, in the style of the repo's existing `*_contract_test.zig`).

**Acceptance (python functional, two cookies):** `GET /api/workspaces` as B does not contain A's workspace; `GET /api/session/:a_id` as B → 404; `GET /api/session/:a_id/messages` as B → 404; `GET /api/workers` as B lists only B + shared; `attach` to A's terminal as B → 404.

### W3 — push channels (SSE + WS)

Today `/api/events` subscribes to **family** routing keys — `workers`, `sessions`, `kanban`, `llm`, `queue` (`unified_events_sse.zig:10-16` comment, `:341-367` subscribe loop) — so every connected client receives every user's events. The handler already resolves the cookie and then throws the identity away (`:277-295`).

Plan:
1. Resolve the owner in the SSE handler (keep the existing 401/auth_error behaviour).
2. Filter at the **callback**, not the subscription: the bus delivers `SseEvent` payloads to each client's callback; drop events whose owning user is neither the subscriber nor shared. Requires the event payload to carry a user id (or a session/workspace id that can be joined to an owner) — decide in the implementation spike; the cheapest correct version is to add the owner to `SseEvent` at publish sites (`src/agentic_loop/on_event_sent*.zig`, `sse_send_event_worker.zig`).
3. Same for `terminal_ws.zig:149-163` (identity validated then dropped) — reject cross-user attach, and stop silent `return` (log + close frame).
4. Background workers publish events with **no** request context: the owner must be carried on the enqueued job (`EmitRunAgentInput.user_id`, matching W1) and read back at publish time.

**Acceptance (python functional):** two SSE clients (A and B) on `channels=sessions,workers,llm`; A triggers a session rename + a worker run; assert **B receives zero frames mentioning A's session/worker ids** and still receives its own.

### W4 — settings / config follow-ups

1. Background paths that read the **global** `config.json` while auth is on (worker/CLI/tool processes): resolve the owner from the session row (available after W1) and read `users.config_json`. This closes the same class of bug as `tools_exec_add_mcp_server.zig`.
2. `nalar_config_get/put/profile_delete` already re-resolve the cookie inline — refactor them onto `resolveRequestUserId` so there is exactly one identity implementation, not four.
3. Document `config.json` as "auth-off only" in `README.md` (the README already documents the `users.config_json` partition at `:200-210`; extend, don't rewrite).

**Acceptance:** extend `tests/functional/user_config_test.py` — a background/worker config write lands in the right user's row.

### W5 — frontend: stop B inheriting A's browser state

Inventory (from the audit; keys are **all** origin/window-global today):

- localStorage: `nalar-active-workspace`, `nalar-workspace-expanded`, `nalar-workspace-item-expanded`, `nalar-workspace-item-tasks-expanded`, `nalar-workspaces:v1`, `sidebar-collapsed`, `sidebar-width`, `active-chat-id`, `active-chat-name`, `active-task-id`, `nalar_chats_sort_direction`, `nalar-sidebar-*`, `nalar-right-sidebar-width`, `nalar-right-sidebar-panel`, `nalar-tabs:v1:<windowId>`, `nalar-folder-picker-recent:v1`, `nalar-task-media:v1`, `nalar-git-status:v1:<cwd>`, `nalar-auth-me:v1`, `session_cwd_<id>`, `chat-scroll-*`, `kanban-*-scroll-*`, `diff-review-comments`, `diff-comment:*` (`src/apps/desktop/src/stores/workspaces.ts:225-230`, `src/apps/desktop/src/stores/navigation.ts:5-10`, `src/apps/desktop/src/stores/sidebar.ts:4-13`, `src/apps/desktop/src/stores/tabs.ts:49-61`, `src/apps/desktop/src/helpers/taskMediaCache.ts:35`, `src/apps/desktop/src/helpers/workspacesCache.ts:22`).
- IndexedDB: single database **`nalar-sync`** v3 with stores `messages`, `sessions`, `tasks`, `sync_state` (`src/apps/desktop/src/sync/IndexedDbStore.ts:10-15`) containing full cached message bodies.
- Logout clears only `nalar-auth-me:v1` (`src/apps/desktop/src/components/shell/Sidebar.vue:256-268`, `src/apps/desktop/src/helpers/authMe.ts:109-116`).

Plan:
1. **One namespacing helper**: `userScopedKey(key)` using the id from `/api/auth/me` (`nalar-auth-me:v1` already caches `user.id`). When auth is off, `userScopedKey` returns the key unchanged → zero migration for the auth-off case.
2. Apply it to the **data-bearing** keys first — `nalar-workspaces:v1`, `nalar-active-workspace`, `active-chat-id`, `active-chat-name`, `active-task-id`, `nalar-tabs:v1`, `nalar-task-media:v1`, `diff-review-comments`, `session_cwd_*`. Pure-preference keys (sidebar widths) can follow or be left global; call the split out explicitly in the PR.
3. **IndexedDB**: include the user id in the database name (e.g. `nalar-sync:<userId>`; `IndexedDbStore.ts:10`), or add `userId` to the key paths. Cheapest safe version is the DB-name split — no schema/key migration, no cross-database reads.
4. **Purge on identity change**: on logout *and* when `/api/auth/me` returns a different id than the cached one, clear the previous user's namespaced keys, delete the old IndexedDB database, and reset the Pinia stores (`workspaces`, `navigation`, `tabs`, `sidebar`) — including via a `storage` event listener so an already-open sibling tab reacts.
5. **Gate the first paint**: while auth is on and `/api/auth/me` is unresolved, do not paint from `nalar-workspaces:v1` / IndexedDB (`stores/workspaces.ts:1176-1207`, `ChatView.vue:2611-2645`, `ChatsList.vue:463-485`). B must never see A's cached list, even for one frame.
6. **Tests** (vitest): `userScopedKey` round-trip; a spec that logs in as A with state present, then switches to B, and asserts A's cache is gone and never painted; `authMe` change → purge invoked. Follow the repo rule that any view state change also updates the URL (existing `appUrl.ts` canonical routes are already user-agnostic and stay as-is).

### W6 — tests, ratchet, CI

1. **`tests/functional/per_user_isolation_test.py`** — the primary deliverable test file. Harness usage mirrors `tests/functional/user_config_test.py`: one `FunctionalHarness.boot(bin, extra_args=("--auth",))`, isolated `HOME` tmpdir, `create-admin` twice (`--force` for the second), two cookie jars, never port 8081.
   Required cases:
   - `test_workspaces_list_is_per_user`
   - `test_workspace_get_by_foreign_id_is_404`
   - `test_session_create_stamps_owner`
   - `test_session_get_by_foreign_id_is_404`
   - `test_session_messages_by_foreign_id_is_404`
   - `test_workers_list_is_per_user`
   - `test_sse_does_not_deliver_foreign_events`
   - `test_body_user_id_is_ignored` (spoof attempt)
   - `test_auth_off_is_unchanged` (regression: one user, no cookie, everything visible)
   - `test_legacy_user_system_rows_visible_to_all` (D2)
2. **Static contract test** listing ownership-sensitive routes (ratchet, §W2).
3. **Zig in-memory tests**: the visibility clause for 2 users + sentinel (`1aa1d97c`'s test is a reference template), and the migration's idempotency + registration (`Migration093 is registered in allMigrations`).
4. **CI**: the functional suite must run in the same job that runs `tests/functional/auth_test.py`; add the new file to the list if the runner enumerates explicitly.

---

## Risks & mitigations

| risk | mitigation |
|---|---|
| **Data disappears on upgrade** — the machine owner enables `--auth` and their existing workspaces vanish | D2 shared sentinel; `test_legacy_user_system_rows_visible_to_all` |
| **181 handlers is too big for one PR → half-scoped state** | ship by route family (W2.1…W2.6), each with its own test; the ratchet test (W6.2) makes the remaining unscoped routes an explicit, visible list |
| **`user_system` sentinel becomes a permanent junk drawer** — unscoped writes keep landing there and are visible to everyone | assert stamping in W1 tests; the sentinel bucket only shrinks (D2); add a metric/log when a write falls back to `user_system` in auth mode |
| **Silent migration skip** — `MigrationManager` applies by `version >` with no duplicate guard, so a version clash produces no error at all | D6: this plan owns 093; prove the number is free across **all** branches with `git log --all -G 'version: u32 = 9[23]'` before registering |
| **Framework limits** — no principal on `ctx`; `req.session` is a cookie flash bag | D3: server-side re-resolve; documented so nobody "optimises" it into `req.session` |
| **Breaking the auth-off path** (the default for almost all users) | D5: resolver returns `user_system`, clause always true; explicit regression test + the existing ~40 functional tests must stay green |
| **Performance**: extra PK lookup per request | single indexed SELECT (`auth_sessions.token_hash` is the PK); measure in the W2 spike on a cold cache if it shows up in profiles |
| **False sense of security**: filesystem/host still shared | deferred by explicit user decision (D9); state the boundary in `README.md`; never claim "multi-tenant" or "sandboxed" anywhere |
| **Frontend purge races** (tab A logs out while tab B is mid-fetch) | purge on identity *change* observed from `/api/auth/me`, plus `storage`-event fan-out; never paint cached data before the identity is known (W5.5) |

## Verification checklist (definition of done)

- [ ] `zig build test` green; new resolver + migration + clause unit tests present.
- [ ] `git log --all -G 'version: u32 = 9[23]'` run before registering migration **093** (D6 — a duplicate version is the only silently-skipped failure mode in this plan).
- [ ] `tests/functional/per_user_isolation_test.py` green, all 10 cases, on an isolated `HOME`.
- [ ] Existing suites untouched by the change: `tests/functional/auth_test.py`, `user_config_test.py`, plus the wider functional suite.
- [ ] Manually verified on a scratch instance (`--auth`, two admins, two browsers/profiles): A sees only A+legacy; A's live events never appear in B's EventSource; A's workspace never appears in B's sidebar after a browser switch without a page reload.
- [ ] `README.md` documents: per-user ownership, the `user_system` legacy rule, no admin cross-user visibility, `config.json` = auth-off only, and the **deferred** filesystem boundary (D9).
- [ ] Ratchet test listing still-unscoped routes is committed (so the remaining gap is visible, not forgotten).
