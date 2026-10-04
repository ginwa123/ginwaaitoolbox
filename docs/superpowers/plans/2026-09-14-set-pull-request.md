# set_pull_request agent tool + session.pr_url + PR-changes in ChatView right panel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new agent tool `set_pull_request` attaches a pull/merge-request URL to the current session (persisted in new `sessions.pr_url` + `sessions.pr_provider` columns, multi-provider: GitHub, GitLab, generic). Once set, the ChatView right panel switches to **PR mode** and shows all file changes of that PR (read-only), instead of the working-tree changes.

**Why this shape:** mirrors the proven `set_git_worktree` → `sessions.git_worktree_cwd` → `effectiveCwd` → sidebar chain (Migration 046, `tools_exec_set_git_worktree.zig:49-68`, `llm_history.updateSessionGitWorktreeCwd`). Every layer below is a copy of that precedent with `pr_url` substituted — low design risk. Provider support is a small strategy layer because PR creation today is GitHub-only (`gh` CLI in `git_pr_create.zig`) and there are **zero** `glab`/GitLab/Gitea references in `src/`.

**Spec:** this document IS the spec (kanban card `rightsidebar inside chatview component`, planning review 2026-09-14).

**Worktree:** `/home/ginwa/.config/pabrik/.worktrees/set-pull-request-plan-1789416600000` on branch `worktree/set-pull-request-plan-1789416600000`.

**Base:** `origin/main` (post-#495 squash `eb56dd05`, post-#500 rebase).

---

## 0. Current state (verified 2026-09-14, sub-agent survey)

| Area | File | State |
|---|---|---|
| Tool definition pattern | `src/modules/agent/tools/set_git_worktree.zig` (input struct L11-38, `AgentTool` schema L62-107, pure validators, `execute*ToString`, `<worktree>` XML envelopes L891-940) | Template for the new tool. Schema types in `schemas.zig:32-58`. |
| Tool registration | `src/agentic_loop/tools_equipped.zig` (`equips()` L60 LLM-visible list + `UNIFIED_TOOL_REGISTRY()` L143 dispatch) + `src/agentic_loop/tools.zig` re-export hub (L17-50) + `ToolExecContext` (L77, already carries `allocator/db/session_id/cwd`) | New tool needs 3 touch points + 1 new `tools_exec_set_pull_request.zig` adapter (4-step shape: parse JSON → execute → `<error>` detect → `wrapToolOutput`). |
| Tool→DB write pattern | `tools_exec_set_git_worktree.zig:50-65` extracts `<path>` from tool XML → `llm_history.updateSessionGitWorktreeCwd` (`llm_history.zig:3591`, `UPDATE sessions SET git_worktree_cwd = ? …` + `onEventSendSessions(action="updated")` broadcast) | Exact template for `updateSessionPrUrl`. |
| Sessions schema | `src/migrations/migration.zig` single file, versions 1–85 (latest 085). `git_worktree_cwd TEXT` added by Migration 046 (`:856-871`); current convention is idempotent `addColumnIfMissing` (`:1643-1680`, used by 063/077/082) | `pr_url` = Migration **086** via `addColumnIfMissing`. |
| Session model/CRUD | `src/models/session.zig:17-45` struct, `SessionTableInfo` + `getSession()` (`llm_history.zig:3075-3225`, `COALESCE` SELECT), `SessionBroadcastInfo` (`:104-119`) + `on_event_sent.zig:120-135,399` | All need a `pr_url` field threaded through. |
| Session wire (frontend reads) | `GET /api/llm/session/:id/messages` → `sessionMessagesHandler` (`session_messages_get.zig:11`, routes `main.zig:435,458`) → `SessionMessagesResponse` (`http_response.zig:258-280`, has `git_worktree_cwd`) → populated from `SessionMessageResponse` (`llm_history.zig:541-551`, `COALESCE(s.git_worktree_cwd,'')` at `:637,656`) | `pr_url` rides the same response. NOTE: the session-*list* endpoint (`session_list.zig:106`, `SessionInfo` `llm_history.zig:16-56`) does **not** carry `git_worktree_cwd` either — list support is optional (see open questions). |
| PR creation today | `src/http_handlers/git_pr_create.zig` spawns `gh pr create --base --title --body` in worktree (`POST /api/git/pr`, route `main.zig:563`), `CreatePrDialog.vue` frontend | GitHub-only. No glab/vendor CLIs. |
| Worktree info | `GET /api/git/worktree/info` (`git_worktree_info.zig`, route `main.zig:561`): branch, last commit, `default_base` (origin/main→master→develop→main), commits_ahead, diff_summary via git CLI | Precedent for git-CLI-in-handler use cases. |
| Right panel | `SidebarDiffPanel.vue` (props `{cwd}`, emits `submit-review/refresh`, REST `getGitChanges/getGitFileDiff/stage/unstage`), `ChatRightSidebar.vue` shell, `ChatView` passes `effectiveCwd` + `refreshWorktreeBinding()` via `getChatHistory(limit=1)` (reads `git_worktree_cwd`) | Panel needs a PR mode driven by a new `prUrl` prop. Shared `parseUnifiedDiff` parser exists but **skips** `diff --git` headers — needs a `splitDiffByFile()` addition. |

---

## Global Constraints

- **Cross-platform**: any Zig touch MUST verify `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc` + `-target aarch64-macos -lc`. New subprocess spawns (`gh`/`glab`/`git`) must use the `std.process.run` + bounded 64KB pipe pattern from `git_pr_create.zig` / `set_git_worktree.zig:160-190`, and `.cwd` MUST be a `process.Child.Cwd` tagged union (never null).
- **No `// NEW (plan: ...)` tags** in source. Explain *why*, not *when*.
- **No port 8081**: functional tests boot isolated binary via `tests/functional/harness.py` (free port 8080..8199, tmpdir HOME). Never `nohup ... --port 8080` + curl.
- **Behavioural tests only** (frontend): Vitest `@vue/test-utils` `mount` + `setActivePinia(createPinia())`; ChatView-source assertions use the static-contract grep pattern (`ChatView.worktreeSidebar.spec.ts` precedent). Zig: colocated unit tests following the validator-test pattern.
- **TDD discipline**: failing test → minimal code → commit, per task.
- **No ChatView.vue bloat**: ChatView edits limited to wiring (pass `prUrl`, extend `refreshWorktreeBinding`). Panel logic lives in `chat_right_sidebar/`. Tracked `.vue` edits MUST go through python patching, not `text_replace` (it reformats whole files).
- **Secrets**: never log tokens/URLs with embedded credentials; strip `https://<token>@` before logging/persisting (normalize on write).

---

## 1. Design decisions (locked)

1. **Tool semantics = attach only (confirmed 2026-09-14).** `set_pull_request` takes an *existing* PR/MR URL and binds it to the session (mirrors `set_git_worktree` attach semantics). Creation stays in `gh pr create` / `CreatePrDialog` — no create strategy in this plan. Params: `pr_url` (required), `provider?` (`github|gitlab|generic`, default auto-detect), `base?`/`head?` (generic-forge fallback only), `clear?` (unbind, mirrors worktree `clear`), `verify?` (default true — see 3).
2. **Schema = two columns.** `sessions.pr_url TEXT` + `sessions.pr_provider TEXT` (nullable, `""` = unset). The tool stores the *effective* provider at write time (explicit override, else auto-detected) — reads stay deterministic. Rationale: host-based detection fails on self-hosted forges (GitHub Enterprise on a custom domain looks `generic`; a self-hosted GitLab without the `/-/merge_requests/` path is ambiguous), so re-deriving on every read would misroute. The endpoint still re-derives from the URL as a fallback when `pr_provider` is empty (old rows). PR number stays derived (never stored).
3. **Verify is best-effort.** `verify=true` runs the provider CLI `view` command (`gh pr view <url> --json number,baseRefName,headRefName` / `glab mr view <url>`). CLI missing → persist anyway with `<warning>cli-not-found</warning>` in the envelope (degraded, panel will error later with guidance). CLI present + PR not found/auth fail → `<error>`, do NOT persist.
4. **One diff endpoint, full text.** `GET /api/git/pr/diff?path=&pr_url=` returns the *whole* unified diff; the frontend splits per file with a new pure `splitDiffByFile()` and reuses `parseUnifiedDiff` per file. Avoids N+1 requests and reuses the tested parser.
5. **Provider strategy (backend, in endpoint + tool verify):**
   - `github` (host `github.com` or `gh` override): `gh pr diff <url> --repo <owner/repo>` (auth via gh); fallback pure-git `git fetch origin pull/<N>/head` + `git diff <base>...FETCH_HEAD` when `gh` is absent but remote creds work.
   - `gitlab` (host `gitlab.*` or `glab` override, incl. self-hosted): `glab mr diff <url>`; fallback `git fetch origin merge-requests/<IID>/head` + `git diff <base>...FETCH_HEAD`.
   - `generic` (anything else, or explicit): requires `base`/`head` (from tool params, else endpoint query overrides, else `default_base` auto-detect from `git_worktree_info` logic + current branch) → pure `git diff base...head`. No forge CLI needed — this is also what makes the feature testable without network.
6. **Panel is read-only in PR mode.** No stage/unstage buttons, no context menu (hunks belong to the PR, not the worktree). Mini-chat review stays (it only sends a chat message). Header shows `🔀 PR #N` + clickable URL + base…head + refresh.
7. **URL normalization on write.** Strip credentials, trailing `/files`/`/commits` suffixes, force canonical form (`https://host/owner/repo/pull/N`). What the tool persists is what the panel parses — one normalizer shared by tool + endpoint.

---

## 2. File map

| File | Action | Why |
|---|---|---|
| `src/migrations/migration.zig` | EDIT | Migration 086 `pr_url TEXT` + `pr_provider TEXT` via `addColumnIfMissing` + registry entry in `allMigrations` |
| `src/models/session.zig` | EDIT | `pr_url: ?[]u8 = null` + init/clone/deinit |
| `src/agentic_loop/llm_history.zig` | EDIT | `SessionTableInfo` + `getSession` SELECT (`COALESCE(s.pr_url,'')`, `COALESCE(s.pr_provider,'')`) + `SessionMessageResponse` + `getSessionMessagesSorted` select + `SessionBroadcastInfo` + new `updateSessionPrUrl(url, provider)` (+ SSE `action="updated"`) |
| `src/http_handlers/http_response.zig` | EDIT | `SessionMessagesResponse.pr_url` + `makeSessionMessagesResponse` |
| `src/http_handlers/session_messages_get.zig` | EDIT | Pass through `pr_url` (mirrors `git_worktree_cwd` line) |
| `src/modules/agent/tools/set_pull_request.zig` | NEW | Input struct, `AgentTool` schema, URL normalize/validate, provider detect, verify via CLI, `<pull_request>` XML envelopes |
| `src/agentic_loop/tools_exec_set_pull_request.zig` | NEW | 4-step adapter + persist via `updateSessionPrUrl` (log-but-don't-fail on DB error, worktree precedent) |
| `src/agentic_loop/tools_equipped.zig` | EDIT | `equips()` + `UNIFIED_TOOL_REGISTRY()` entries |
| `src/agentic_loop/tools.zig` | EDIT | `execSetPullRequest` re-export |
| `src/modules/agent/tools/pr_provider.zig` | NEW | Shared: `detectProvider(url)`, `parsePrRef(url)` (provider/owner/repo/number), `normalizePrUrl`, strategy fns used by BOTH tool-verify and diff endpoint (no duplication) |
| `src/http_handlers/git_pr_diff.zig` | NEW | `GET /api/git/pr/diff?path=&pr_url=[&base=][&head=]` → full unified diff text via provider strategy |
| `src/main.zig` | EDIT | Route registration (`:563` area) |
| `src/apps/desktop/src/api/index.ts` | EDIT | `SessionMessagesResponse.pr_url`, `getPrDiff(cwd, prUrl)` client, `GitPrDiff` type |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT (small) | Extend `refreshWorktreeBinding` to also assign `prUrl`; pass `:pr-url` to sidebar |
| `src/apps/desktop/src/components/views/chat_right_sidebar/parseUnifiedDiff.ts` | EDIT | Add pure `splitDiffByFile(diffText)` → `{file, status, hunksText}[]` |
| `src/apps/desktop/src/components/views/chat_right_sidebar/SidebarDiffPanel.vue` | EDIT | PR mode: `prUrl` prop, file list from split diff, read-only rows, PR header; worktree mode unchanged when empty |
| `src/apps/desktop/src/components/views/__tests__/ChatView.prSidebar.spec.ts` | NEW | Static-contract: prUrl wiring, refresh extension |
| `src/apps/desktop/src/components/views/__tests__/SidebarDiffPanel.pr.spec.ts` | NEW | Behavioural: PR mode renders files/diff, no stage buttons, error state |
| `src/apps/desktop/src/components/views/__tests__/splitDiffByFile.spec.ts` | NEW | Parser: multi-file split, renames, new/deleted files |
| `tests/functional/session_pr_url_test.py` | NEW | Migration + wire: pr_url in messages response; generic-mode PR diff on fixture repo (no network) |

---

## 3. Phases

### Phase 0 — Column + plumbing (no behaviour change)
- [ ] Task 0.1: Migration 086 (`addColumnIfMissing(sessions, pr_url, TEXT)`) + registry entry. Zig migration test (apply on scratch DB, assert column exists).
- [ ] Task 0.2: Thread `pr_url` + `pr_provider` through `models/session.zig`, `SessionTableInfo`, `getSession` SELECT, `SessionMessageResponse`, `SessionBroadcastInfo`, `updateSessionPrUrl(url, provider)` (+ SSE broadcast mirroring worktree setter). `http_response` + `session_messages_get` passthrough. Frontend `api/index.ts` types only.
- [ ] Task 0.3: Functional `session_pr_url_test.py` (red): harness boot → messages response contains `pr_url: ""` + `pr_provider: ""` defaults on old session; direct `UPDATE sessions SET pr_url, pr_provider` → response reflects both. (Tool/endpoint land later; this proves the columns + wire.)

### Phase 1 — set_pull_request tool
- [ ] Task 1.1: `pr_provider.zig` pure core + unit tests: `normalizePrUrl` (strip creds/suffixes), `detectProvider` (github/gitlab/generic), `parsePrRef` (owner/repo/number or MR iid) for github + gitlab URL shapes (incl. `/-/merge_requests/`).
- [ ] Task 1.2: `set_pull_request.zig` (schema, validators, verify via `gh`/`glab` view, `<pull_request>` envelopes with `<url>/<provider>/<number>/<verified>` + `<warning>`/`<error>`).
- [ ] Task 1.3: `tools_exec_set_pull_request.zig` + registration (`tools_equipped`, `tools.zig`) + persist URL + effective provider via `updateSessionPrUrl` (clear→both null). Zig test: exec persists both + broadcasts (mock db like worktree exec test).
- [ ] Task 1.4: Manual QA matrix (requires auth): `gh` present/absent × github URL valid/invalid; `glab` × gitlab URL; generic URL + base/head. Record results in PR description.

### Phase 2 — PR diff endpoint
- [ ] Task 2.1: `git_pr_diff.zig` (`GET /api/git/pr/diff`): normalize → provider = stored `pr_provider` when the session has one (endpoint reads it via the same session lookup), else re-derive from URL → strategy (gh / glab / pure-git fetch+diff / generic base...head), bounded 1MB diff cap, error mapping (not-a-repo→404, CLI-missing→422 with install hint, PR-not-found/auth→502 with provider message). Route in `main.zig`.
- [ ] Task 2.2: Functional generic-mode test (no network): fixture repo with `main` + feature branch, `pr_url=https://git.example.com/o/r/pull/1` + `base=main&head=<branch>` → diff contains expected hunks; unknown file/branch → clean error JSON (covers empty-slice-NULL + validator wire modes).

### Phase 3 — Panel PR mode (frontend)
- [ ] Task 3.1: `splitDiffByFile()` + spec (multi-file, `new file mode`, `deleted file mode`, renames `a/ b/`).
- [ ] Task 3.2: `SidebarDiffPanel.vue` PR mode: `prUrl` prop → `getPrDiff` on mount/cwd/prUrl change; header `🔀 #N + link + base…head`; single file list (status from split); click → inline diff via existing renderer; NO stage/unstage buttons; error → Retry; empty prUrl → today's worktree mode untouched. Behavioural spec with mocked api.
- [ ] Task 3.3: ChatView wiring (python-patched): `prUrl` ref, extend `refreshWorktreeBinding` (`if (data.pr_url !== undefined)`), pass `:pr-url`, sidebar refresh already re-syncs (no change needed). Static-contract spec.
- [ ] Task 3.4: `vue-tsc --build` + full views/git vitest sweep (tool-width failure pre-exists on main — verify no NEW failures).

### Phase 4 — Docs + follow-ups (explicitly out of scope)
- [ ] Task 4.1: Update `CreatePrDialog` success path? Currently the dialog only opens the URL. Setting `sessions.pr_url` from the dialog needs a writer (tool-only today) — record as follow-up, do NOT build a REST setter in this plan (keeps write-path single-owner: the agent tool).
- [ ] Task 4.2: Session-list endpoint `pr_url` (mirrors the `git_worktree_cwd` gap) — follow-up if a list UI needs it.

---

## 4. Tests

| Layer | File | What it proves |
|---|---|---|
| Zig migration | `migration.zig` inline test | 086 applies, `pr_url` exists, idempotent re-run |
| Zig unit | `pr_provider.zig` tests | normalize/detect/parse across github/gitlab/self-hosted/generic URLs, cred stripping |
| Zig unit | `set_pull_request.zig` tests | validators reject bad URL/unknown provider; envelopes well-formed |
| Zig exec | `tools_exec_set_pull_request` test | success persists pr_url + broadcasts; clear nulls it; DB error logged not raised |
| Vitest | `splitDiffByFile.spec.ts` | multi-file/rename/new/deleted splits |
| Vitest | `SidebarDiffPanel.pr.spec.ts` | PR mode list+diff, no stage buttons, retry on error, worktree mode unchanged when empty |
| Vitest | `ChatView.prSidebar.spec.ts` | prUrl prop passed, refresh extension present |
| Functional | `session_pr_url_test.py` | column defaults + wire passthrough (url + provider) + generic-mode diff on fixture repo (no network) |
| Manual | QA matrix | gh/glab present/absent × valid/invalid URLs (auth-required, recorded in PR) |
| Typecheck | `vue-tsc --build` + zig cross-compile checks | no regressions |

---

## 5. Risks / open questions (for human review)

1. ~~Attach-only vs create?~~ Answered 2026-09-14: **attach-only**, no create strategy.
2. **REST setter for pr_url?** Only the agent tool writes today (single owner, like `git_worktree_cwd`). `CreatePrDialog` won't auto-bind the session — follow-up if wanted.
3. **Session-list `pr_url`?** Same gap as `git_worktree_cwd` (list endpoint lacks it). Needed only if a non-ChatView UI shows PR state — confirm not needed.
4. **glab availability?** `gh` is already assumed on PATH; `glab` becomes a second soft dependency (degraded mode when absent). Acceptable, or vendor both?
5. **Diff size cap?** 1MB cap proposed; huge PRs truncate with a `<truncated>` marker — acceptable for a review sidebar?
6. **Auth for private repos?** Relies on `gh`/`glab` auth state on the host (same as `gh pr create` today). No token handling in pabrik — confirm.
