# TASK 5 BRIEF — HTTP handlers + routes

WORK DIRECTLY IN THIS EXISTING WORKTREE — do NOT call `set_git_worktree`, do NOT create a
new worktree, do NOT touch `/home/ginwa/ginwaaitoolbox`:

    /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930

`cd` there for every command. All paths below are relative to that directory.

Repo: **nalar**, Zig 0.16. Tasks 1–4 are committed and green. **Do NOT modify**
`secrets_store.zig`, `secrets_substitution.zig`, `handle_tool.zig`, `workspace_scope.zig`,
or any `src/modules/agent/tools/*` file. Do not touch the frontend.

Plan: `docs/superpowers/plans/2026-10-02-workspace-secrets.md` (rev 2) — `### Task 5` and the
`## Wire Contract` section. Implement the contract EXACTLY as written there.

---

## The template to copy

`src/http_handlers/documents_*.zig` is the precedent and you should mirror it closely — the
house shape is: module docstring → private `useCase` (pure, DB-taking, typed error set) →
`pub fn xHandler(ctx, req, res)` (thin: parse, call useCase, map errors) → inline
`std.testing` tests against in-memory SQLite in the same file.

Read all five `documents_*.zig` files plus `documents_store.zig` before writing anything.

---

## Four handlers

| File | Verb | Route |
|---|---|---|
| `secrets_list.zig` | GET | `/api/workspaces/:workspace_id/secrets` |
| `secrets_create.zig` | POST | `/api/workspaces/:workspace_id/secrets` |
| `secrets_update.zig` | PATCH | `/api/workspaces/:workspace_id/secrets/:secret_id` |
| `secrets_delete.zig` | DELETE | `/api/workspaces/:workspace_id/secrets/:secret_id` |

Each handler signature is exactly:
```zig
pub fn secretsListHandler(
    ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse,
) !gserverz.HttpResponse
```

`workspace_id` comes from `req.params.get("workspace_id") orelse ""` — never from the body or
a query param. `secret_id` likewise.

### Wire shapes (exact)

| Verb | Status | Body |
|---|---|---|
| GET | 200 | `{ "secrets": [{ "id", "name", "created_at", "updated_at" }], "count": N }` |
| POST | 201 | `{ "secret": { "id", "name", "created_at", "updated_at" } }` |
| PATCH | 200 | `{ "secret": { …same… } }` |
| DELETE | 200 | `{ "id": string, "success": true }` |
| error | 4xx/5xx | `{ "error": string }` |

**No response body anywhere contains the value.** Not on create, not on update, not on list.
There is no `key_hint`. If you find yourself wanting to return the value, re-read Design
Decision 9 — the UI never receives it, and "the value crossed the network and we chose not to
render it" is not a guarantee.

### Request bodies

```jsonc
// POST
{ "name": "GITHUB_TOKEN", "value": "ghp_xxx" }

// PATCH — both fields optional. `name` omitted = keep, `value` omitted = keep.
// `name` is NOT renameable: a rename would silently break every prompt and
// skill that references {{SECRETS:OLD_NAME}}.
{ "name": "GITHUB_TOKEN", "value": "ghp_new" }
```

### Error mapping

Two exhaustive `switch (err)` blocks per handler (status + message), exactly as
`documents_get.zig` does. The switch must be exhaustive over the handler's declared error
set — that is the de-facto safety net, so do not add a variant you forget to map.

| Error | Status | Message |
|---|---|---|
| `WorkspaceIdRequired`, `NameRequired`, `ValueRequired` | 400 | `"workspace_id required"` / `"name is required"` / `"value is required"` |
| `InvalidName` | 400 | `"name must match [A-Za-z0-9_-]{1,64}"` |
| `NameTaken` | 409 | `"a secret named 'X' already exists in this workspace"` |
| `NotFound` | 404 | `"secret not found"` |
| store errors | 500 | `"DB error"` |

**404, never 403, for every cross-workspace case** — a 403 confirms the id exists, which is
itself a leak. `documents_get.zig`'s module docstring explains this; follow it.

---

## Response shapes in `http_response.zig`

Add `SecretResponse` and `makeSecretListResponse` to
`src/http_handlers/http_response.zig`, mirroring `DocumentResponse` / `makeDocumentListResponse`
(the list envelope is `{…s, count}` rather than a bare array so a future paginated variant can
add fields without a breaking change — that is the stated reason in that code).

Add a comment saying the type deliberately has **no `value` field**, so a future edit does not
"helpfully" add one back.

---

## Registration (three mechanical edits)

1. `src/http_handlers/mod.zig` — four re-exports, mirroring the `documentsListHandler` block.
2. `src/main.zig` — four routes on the `authed` group, beside the documents routes:
   ```zig
   try authed.get   ("/api/workspaces/:workspace_id/secrets",              ai_mod.http_handlers.secretsListHandler);
   try authed.post  ("/api/workspaces/:workspace_id/secrets",              ai_mod.http_handlers.secretsCreateHandler);
   try authed.patch ("/api/workspaces/:workspace_id/secrets/:secret_id",  ai_mod.http_handlers.secretsUpdateHandler);
   try authed.delete("/api/workspaces/:workspace_id/secrets/:secret_id",  ai_mod.http_handlers.secretsDeleteHandler);
   ```
   **The two literal routes MUST be registered before the two `:secret_id` routes.**
   `matchRoute` walks routes in registration order and returns on first hit
   (`zig-pkg/kabelweb-*/src/server/router.zig:614`). Write a comment saying so — the repo
   treats this as a real hazard and several existing routes carry such comments.
3. **No auth code.** Any route whose path carries `:workspace_id` is already 404-gated by
   `src/http_handlers/auth_middleware.zig` (the `canSeeWorkspace` block), for free.

---

## Tests

Inline `test "..."` blocks in each handler file, over in-memory SQLite, copying the
`documents_*.zig` test setup.

Required:

1. Each handler's `useCase` against in-memory SQLite: the happy path, and each error variant
   mapping to the right status.
2. **The LIST `useCase` selects no `value` column — assert on the SQL string itself**, so a
   future edit that adds it fails the test. This is the mechanical version of the "no value
   crosses a GET" promise.
3. A POST with `value: ""` returns **400 `ValueRequired`, not 500**. `SqliteBackend.exec`
   binds a zero-length slice as SQL NULL, which violates `NOT NULL` — this is exactly the
   class of bug the repo's testing rule exists to catch, and it is only visible over a real
   HTTP round-trip.
4. Duplicate name in one workspace → 409; the SAME name in a second workspace → 201.
5. Cross-workspace: workspace B's `useCase` for A's secret id → `NotFound` → 404, never 403.
6. **Static contract tests** grepping `src/main.zig` for each of the four route literals, so
   deleting a route breaks the build rather than shipping silently. Copy the idiom from
   `llmSourceContains` in `src/http_handlers/mod.zig` (it does
   `std.Io.Dir.cwd().readFileAlloc(testing.io, "src/main.zig", …)` then `indexOf`).
7. A static assertion that the literal routes appear BEFORE the `:secret_id` routes in
   `main.zig` — i.e. compare the byte offsets of the two route strings. This pins the
   ordering hazard mechanically rather than trusting review to read the comments.

**TDD: failing test first, watch it fail, then implement.**

---

## GATE

```bash
cd /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930
zig build test --summary all
```

Must report `Build Summary: 8/8 steps succeeded` and exit 0.

**Gotchas that cost time already:**
- The run prints a spurious `failed command: .../test --listen=-` line immediately BEFORE the
  success summary. **Not a failure.** Trust the Build Summary and exit code.
- Cold build ≈ 10+ min. Do NOT run two `zig build test` concurrently in this tree — they
  contend on `.zig-cache` and produce a genuine spurious failure. Another agent may be working
  in the same tree on the frontend; coordinate by not starting a build until you have checked
  no other `zig build` is running (`pgrep -x zig`).

If failures appear in files you did not touch, report them rather than fixing them.

Commit when green:

```
feat(secrets): workspace-scoped HTTP surface
```

---

## HARD CONSTRAINTS

- **No `// NEW (plan: ...)` comments.** Explain WHY in one plain sentence, or not at all.
- **No `user_id`.** Access is workspace membership via `workspace_members`, enforced by
  `auth_middleware` → `canSeeWorkspace`. Do not add auth code; do not add a per-secret owner.
- **Never return, log, or echo a secret value** in any response body, error message, or log
  line.
- Never bind or touch port 8081.
- If you conclude a file outside the list above must change, STOP and report.

## REPORT BACK

Files changed, exact commit sha, the `Build Summary` line, confirmation that the literal
routes precede the `:secret_id` routes, and any deviation with its reason.