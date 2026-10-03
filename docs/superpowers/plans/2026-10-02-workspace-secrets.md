# Workspace Secrets Implementation Plan (rev 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user stores a credential once per workspace under a name of their choosing (`GITHUB_TOKEN`, `stripe_key`, …). The agent may reference it from **any** tool parameter as the literal text `{{SECRETS:GITHUB_TOKEN}}`; the backend substitutes the real value immediately before the tool executes. The model never receives the value **through the substitution path** — not in a prompt, not in a tool argument it can read back, not in a tool result, not in `llm_history`, not over SSE. (It is stored plaintext, so this is *not* a claim that the model can never obtain it by other means; see Design Decision 2.)

**Architecture:** Three parts that must land as one change, because each is worthless alone.

1. **Storage** — a `workspace_secrets` table (Migration 101) holding `workspace_id`, `name` and a plaintext `value` column, matching how `config.json` already holds the LLM `api_key`. No encryption at rest, no `key_hint` (reviewer, 2026-10-03).
2. **The substitution boundary** — one function, `secrets_substitution.substituteToolArguments`, called from `dispatchTool` (`src/agentic_loop/handle_tool.zig:192`) *after* the Lua pre-hook and *before* the registry walk. It parses the raw arguments JSON, walks every string leaf, replaces `{{SECRETS:name}}` with the decrypted value, and returns the substituted string plus a list of `{name, value}` pairs used to redact the tool's own output. Substitution is deliberately **not** done in the Lua hook seam and **not** done on the raw bytes — both are explained in Design Decisions 4 and 5.
3. **Discovery + the guarantee** — a `list_secrets` agent tool that returns names only (never values), plus a prompt rule. The discovery tool exists because the repo has an explicit, twice-stated convention that catalogues are discovered by tool call and never pre-listed in the prompt (`src/modules/agent/prompts/core.zig:177` for skills, `:160` for progressive tools).

**Tech Stack:** Zig 0.16 (`AgentTool`, `ToolExecContext`, `wrapToolOutput`, `std.json` parse/re-serialize), SQLite (Migration 101), Vue 3 + vitest, python functional harness (isolated tmpdir `HOME`, free port outside 8081). **No new dependencies, no crypto.**

---

## Global Constraints

- **NEVER kill or bind port 8081.** It is the always-running dev server. `tests/functional/harness.py:145` declares `RESERVED_PORTS: tuple[int, ...] = (8081,)` and the picker skips it.
- **NEVER verify HTTP behaviour with `nohup ./zig-out/bin/nalar --port 8080 &` + `curl`.** Use `tests/functional/harness.py`, which boots a fresh binary against an isolated tmpdir `HOME` and tears both down. The anti-pattern leaks a process across tool calls and is exactly what missed the PR #291 bugs.
- **`SqliteBackend.exec` binds a zero-length slice as SQL NULL** (`zig-pkg/databases-…/src/sqlite/Sqlite.zig:176-182`). Every `NOT NULL` text column written by this feature goes through `COALESCE(NULLIF(?, ''), '')`, exactly as `documents_store.zig:202-206` does. A `PATCH` that clears a secret to `""` will otherwise 500.
- **A new migration must be version 101 and appear in `allMigrations`.** PR #781 (merged) took 100 with `workspace_members`; re-verify 101 is still free on `main` before writing the migration — a stale number here is the most likely reason Task 2 fails on day one. `runMigrations` gates on `migration.version > currentVersion` where `currentVersion` is `MAX(version)` (`src/migrations/migration.zig:1596-1597`) — a single global watermark. A migration that is not in the array, or whose version is ≤ the max, silently never runs on an existing database.
- **No `// NEW (plan: …)` tags** in any new code or comment. Explain *why* in one plain sentence or not at all.
- **Cross-platform:** the frontend uses Tailwind v4 utility classes plus CSS custom properties (`var(--semantic-text-muted)`), never hex literals. The backend must compile on Linux/macOS/Windows — the CI matrix runs `backend-{linux,macos,windows}`.
- **`workspace_secrets` carries no `user_id`.** Access is workspace membership via `workspace_members` (PR #781), enforced by `auth_common.workspaceVisibilityClause` + `canSeeWorkspace` exactly as it is for `documents`. A per-secret owner column would answer authorship, not entitlement, and would contradict the middleware the moment a workspace is shared. See Design Decision 11.
- **Route order matters both sides of the wire.** Backend `matchRoute` walks routes in registration order and returns on first hit (`zig-pkg/kabelweb-…/src/server/router.zig:614`), so literals must be registered before same-length `:param` siblings. Vue Router matches in registration order too (`src/apps/desktop/src/router/index.ts`), so `/app/:workspaceId/settings` must be registered **above** `/app/:workspaceId` at `router/index.ts:86`.
- **Verification gates for this feature** (all must pass before the PR is opened):
  - `zig build test` (inline Zig tests, including the redaction tests)
  - `cd src/apps/desktop && npx vue-tsc --noEmit && npx vitest --run src/__tests__/SecretsSection.spec.ts`
  - `PYTHONPATH=tests/functional .venv-func/bin/python -m pytest tests/functional/workspace_secrets_test.py -q`

---

## Current State (verified 2026-10-02 in this worktree, via 4 parallel explorers + first-hand re-verification)

### The storage layer

| Fact | Evidence |
|---|---|
| Highest existing migration is **100** (`Migration100AddWorkspaceMembers`, PR #781, merged). **101 is the next free number.** | `src/migrations/migration.zig:2051`, struct at `:14779` |
| `allMigrations` is an array literal ending at `src/migrations/migration.zig:2052`; a new migration is one `pub const MigrationNNNX = struct` + one array entry. | `src/migrations/migration.zig:1790-2052` |
| **There is NO encryption anywhere in `src/`.** Every `crypto` hit is hashing (bcrypt, sha2, blake3). Zero cipher imports, zero keyring, zero `crypto.random`. This is why plaintext storage (DD2) is consistent rather than novel. The only `encrypt`-named column is `reasoning_encrypted_content`, a pass-through of Anthropic's own opaque token. | `rg -i 'encrypt\|decrypt\|cipher\|aes\|keyring' src/` |
| **There is NO `secrets` table, route, tool, module, or `{{SECRETS:` token anywhere.** Zero name collisions with the proposed `secrets` / `list_secrets` / `workspace_secrets`. | verified by exhaustive search |
| The newest workspace-scoped table is `documents` (Migration 098): `workspace_id TEXT NOT NULL`, FK to `workspaces(id)`, **no `user_id`**. | `src/migrations/migration.zig:3737-3746` |
| Only **five** tables carry a `user_id` (`workspaces`, `sessions`, `worker`, `skill_eval_runs`, `skill_eval_results`). Workspace scoping does not use it. | `src/migrations/migration.zig:4604`, `:4613`, `:5334`, `:5565`, `:5593` |
| `PRAGMA foreign_keys` is deliberately OFF, so a declared `ON DELETE CASCADE` is documentation only — the workspace-delete path issues the child DELETE itself. | `src/migrations/migration.zig:3718-3721` |
| Zig 0.16 *does* ship `std.crypto.aes_gcm.Aes256Gcm` (`/usr/lib/zig/std/crypto/aes_gcm.zig:11-12`) — encryption was available and was deliberately declined (DD2), not overlooked. | verified in the toolchain |
| `getDefaultConfigDir` is cross-platform (APPDATA / Library/Application Support / `.config`) and is the established home for user state. | `src/modules/config/Config.zig:2884-2909` |

### The dispatch layer — the load-bearing part

| Fact | Evidence |
|---|---|
| **`dispatchTool` is the choke point** for every built-in tool. `effective_call` is already a mutable local copy carrying `function.arguments`. | `src/agentic_loop/handle_tool.zig:192-193` |
| The Lua pre-hook runs at `:207` and the registry walk at `:217-221`. Insertion point for substitution is **between them**, on `effective_call`. | `src/agentic_loop/handle_tool.zig:207-221` |
| **MCP tools bypass `dispatchTool` entirely.** Phase 3 of `handle_tool` intercepts `isMCPTool` at `:747` and `continue`s. `dispatchTool`'s own MCP branch (`:224-225`) is dead from the production path. | `src/agentic_loop/handle_tool.zig:747-788` |
| `handle_tool` is the **only** entry to dispatch: main session, sub-agent, kanban task and routine all reach it via `runAgenticMultiStepnew` (`workflow.zig:571`) → `workflow.zig:1631`. No HTTP handler executes a tool. | verified call graph |
| **Phase 2 persists the RAW arguments to the DB at `handle_tool.zig:533`, textually BEFORE dispatch at `:790`.** So a substitution applied at dispatch leaves the database holding `{{SECRETS:NAME}}` — which is the correct outcome and must be asserted by a test, not assumed. | `src/agentic_loop/handle_tool.zig:533`, `:790` |
| Both persistence paths — Phase 1 placeholder (`:601`, `:610`) and the error envelope (`:796`) — pass `tool_call.function.arguments`, **not** `effective_call.function.arguments`. Dispatch-time substitution therefore does not by itself leak to the DB. | `src/agentic_loop/handle_tool.zig:601`, `:610`, `:796` |
| **LEAK VECTOR — `shell.zig` echoes the substituted command back into the tool result.** `result_to_json` puts `result.command` (the post-substitution dupe) into the `data` payload, so `curl -H "Auth: {{SECRETS:gh}}"` returns the real token to the model. This is the single biggest threat to the feature's promise. | `src/modules/agent/tools/shell.zig:874-881`, `:677`, `:851` |
| Naive byte substitution into the raw arguments JSON is unsafe: a secret containing `"` terminates the JSON string literal and a secret containing `\` becomes an escape leader. Consumers that re-parse the args — `normalizeParamsJson` (`tools_wrap_output.zig:94`), `parseShellArgs` (`tools_exec_bash_args.zig:115`), `repairToolCallArguments` (`Agent.zig:1785`) — all break or silently degrade to `{"_raw": …}`. | verified all four |
| `jsonEscapePath` at `handle_tool.zig:1680-1694` escapes only `\` and `"` — insufficient for arbitrary secret values (no control chars, no NUL). | `src/agentic_loop/handle_tool.zig:1680-1694` |
| `ToolExecContext` has **no `workspace_id`**. Workspace is resolved server-side from `ctx.session_id` via `workspace_scope.resolveWorkspaceId` — the documents tools' established pattern. | `src/agentic_loop/tools.zig:92-143`, `src/agentic_loop/workspace_scope.zig:17` |
| `shell.zig` sets **no `env_map`** on either spawn; the child inherits the server's full environment unmodified. There is no existing env-injection point. | `src/modules/agent/tools/shell.zig:435-452`, `:818-824` |
| All Zig tests are **inline `test "…"` blocks** — there is not a single `*_test.zig` file in the repo. `handle_tool.zig:1693-1806` is the worked template for a test that builds a real `ToolContext` with in-memory SQLite and calls `dispatchTool` directly. | verified |

### The prompt layer

| Fact | Evidence |
|---|---|
| The live prompt builder is `buildMessages` (`prompts_build_messages_for_agent_prompt.zig:74`). `build_agent_prompt` is **dead** — no production caller, only 8 test call sites. | verified |
| `buildMessages` receives `db` (`:77`) and `session_id` (`:79`), so a workspace-scoped lookup is available at prompt time. | `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig:77`, `:79` |
| The repo convention is explicit: catalogues are discovered by **tool call, never pre-listed in the prompt** — "no skills are pre-listed in this prompt" (`core.zig:177`), "Tools you already have are NOT listed by `search_tool`" (`core.zig:160`). | `src/modules/agent/prompts/core.zig:177`, `:160` |
| Static tool rules are appended unconditionally at `prompts_build_messages_for_agent_prompt.zig:121-136` and live in `core.zig` as `pub const <Name>ToolRule`. | verified |
| A `DEFAULT_AGENT_TOOLS` list exists at `tools_equipped.zig:343` and seeds new agents only — it does **not** retrofit existing agents. | `src/agentic_loop/tools_equipped.zig:343` |

### The HTTP + frontend layer

| Fact | Evidence |
|---|---|
| `matchRoute` walks `for (self.routes.items)` at `router.zig:614` and returns on first hit. **Note:** the repo's own `AGENTS.md` and two older plans cite `router.zig:182` for this — that line is a closing brace in the current vendored package and is **stale**. Use `:614`. | verified against the vendored package |
| The documents precedent for a workspace-scoped CRUD resource is complete and copyable: `documents_store.zig`, five `documents_*.zig` handlers, five `mod.zig` re-exports at `:171-175`, five routes at `main.zig:840-844`. | verified |
| Any route whose path carries `:workspace_id` is **automatically 404-gated** in auth mode by `auth_middleware.zig:74-82`, which calls `canSeeWorkspace` (`auth_common.zig:217`). No per-handler auth code is needed for the workspace check. | verified on `main` at PR #783 time |
| `GET /api/config/nalar` returns MCP server headers **in cleartext** (`mcp_servers` is `?std.json.Value`, sent "as-is") and sub-agent `api_key` verbatim. There is no redaction layer in the config surface today. | `src/http_handlers/http_response.zig:365`, `:434` |
| **No `/app/:workspaceId/settings` route exists.** `SettingsView.vue` is global (LLM profiles, MCP, tools, memories) and its own tab state is a bare `ref` at `:11`. `/app/:workspaceId` at `router/index.ts:86` is a catch-all that would swallow `/app/ws_1/settings`. | verified |
| `?section=` is the reserved query key inside the settings shell; `?tab=` is owned by browser tab-mode and must not be reused. | `src/apps/desktop/src/components/NalarSettings.vue:84-88` |
| The frontend already has a masked-value helper (`McpServersSection.vue:18`) — **but it puts the raw value in a `title=` tooltip at `:120` while masking at `:138`.** Do not copy that pattern. | verified |
| Frontend tests: vitest, `cd src/apps/desktop && npx vitest --run <file>`. `McpServersSection.spec.ts` is the template for a presentational section spec including a masking assertion. | verified |
| **There is no iOS app and no Android settings screen.** Zero `.swift`/`.xcodeproj` files; the 8 Android `*Screen.kt` files are login/recents/chat/projects/network-inspector. No shared codegen layer. **Mobile is out of scope.** | verified |

---

## Design Decisions (for reviewer)

### 1. A new `workspace_secrets` table, not a `users.config_json` field

**Decision:** Migration 101 creates `workspace_secrets`.

**Rejected:** adding a `secrets` map to `users.config_json` (the `web_search` plan's no-migration route). It is wrong on three counts: (a) `config_json` is **user**-scoped and has no `workspace_id` — the feature's stated unit is the workspace; (b) the whole blob is returned to the browser by `GET /api/config/nalar` verbatim (`http_response.zig:365`), so a secrets map there would be readable by any authenticated user of the same account with one GET; (c) `Migration099` already treats `config_json` as a raw-string-rewritten blob — mixing a credential store into it invites the next token-rename migration to corrupt it.

**Why a table is right:** the documents precedent (`documents_store.zig`) already proves the pattern: `workspace_id` is a function parameter that appears in the `WHERE` clause, never a value the caller can choose to omit. The who-may-use-it half of that is `auth_common.workspaceVisibilityClause` over `workspace_members` (see Design Decision 11).

> **Rev 2 (2026-10-03, post-merge).** `main` was merged into this branch before
> implementation, which moved a number of cited line numbers (PR #781 added Migration 100;
> PR #780 added the `web_search` feature). Every `path:line` below was re-audited against
> the merged tree, and **Migration 101 was re-verified as free**. No design change from rev 1.

### 2. No encryption at rest — the value is stored as plaintext `TEXT`

**Decision (reviewer, 2026-10-03):** no master key, no cipher. `value TEXT NOT NULL` holds the
plaintext, exactly as `config.json` holds the LLM `api_key` and `users.config_json` holds MCP
header values today. No `secrets_master_key.zig`, no `secrets.key`, no `value_enc`.

**Why this is coherent, not careless:** it makes the feature match the repo's existing credential
posture instead of being the one place that claims more. Encryption at rest would only have
protected the `agent.db` file, and only because the key sat *beside* it in the same config dir —
so a compromised home directory gets everything either way, while every backup, every `sqlite3`
invocation and every copied `.db` would have been inert. That trade was judged not worth a
crypto module, a key-file lifecycle, and three platform-conditional code paths. Agreed.

**What the feature therefore does and does not promise — read this before writing the header:**

The substitution machinery still guarantees the value is never passed to the model **by that
machinery**: it never appears in a prompt, in a tool argument the model can read back, in a tool
result, in `llm_history`, or over SSE. That part is unchanged and is what Tasks 3, 4 and 8 prove.

It does **not** defend against the model going to disk for it. There is no sandbox on the read
path — `read_file.zig` contains no sandbox check, and `file_sandbox.zig` governs only
`present_files` and `GET /api/files/download` ("may this file be shown to the browser"), not
reads. `command` spawns `bash -c` with no allowlist. So a prompt-injected model can run
`sqlite3 ~/.config/nalar/agent.db 'SELECT value FROM workspace_secrets'` and read every secret in
every workspace. **With plaintext storage that is a one-command exfiltration.**

That is exactly today's exposure for `api_key` and MCP headers, so this change makes nothing
worse — but it means the plan must not overclaim. The Goal line is amended accordingly, and any
future copy of this feature's description must carry the same caveat.

### 3. `{{SECRETS:NAME}}` is substituted at `dispatchTool` AND at the MCP branch

**Decision:** one `secrets_substitution` module, called from two places: `dispatchTool` (`handle_tool.zig:207`, after the pre-hook, before the registry walk) and the Phase-3 MCP branch (`handle_tool.zig:747`, before `handle_mcp_tool_run`). Both call the same function.

**Why two and not one:** verified — MCP tools never reach `dispatchTool` from the production path; Phase 3 intercepts them at `:747` and `continue`s. A hook placed only in `dispatchTool` would silently not cover MCP tools, which is the most likely place a user wants a secret (an API-key-authenticated MCP call).

**Why after the pre-hook and not before:** a user-authored Lua hook receives `arguments` and may log or rewrite them. Substituting before would hand the plaintext to arbitrary user Lua with no redaction downstream. After, the hook sees `{{SECRETS:NAME}}`; only the executor sees the value. (Hooks can still *modify* args — `.proceed_modified` sets `effective_call.function.arguments` at `:211` — so substitution must run on whatever the hook produced, not on the original string.)

### 4. Substitution parses the arguments JSON and re-serializes; it never edits raw bytes

**Decision:** `substituteToolArguments` parses the arguments as `std.json.Value`, walks every object/array/string leaf, replaces placeholders inside **string leaves only**, and re-serializes with `std.json.Stringify.valueAlloc`.

**Rejected:** `std.mem.replace` on the raw arguments bytes. A secret containing `"` terminates the JSON string literal; a secret containing `\` becomes an escape leader (`\U` is invalid — the exact failure documented at `handle_tool.zig:1671-1673`); a newline is an illegal control character. Every downstream consumer that re-parses the args breaks at once, and two of them (`normalizeParamsJson` at `tools_wrap_output.zig:94`, `repairToolCallArguments` at `Agent.zig:1785`) **fail silently** — the model gets `{"_raw": "<garbage>"}` instead of an error. Silent degradation is the worst possible failure mode for a security feature.

**Rejected:** extending `jsonEscapePath` (`handle_tool.zig:1680`). It escapes only `\` and `"`. A secret is arbitrary user input.

### 5. Every substituted value is redacted from the tool's output before it is persisted or streamed

**Decision:** substitution returns `SubstitutionResult { substituted_args, resolved: []ResolvedSecret }`. After the tool runs, `secrets_substitution.redactOutput` replaces each `resolved.value` with `{{SECRETS:NAME}}` in the result string, before `updateAndSendToolResult`.

**Why this is mandatory, not hardening:** `shell.zig:874-881` puts `result.command` — the fully substituted string — into the tool result `data`. So `curl -H "Authorization: {{SECRETS:gh}}"` returns the real token to the model, and from there into the next request to the provider and into `llm_history`. Without redaction the feature delivers the opposite of its promise: the value is still never *stored* in plaintext, but it is handed to the model on the very first call. **Redaction is the feature.**

**Rejected:** "the shell tool echoing its own command is the user's problem". It is precisely the case this feature exists to serve.

**Accepted, stated limitation:** redaction is a best-effort substring replacement on the output. A secret that a tool transforms (base64-encoded, split, reversed) is not caught. This is documented in the module header rather than papered over; catching transformed values would require tainting the whole process, which is out of scope.

### 6. A `list_secrets` tool, not a prompt-inlined list of names

**Decision:** new agent tool `list_secrets` (no arguments) returning `{ name, created_at }` for the calling session's workspace, resolved server-side. Registered in `UNIFIED_TOOL_REGISTRY`, default-on for agent and kanban via `DEFAULT_AGENT_TOOLS`.

**Rejected:** injecting the names into the system prompt as a per-session block (the `makeWorkspaceContext` pattern at `prompts_build_messages_for_agent_prompt.zig:188-193`). It breaks the convention the repo states twice — catalogues are discovered by tool call, never pre-listed — and it puts a per-workspace-varying byte range into the cacheable system prefix, which `prompts_build_messages_for_agent_prompt.zig:113-120` explicitly calls out as a cache-fragmentation cost.

**Note on `DEFAULT_AGENT_TOOLS`:** it seeds **new** agents only (`tools_equipped.zig:343`). Existing agents' persisted `agent_tools` rows predate this tool. Same lesson as `Migration099`: the tool must be reachable without every user editing a checklist, so `filterAndMergeTools` (`workflow.zig:2237`) appends it the way it appends MCP and progressive tools — a **server-side injection that bypasses the allowlist**, exactly as `skill_evals` does (documented at `workflow.zig:2243-2250`).

### 7. The model sees the key NAME, which is not a secret

**Decision:** `{{SECRETS:NAME}}` names are not secret. `list_secrets` returns them; the prompt rule explains the syntax. A name like `GITHUB_TOKEN` tells the model nothing about the credential.

**Rejected:** opaque generated names (`sec_7f3a2b`). Unmemorable, unusable in prose, and buys nothing — anyone who can call the tool can already call `gh` with the value.

### 8. Unresolved placeholder = hard error naming the missing key, never a silent empty string

**Decision:** `{{SECRETS:NOPE}}` where `NOPE` is not in this workspace produces a tool error envelope: `unknown secret 'NOPE' in this workspace — call list_secrets`. The call fails; nothing is dispatched.

**Rejected:** substituting an empty string. `Authorization: ` produces a 401 from a third party several steps later, and the model has no way to connect that to a typo in a placeholder. The immediate, specific error is the only one the agent can act on.

### 9. The UI never renders a stored value, and never receives one

**Decision (reviewer, 2026-10-03):** `GET /api/workspaces/:workspace_id/secrets` returns
`{ name, created_at, updated_at }` — **no value field and no `key_hint` field**. The value exists
only in POST/PATCH request bodies. `key_hint` was proposed and dropped: with it gone, the UI
renders a row as `NAME` + "configured" + `updated_at`, and cannot distinguish two rotations of the
same key. That is the accepted cost of zero disclosure on the read path — rotation is confirmed by
having saved it, not by reading it back.

**Rejected:** returning the value and masking it client-side (what `LlmConfigForm.vue:308-319` does
for `api_key`). "The value crossed the network to the browser and we chose not to display it" is not
a guarantee — it is one XSS away from exposure, and it is already a live bug shape in this repo
(`McpServersSection.vue:135` renders the raw header value into a `title=` tooltip, with the
`maskValue()` call at `:138`).

### 10. Redaction must be applied to the config GET too, or the feature is half a promise

**Decision:** out of scope for this plan, recorded as a follow-up. `GET /api/config/nalar` today returns MCP header values and sub-agent `api_key`s in cleartext (`http_response.zig:365`, `:434`). That is a **pre-existing** leak in a different feature, not one this plan introduces. Flagging it for the reviewer rather than silently expanding scope.

---

### 11. No `user_id` column — membership in `workspace_members` IS the access check

**Decision:** `workspace_secrets` carries `workspace_id` and nothing else. No `user_id`, no `created_by`.

**Why:** [PR #781](https://github.com/ginwa123/ginwaaitoolbox/pull/781) (merged) added `workspace_members(workspace_id, user_id, role, joined_at, invited_by)` with `PRIMARY KEY (workspace_id, user_id)`, and `auth_common.workspaceVisibilityClause` (`auth_common.zig:158`) now answers "who may see this workspace" with an `EXISTS` subquery over that table. `canSeeWorkspace` (`auth_common.zig:217`) uses it. So a per-secret `user_id` would duplicate a decision the schema already makes one level up — and would immediately disagree with it the moment a workspace is shared, because the middleware grants access on membership while the row would grant it on authorship.

The rule is the documents rule, unchanged: **`workspace_id` appears in every `WHERE` clause as a parameter the caller cannot omit**, and the middleware decides whether the caller may use that workspace at all. There is no second check to forget.

**Consequence, accepted for v1 (reviewer decision 2026-10-03):** every member of a workspace can read, rotate, and delete every secret in it — including `viewer`-role members, because `workspaceVisibilityClause` filters on *membership only* and never looks at `m.role`. That is consistent with the rest of the app today (a `viewer` can already read every document in the workspace), and it ships that way deliberately. Role-based access is a later, separate change; see Out of Scope and Open Question 5.

**Not solved by adding a column.** If per-role secret access is wanted, the place to add it is a role predicate inside `workspaceVisibilityClause` or a new `secretsCanBeRead` sibling — not a `user_id` on the row, which would answer the wrong question (authorship ≠ entitlement).

## Wire Contract

### Table (Migration 101)

```sql
CREATE TABLE IF NOT EXISTS workspace_secrets (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL,
    name TEXT NOT NULL,
    -- Plaintext, per Design Decision 2. Never selected on a list path.
    value TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
)
```

```sql
CREATE UNIQUE INDEX IF NOT EXISTS uq_workspace_secrets_name
ON workspace_secrets(workspace_id, name)
```

```sql
CREATE INDEX IF NOT EXISTS idx_workspace_secrets_workspace
ON workspace_secrets(workspace_id, name)
```

Naming follows the established convention: `idx_<table>_<cols>` for plain, `uq_<table>_<cols>` for UNIQUE (see `uq_skill_eval_facts` at `src/migrations/migration.zig:5535`).

**Migration notes the implementer must honour:**
- `FOREIGN KEY … ON DELETE CASCADE` is documentation only — `PRAGMA foreign_keys` is off (`migration.zig:3718-3721`). The workspace-delete handler must issue `DELETE FROM workspace_secrets WHERE workspace_id = ?` explicitly, alongside the existing child deletes.
- One SQL statement per `db.exec` (`sqlite3_prepare_v2` compiles only the first) — `migration.zig:3729-3730`.
- Every `NOT NULL` TEXT column is written `COALESCE(NULLIF(?, ''), '')`.
- The `name` must be validated **before** the INSERT: `SqliteBackend.exec` binds `""` as NULL, which violates `NOT NULL`.

### `{{SECRETS:NAME}}` grammar

```
{{SECRETS:<name>}}
```

- `<name>` matches `[A-Za-z0-9_-]{1,64}`. Anything else is not a placeholder — it is literal text, passed through untouched.
- Nesting is impossible: the substituted value is **not** re-scanned, so a secret whose value happens to contain `{{SECRETS:...}}` cannot recurse.
- Matching is case-**sensitive** on the `SECRETS` token (matching `matchPathWithParams`'s case sensitivity at `router.zig:681`) but case-**insensitive** on the name? **No — case-sensitive on both.** One rule, no surprise: `GITHUB_TOKEN` and `github_token` are different secrets.

### HTTP routes

Registered on the `authed` group so `auth_middleware.zig:74-82` applies the workspace 404 gate automatically. **The two literal routes are registered before the two `:secret_id` routes**, per `router.zig:614`.

| Method | Path | Success | Body |
|---|---|---|---|
| `GET` | `/api/workspaces/:workspace_id/secrets` | 200 | `{ "secrets": [{ "id", "name", "created_at", "updated_at" }], "count": N }` |
| `POST` | `/api/workspaces/:workspace_id/secrets` | 201 | `{ "secret": { "id", "name", "created_at", "updated_at" } }` |
| `PATCH` | `/api/workspaces/:workspace_id/secrets/:secret_id` | 200 | `{ "secret": { …same… } }` |
| `DELETE` | `/api/workspaces/:workspace_id/secrets/:secret_id` | 200 | `{ "id": string, "success": true }` |
| any error | — | 4xx/5xx | `{ "error": string }` (`http_response.zig:350-354`) |

**No response body anywhere contains the value.** Not on create, not on update, not on list, not on get.

**Request bodies:**

```jsonc
// POST
{ "name": "GITHUB_TOKEN", "value": "ghp_xxx…" }

// PATCH — `name` omitted = keep; `value` omitted = keep; name is NOT
// renameable after creation (a rename would silently break every prompt
// and skill that references {{SECRETS:OLD_NAME}}).
{ "name": "GITHUB_TOKEN", "value": "ghp_new…" }
```

**Error mapping** (the house pattern — two exhaustive `switch (err)` blocks per handler, `documents_get.zig:68-83`):

| Error | Status | Message |
|---|---|---|
| `WorkspaceIdRequired`, `NameRequired`, `ValueRequired` | 400 | `"workspace_id required"` / `"name is required"` / `"value is required"` |
| `InvalidName` | 400 | `"name must match [A-Za-z0-9_-]{1,64}"` |
| `NameTaken` | 409 | `"a secret named 'X' already exists in this workspace"` |
| `NotFound` | 404 | `"secret not found"` |
| `NoMasterKey`, `DecryptFailed` | 500 | `"secret store unavailable"` |

**404-not-403** for every cross-workspace case, matching `documents_get.zig:1-8`: a 403 confirms the id exists, which is itself a leak.

---

## File Map

| Action | File | Responsibility |
|---|---|---|
| Create | `src/migrations/migration.zig` | `Migration101CreateWorkspaceSecrets` (table + 2 indexes) + one `allMigrations` entry + inline tests |
| Modify | `src/http_handlers/workspace_delete.zig` | Explicit `DELETE FROM workspace_secrets WHERE workspace_id = ?` (FK cascade is inert) |
| Create | `src/agentic_loop/secrets_store.zig` | CRUD + `listSecretNames` (names only) + `loadSecretValues` (dispatch-only). `workspace_id` is always a `WHERE` parameter. Plaintext `value` column, never selected on a list path. |
| Create | `src/agentic_loop/secrets_substitution.zig` | `substituteToolArguments` (parse → walk → substitute → re-serialize), `redactOutput`, `listNamesForPrompt`. Pure + injectable resolver so tests need no filesystem. |
| Create | `src/agentic_loop/tools_exec_list_secrets.zig` | `execListSecrets` — names only, workspace resolved from `ctx.session_id` |
| Create | `src/modules/agent/tools/list_secrets.zig` | The `AgentTool` schema + description |
| Modify | `src/agentic_loop/tools_equipped.zig` | Registry entry; `list_secrets_tool` into `DEFAULT_AGENT_TOOLS` |
| Modify | `src/agentic_loop/tools.zig` | Re-export `execListSecrets` |
| Modify | `src/agentic_loop/handle_tool.zig` | Call substitution in `dispatchTool` (after pre-hook) **and** the MCP branch; apply `redactOutput` before every `updateAndSendToolResult` |
| Modify | `src/agentic_loop/workflow.zig` | `filterAndMergeTools` appends `list_secrets` server-side (allowlist bypass) |
| Modify | `src/modules/agent/prompts/core.zig` | `SecretsToolRule` — the `{{SECRETS:…}}` syntax + the "never echo a secret" rule |
| Modify | `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig` | Append `SecretsToolRule` with the other unconditional rules |
| Create | `src/http_handlers/secrets_list.zig` | `GET` + private `useCase` + inline tests |
| Create | `src/http_handlers/secrets_create.zig` | `POST` + private `useCase` + inline tests |
| Create | `src/http_handlers/secrets_update.zig` | `PATCH` + private `useCase` + inline tests |
| Create | `src/http_handlers/secrets_delete.zig` | `DELETE` + private `useCase` + inline tests |
| Modify | `src/http_handlers/http_response.zig` | `SecretResponse` (no value field) + `makeSecretListResponse` |
| Modify | `src/http_handlers/mod.zig` | Four re-exports, mirroring `documentsListHandler` at `:171` |
| Modify | `src/main.zig` | Four `try authed.<verb>(…)` routes, literals before `:secret_id` |
| Modify | `src/apps/desktop/src/api/index.ts` | `Secret` interface + four client functions (relative path, no `/api`) |
| Modify | `src/apps/desktop/src/router/index.ts` | `/app/:workspaceId/settings` **above** `/app/:workspaceId` at `:86` |
| Modify | `src/apps/desktop/src/components/AppLayout.vue` | `currentView` branch for the new path |
| Create | `src/apps/desktop/src/components/views/WorkspaceSettingsView.vue` | Workspace-scoped settings page, `?section=`-backed tab |
| Create | `src/apps/desktop/src/components/workspace/SecretsSection.vue` | CRUD list, "configured" state, write-only value input |
| Create | `src/apps/desktop/src/stores/secrets.ts` | Pinia store; `error` is rendered, never write-only |
| Create | `src/apps/desktop/src/__tests__/SecretsSection.spec.ts` | vitest spec incl. the no-value-in-DOM assertion |
| Create | `tests/functional/workspace_secrets_test.py` | Functional tests over the real wire |

---

## Tasks

### Task 1 — Migration 101 + `secrets_store.zig`

- [ ] Write the failing test (in-memory SQLite, the `setupDb` fixture at `migration.zig:3654`): after `Migration101CreateWorkspaceSecrets.up`, `pragma_table_info('workspace_secrets')` contains all 8 columns.
- [ ] Write the failing test: `uq_workspace_secrets_name` rejects a duplicate name in the same workspace but allows the same name in a **different** workspace.
- [ ] Write the failing test: `createSecret` with an empty name returns `error.NameRequired` **before** touching the DB (the empty-slice-binds-as-NULL trap).
- [ ] Write the failing test: `getSecret` with a foreign `workspace_id` returns `error.NotFound`, never another workspace's row.
- [ ] Implement `Migration101CreateWorkspaceSecrets` + its `allMigrations` entry at the array tail.
- [ ] Implement `secrets_store.zig`: `listSecrets`, `getSecret`, `createSecret`, `updateSecret`, `deleteSecret`, `listSecretNames`, `loadSecretValues`. Every one takes `workspace_id` as a positional parameter that appears in the `WHERE` clause — copy the guard style from `documents_store.zig:137`.
- [ ] Write `listSecretNames` to select `name` only. It is the only function the agent path may call.
- [ ] Add the explicit child-delete to `workspace_delete.zig`.
- [ ] Run `zig build test`.
- [ ] Commit: `feat(secrets): migration 101 + workspace-scoped secret store`

### Task 2 — `secrets_substitution.zig`: the boundary (pure, no DB)

- [ ] Write the failing test: `{"command":"curl -H 'Auth: {{SECRETS:GH}}'"}` with `GH=abc` → the string leaf becomes `curl -H 'Auth: abc'`.
- [ ] Write the failing test: a secret whose value is `he said "hi"\n` still yields **parseable** JSON when re-parsed by `std.json.parseFromSlice`.
- [ ] Write the failing test: a secret whose value contains `\` does not produce an invalid escape (`\U`).
- [ ] Write the failing test: `{{SECRETS:NOPE}}` with no resolver hit returns `error.UnknownSecretName` — it does **not** substitute an empty string.
- [ ] Write the failing test: a substituted value containing `{{SECRETS:GH}}` is **not** re-scanned (no recursion).
- [ ] Write the failing test: `redactOutput("curl -H 'Auth: abc' ok", [{GH,"abc"}])` → `curl -H 'Auth: {{SECRETS:GH}}' ok`.
- [ ] Write the failing test: `redactOutput` on output that does not contain the value returns the input unchanged (no spurious allocation churn breaking ownership).
- [ ] Write the failing test: a placeholder inside a **non-string** JSON leaf (e.g. a number) is left alone.
- [ ] Implement `substituteToolArguments(allocator, args_json, resolver) !SubstitutionResult` — parse, walk, substitute, re-serialize. Inject `resolver` as a function pointer so this file needs no DB and no filesystem.
- [ ] Implement `redactOutput(allocator, output, resolved) ![]u8`.
- [ ] Run `zig build test`.
- [ ] Commit: `feat(secrets): JSON-safe placeholder substitution + output redaction`

### Task 3 — Wire both dispatch paths + assert the DB keeps the placeholder

The task that closes the loop. Do not fold it into Task 5.

- [ ] Write the failing test (inline in `handle_tool.zig`, using the `hookDispatchSetup` template at `:1631`): a real in-memory SQLite + a real `ToolContext` + a real `read_file` exec, where the arguments contain a `{{SECRETS:…}}` that resolves — assert the **executor received the real value**.
- [ ] Write the failing test: the same dispatch leaves `llm_history.tool_calls_json` holding `{{SECRETS:…}}`, **not** the value. This is the assertion that pins the Phase-2-before-dispatch ordering as an intentional property.
- [ ] Write the failing test: a tool whose output contains the substituted value has that value redacted out of the persisted result.
- [ ] Call `secrets_substitution.substituteToolArguments` in `dispatchTool` between the pre-hook and the registry walk, resolving `workspace_id` from `ctx.session_id` via `workspace_scope.resolveWorkspaceId`. Return the `UnknownSecretName` error as a `wrapToolOutput` error envelope naming the missing key — never dispatch.
- [ ] Call the same function in the Phase-3 MCP branch before `handle_mcp_tool_run`.
- [ ] Apply `redactOutput` before **every** `updateAndSendToolResult` call site in the Phase-3 loop (there are six: unknown-tool `:739`, MCP short-circuit `:760`, MCP hook error `:778`, MCP result `:785`, dispatch error `:798`, dispatch result `:850`).
- [ ] Add a static-contract test that greps `handle_tool.zig` and asserts the MCP branch contains the substitution call — the shape of the existing tests at `handle_tool.zig:1402`.
- [ ] Run `zig build test`.
- [ ] Commit: `feat(secrets): substitute at dispatch, redact before persist`

### Task 4 — `list_secrets` tool + registry + allowlist bypass + prompt rule

- [ ] Write the failing test: `execListSecrets` with a context whose session resolves to workspace A returns only workspace A's names.
- [ ] Write the failing test: the result string contains no value substring, and the tool's schema JSON contains no `value` key.
- [ ] Write the failing test: a session that resolves to **no** workspace returns an empty list (fail closed, never all workspaces).
- [ ] Write the failing test: `filterAndMergeTools` appends `list_secrets` even when `allowed_tools` is a restrictive CSV that omits it (the `Migration099` lesson).
- [ ] Write the failing test: the appended schema has no `workspace_id` field, so `ignore_unknown_fields` cannot smuggle a foreign id.
- [ ] Implement `list_secrets.zig` + `tools_exec_list_secrets.zig`; register in `UNIFIED_TOOL_REGISTRY`; add to `DEFAULT_AGENT_TOOLS` for new agents.
- [ ] Append `list_secrets_tool` in `filterAndMergeTools` (`workflow.zig:2237`) as a server-side injection bypassing the allowlist, mirroring the `skill_evals` injection documented at `:2243-2250`.
- [ ] Write `SecretsToolRule` in `core.zig`: the syntax, the "call `list_secrets` to discover names" step, and — explicitly — **"never echo, print, or write a secret's value into a file, a commit message, or your own message back to the user"**. A model told it can use a credential will happily `echo` it.
- [ ] Append it with the other unconditional rules at `prompts_build_messages_for_agent_prompt.zig:121-136`.
- [ ] Run `zig build test`.
- [ ] Commit: `feat(secrets): list_secrets tool + prompt rule`

### Task 5 — HTTP handlers + routes

- [ ] Write the failing inline test for each handler's `useCase` against in-memory SQLite (the `documents_*.zig` pattern: private `useCase`, tagged error set, inline `std.testing` tests in the same file).
- [ ] Write the failing test: `useCase` for LIST selects no `value` column — assert the SQL string itself, so a future edit that adds it fails.
- [ ] Write the failing test: a POST with `value: ""` returns 400 `ValueRequired` rather than 500 (the `COALESCE(NULLIF(…))` trap at the HTTP layer).
- [ ] Implement the four handler files with the two-exhaustive-`switch` error mapping.
- [ ] Implement `SecretResponse` + `makeSecretListResponse` in `http_response.zig` with **no value field**, and add a comment saying why (Design Decision 9) so a future edit does not "helpfully" add it back.
- [ ] Add the four `mod.zig` re-exports.
- [ ] Add the four routes to `main.zig`, literals before `:secret_id`, with a comment citing `router.zig:614`.
- [ ] Add static-contract tests grepping `main.zig` for each route literal (the `llmSourceContains` idiom at `mod.zig:927`).
- [ ] Run `zig build test`.
- [ ] Commit: `feat(secrets): workspace-scoped HTTP surface`

### Task 6 — Frontend: API client, store, section, route

- [ ] Write the failing vitest spec: `SecretsSection` renders one row per secret showing only the name and a "configured" state, and `wrapper.html()` contains **no substring of any value** — the direct analogue of `McpServersSection.spec.ts:24-31` and `LlmConfigForm.spec.ts:60-72`.
- [ ] Write the failing vitest spec: the value input is `type="password"` and there is **no** reveal toggle, because there is no stored value to reveal.
- [ ] Write the failing vitest spec: the empty state renders `data-testid="empty-state"`.
- [ ] Write the failing vitest spec: clicking add emits `add`; clicking delete emits `delete` with the name.
- [ ] Write the failing vitest spec: `WorkspaceSettingsView` mount with `?section=secrets` restores that section, and a tab click calls `router.replace` (the URL-sync rule).
- [ ] Add `Secret` + the four client functions to `api/index.ts` (relative path, `encodeURIComponent` per segment).
- [ ] Create `stores/secrets.ts` following `stores/documents.ts:1-30` — no client-side workspace filter, `error` ref that the view **renders**, per the "no try/catch / error must be distinguishable" rule.
- [ ] Create `SecretsSection.vue` (PascalCase, `*Section.vue` suffix, `data-testid` on every control, Tailwind + CSS vars).
- [ ] Register `/app/:workspaceId/settings` **above** `/app/:workspaceId` at `router/index.ts:86`, and add the `currentView` branch in `AppLayout.vue:1133`.
- [ ] Run `npx vue-tsc --noEmit` and `npx vitest --run src/__tests__/SecretsSection.spec.ts`.
- [ ] Commit: `feat(secrets): workspace settings UI (write-only values)`

### Task 7 — Functional tests over the real wire

Unit tests cannot see route-order shadowing or the empty-slice-binds-as-NULL collapse. These must.

- [ ] Write the test: full CRUD round-trip — create a secret, list it (name present, **no `value` anywhere in the response body**), patch the value, delete it.
- [ ] Write the test: **cross-workspace isolation** — workspace B's `GET` returns `count: 0`; workspace B's `GET` of A's secret id returns **404, not 403**.
- [ ] Write the test: create with `value: ""` → 400 (not 500).
- [ ] Write the test: duplicate name in one workspace → 409; same name in a second workspace → 201.
- [ ] Write the test: a `{{SECRETS:UNKNOWN}}` placeholder produces a tool error envelope naming `UNKNOWN` and does not dispatch.
- [ ] Verify the new module is collected by the shard assignment (per CI memory: `select()` is modulo over the whole collected ITEM list, so confirm with a `--collect-only` run rather than assuming).
- [ ] Run the suite via `tests/functional/harness.py`. **Never** `curl` a live server.
- [ ] Commit: `test(secrets): functional coverage for CRUD, isolation, and substitution errors`

### Task 8 — Documentation + PR

- [ ] Add the feature to `docs/superpowers/plans/` index conventions if the repo requires it (check `docs/SPEC.md` — it is a historical inventory, not a live route index, so most likely no edit is needed).
- [ ] Write the PR body: goal, why the three parts are one change, the task table, the leak vectors closed, and the decisions needing a reviewer (1, 2, 5, 9).
- [ ] Run every gate in Global Constraints one final time and paste the output in the PR body.
- [ ] **Do not claim "pre-push passed ⇒ CI green"** — `.husky/_` is uncommitted and absent in fresh worktrees, so the hook silently does not run.
- [ ] Commit: `docs(secrets): PR description + gate output`

---

## Verification

1. **Refactor gate** — after Task 3, confirm the substitution module has **zero** imports of `handle_tool`, `workflow`, or any `http_handlers` file (no import cycles; `tools_exec_document.zig` is the precedent for a leaf exec module).
2. **Leak gate** — `rg -n 'value' src/agentic_loop/secrets_store.zig src/http_handlers/secrets_*.zig` must show every hit on a path that is either a write or the dispatch-only `loadSecretValues`. No list/read path may select it. Assert this mechanically with a source-grep test, not by eye.
3. **Placeholder-persistence gate** — the Task 4 test asserting `tool_calls_json` still holds `{{SECRETS:…}}` is the single most important test in the plan. It is what proves the model never sees the value in history replay.
4. **Redaction gate** — the `shell.zig` echo case gets its own explicit test, because it is the leak that survives if redaction is applied at the wrong layer.
5. **Isolation gate** — cross-workspace reads return 404 and never 403, in both the Zig inline tests and the functional suite.
6. **Cross-platform** — `zig build test` must pass on Linux, macOS and Windows CI; the master-key file write is the only OS-conditional code (`0600` on POSIX, default ACL on Windows).
7. **Full gates** — `zig build test`, `npx vue-tsc --noEmit`, the vitest spec, and the pytest module, all green, output pasted into the PR.

## Out of Scope

- **Env-var injection into spawned processes.** `shell.zig` sets no `env_map` today (`:435`, `:818`); adding `NALAR_SECRET_<NAME>` would put every secret into the environment of every child process, which is a strictly larger blast radius than substitution and is not what the request asked for. `{{SECRETS:…}}` inside a `command` string already covers the `export` case.
- **Role-based secret access (v1).** Membership-only, per reviewer decision 2026-10-03: a `viewer`-role member can rotate any secret in a shared workspace, because `workspaceVisibilityClause` never reads `m.role`. Accepted for v1, consistent with documents. The follow-up is a role predicate in the visibility clause or a `secretsCanBeRead` helper — explicitly NOT a `user_id` column on the row. See Design Decision 11 and Open Question 5.
- **Secret→tool binding / per-tool allowlists** (which tool may read which secret). Natural follow-up; adds a second table and a second policy layer.
- **Redacting the existing config surface.** `GET /api/config/nalar` returns MCP header values and sub-agent `api_key`s in cleartext today (`http_response.zig:365`, `:434`). Pre-existing, different feature — recorded as Design Decision 10, not fixed here.
- **Mobile.** No iOS app exists; Android has no settings screen and no shared codegen.
- **Cross-workspace secret references.** A placeholder resolves only within the calling session's workspace.
- **Secret rotation schedules / expiry / versioning.** A PATCH overwrites.

## Open Questions for the reviewer

1. **Should `list_secrets` really bypass the allowlist?** Design Decision 6 argues yes (the `Migration099` lesson: a tool only new agents have is a tool existing agents never see). The counter-argument is that a user who deliberately unchecked a tool would expect it gone. Your call.
2. **Is an error on an unknown placeholder the right behaviour, or should it substitute empty?** This plan hard-fails with a named error (Decision 8) on the grounds that an empty substitution produces a confusing third-party 401 several steps later. Confirm.
3. ~~**Should a `viewer` be able to rotate a secret?**~~ **CLOSED — deferred by reviewer decision (2026-10-03): membership-only access ships in v1; role-based access is a later, separate change.** `workspaceVisibilityClause` filters on membership only — `m.role` is never read — so every member, including a `viewer`, can read/rotate/delete every secret in a shared workspace. This matches how documents already behave and is **accepted for v1**. It is recorded here rather than deleted so the implementer does not "fix" it with a `user_id` column: when the role work lands, the place to add it is a role predicate in `workspaceVisibilityClause` or a `secretsCanBeRead` sibling — a per-row owner column would answer authorship, not entitlement. See Design Decision 11.
4. **Should the feature ship before the redaction pass is proven?** It must not — redaction is the feature (Decision 5). Flagging because it means Tasks 4 and 8 are not optional follow-ups.
5. **`{{SECRETS:…}}` syntax — is `SECRETS` the right token, and should the `{{ }}` form be reserved?** The `{{ }}` delimiters are also used by `{{name: ""}}` in workflow diagnostics and `{{m,n}}` regex ranges in the search tool's help text (`progressive_catalog.zig:246`). A regex-quantifier false positive is harmless (it is never inside a tool argument), but if you want a distinct delimiter, now is the time.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Shell echo returns the value to the model** — `shell.zig:874-881` puts the substituted command into the result | **Critical** | Task 3's `redactOutput` + Task 4's four call sites + a dedicated test. Without it the feature is worse than useless. |
| Substitution applied at the wrong layer (before Phase 2, or inside the executor) writes the plaintext to `llm_history` | High | Substitute only on `effective_call` inside `dispatchTool`, which is textually after the Phase-2 insert at `:533`. Asserted by the Task 4 test. |
| Only `dispatchTool` is hooked; MCP tools keep the placeholder and fail | High | Second call site in the Phase-3 MCP branch + a static-contract test asserting it is there. |
| Byte-level substitution corrupts JSON when a secret contains `"` / `\` / newline | High | Parse-and-re-serialize (Decision 4); four dedicated tests; `jsonEscapePath` explicitly not reused. |
| The model learns to `echo` a secret it just used | Medium | `SecretsToolRule` states the rule explicitly; redaction is the backstop, the prompt is the primary control. |
| Tool called with a placeholder the user deleted mid-session | Low | Fails closed with a named error; the agent re-calls `list_secrets`. |
| **Any process that can read `agent.db` reads every secret** — and the agent itself can (`command` → `bash -c`, no allowlist; `read_file` has no sandbox). Accepted: identical to today's exposure for `api_key` and MCP headers. Recorded in DD2 and in the Goal line so the plan never overclaims. | Accepted | Documented explicitly in DD2; the substitution-path guarantee (no prompt / no tool arg / no tool result / no history / no SSE) is unchanged and is what Tasks 2, 3 and 7 prove. |
| Existing agents never see `list_secrets` | Low | Server-side injection in `filterAndMergeTools`, bypassing the allowlist. |
| Route-order shadowing breaks `GET /secrets` against a future `/secrets/:secret_id` | Low | Literals registered first + a static-contract test per route. |

---

## Plan saved checklist

- [x] Plan saved to `docs/superpowers/plans/2026-10-02-workspace-secrets.md`
- [x] Header includes Goal, Architecture, Tech Stack, Global Constraints
- [x] Every task has bite-sized steps (write failing test → implement → verify → commit)
- [ ] **User reviewed before execution begins**
