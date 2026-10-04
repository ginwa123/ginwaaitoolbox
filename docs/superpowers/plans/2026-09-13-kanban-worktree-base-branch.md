# Kanban Worktree Base Branch (rev 1)

> **For agentic workers:** this document records a finished change. The TDD loop
> used is `test-driven-development`; the gates that actually ran are listed under
> `## Verification`.

**Goal:** let the kanban "New task" dialog pick a **base ref** (`origin/main`,
`origin/whatever`) when "Use git worktree" is ON, print it into `llm_history`,
and make the agent actually create the worktree from that ref.

**Architecture:**

1. **Frontend owns the choice.** The dialog gains a searchable base-branch
   dropdown under "Worktree path" and bakes the selection into the
   `create_and_run` `queue_message` as a `Base:` line — the same
   no-new-wire-field approach the `#Notes UseGitWorktree` / `Path:` lines
   already use.
2. **A new read-only endpoint feeds the dropdown.**
   `GET /api/git/branches?path=<repo>` shells out to
   `git for-each-ref refs/heads refs/remotes`. This repo has ~770 refs, so a
   hand-typed-only input would be unusable, and a `<select>` of 770 options
   worse.
3. **The agent tool learns the parameter.** `set_git_worktree` gains an optional
   `base` argument forwarded to `git worktree add -b <branch> <path> <base>`.
   Without this the `Base:` line would be inert text the model may ignore —
   the exact failure mode the previous plan's Task 5 called out.
4. **Defaults stay additive.** No base selected ⇒ no `Base:` line ⇒ byte-for-byte
   the pre-change message, and `git worktree add -b <b> <path>` as before.

**Tech Stack:** Zig 0.16 backend (`git_branches_list.zig` handler, `set_git_worktree.zig`
agent tool, `http_response.zig`, `main.zig` route table), Vue 3 + TS frontend
(`KanbanTaskDetailDialog.vue`, `GitBaseBranchSelect.vue`, `KanbanView.vue`,
`buildTaskCreateMessage.ts`, `api/index.ts`), Python functional harness.

## Global Constraints

- `DONT KILL THE PORT 8081 SERVER` — the functional harness picks a random free
  port; no live server + `curl` was used to verify anything.
- No live-server verification: every wire claim below came from the python
  functional harness (real binary, isolated tmpdir `HOME`) or a static-contract
  test.
- No `// NEW (plan: …)` tags in source.
- `zig build test` alone does **not** analyse the HTTP handler bodies (Zig's lazy
  analysis: the handler is only reachable from `main.zig`). The `Base:` change
  hit exactly this trap — see Pitfalls.

## Current State (verified 2026-09-13, first-hand)

| Fact | Evidence |
|---|---|
| Create-task message is built frontend-side for `create_and_run` | `buildTaskCreateMessage.ts:21`, called from `KanbanView.vue:1034` |
| Backend passes `queue_message` through verbatim | `tests/functional/kanban_task_create_message_format_test.py` (existing tests) |
| Worktree path already flows as a `Path:` line | `buildTaskCreateMessage.ts:36` |
| Agent tool creates the worktree, previously always from HEAD | `set_git_worktree.zig:510` (old argv `git worktree add -b <b> <path>`) |
| Route table is a flat list in `main.zig` | `main.zig:561-562` |
| Repo has no branch-listing endpoint | `git_worktree_info.zig` returns only the current branch + a single `default_base` |
| `/home/ginwa/ginwaaitoolbox` is a **bare** repo with 429 remote refs and a symbolic `refs/remotes/origin/HEAD` | `git for-each-ref` probe; `branch --show-current` still prints `main` |
| `%(refname:short)` renders `refs/remotes/origin/HEAD` as just `origin` | probe output — the trap the parser guards against |

## Design Decisions (for reviewer)

1. **New endpoint instead of reusing `git/worktree/info`.**
   Rejected: extend the existing info endpoint with a `branches` array. The info
   endpoint is per-worktree and computes diffs; mixing a repo-wide ref listing
   into it couples two concerns and breaks its caching story. A separate
   read-only `GET /api/git/branches` is ~140 lines with pure, testable helpers.
2. **`Base:` default is empty (follow HEAD), not `origin/main`.**
   Rejected: preselect `origin/main`. The task text says "**if set** that, it
   will be print in llm_history" — a magic default would silently change every
   existing worktree task, and would hard-fail in repos without an `origin`
   remote. The detected default is still hoisted to **row 0** of the dropdown and
   badged `· default`, so choosing `origin/main` is one click.
3. **Search filters a closed list + offers a typed ref.**
   Rejected: free-text-only (unusable with 770 refs), and search-that-only-filters
   (no way to name an unfetched `origin/<branch>`). The typed-but-unlisted row
   (`Use "origin/x"`) is accepted client-side because `set_git_worktree`'s
   `validateBaseRef` is the real gate and its stderr is rewritten into actionable
   advice.
4. **`git fetch` is NOT run before `git worktree add`.**
   Rejected: fetch-then-create. A `git fetch` in a tool call can hang on a slow
   network inside a bounded read. Instead an unresolvable base produces
   `the base ref 'origin/x' could not be resolved … Run `git fetch origin``.
5. **Ref format validation lives in Zig, not only in the dialog.**
   `validateBaseRef` rejects a leading `-` (argv-flag injection), spaces, `~ ^ : ? * [ \`,
   `..`, `//`, `@{`, a trailing `.lock`, `@`, and control characters — git's own
   check-ref-format rules for the cases that otherwise surface as confusing raw
   stderr.
6. **Symbolic HEAD refs are dropped by two independent guards** (non-empty
   `%(symref)`, and a full refname ending in `/HEAD`) so a git build that reports
   the symref column as whitespace cannot leak a bogus branch named `origin`.

## Wire Contract

Message (additive — both lines are optional):

```
Task : <name>
Description: <desc>

#Notes UseGitWorktree
Path: <abs worktree path>
Base: <base ref>        <- only when the toggle is ON and a ref was picked
```

`GET /api/git/branches?path=<absolute repo path>` →

```json
{
  "is_git_repo": true,
  "current_branch": "main",
  "branches": [
    { "name": "origin/main",    "is_remote": true,  "is_current": false, "is_default": true },
    { "name": "origin/dev",     "is_remote": true,  "is_current": false, "is_default": false },
    { "name": "main",           "is_remote": false, "is_current": true,  "is_default": false }
  ]
}
```

Ordering: detected default first, then remote-tracking refs, then local branches
(git emits refnames lexicographically, so each group is already alphabetical).
`400` for a missing / relative / `-`-prefixed / `..`-bearing path, `404` when the
path is not a git repo.

`set_git_worktree` tool: new optional `base` string property. Success XML gains
`<base>…</base>` only when a base was used.

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/http_handlers/git_branches_list.zig` | add | Endpoint + pure helpers (`validateRepoPath`, `parseRefRows`, `pickDefaultRef`, `orderRefs`) + tests |
| `src/http_handlers/http_response.zig` | edit | `GitBranchEntry`, `GitBranchesResponse`, `makeGitBranchesResponse` |
| `src/http_handlers/mod.zig` | edit | Export the handler |
| `src/ai_workflow/tui/test_runner.zig` | edit | Register the new file's inline tests |
| `src/main.zig` | edit | `GET /api/git/branches` route |
| `src/modules/agent/tools/set_git_worktree.zig` | edit | `base` input + schema + prompt, `validateBaseRef`, `buildWorktreeAddArgv`, `base`-aware stderr rewrite, `<base>` in success XML |
| `src/modules/agent/tools/set_git_worktree_test.zig` | edit | New signature call sites + base/argv/validation tests |
| `src/apps/desktop/src/api/index.ts` | edit | `listGitBranches()` (never throws) |
| `src/apps/desktop/src/components/kanban/GitBaseBranchSelect.vue` | add | Searchable dropdown (lazy load, ↑/↓/Enter/Escape, click-outside, typed-ref fallback) |
| `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | edit | Worktree-block mount + `worktreeBaseBranch` state/emits/reset |
| `src/apps/desktop/src/components/kanban/buildTaskCreateMessage.ts` | edit | `Base:` line |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | edit | Thread `worktreeBaseBranch` into the message builder |
| `src/apps/desktop/src/__tests__/GitBaseBranchSelect.spec.ts` | add | 18 component tests |
| `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.useGitWorktree.spec.ts` | edit | Base-branch emit + reset tests |
| `src/apps/desktop/src/__tests__/{buildTaskCreateMessage,KanbanTaskDetailDialog,KanbanTaskDetailDialog.runAgent}.spec.ts` | edit | `Base:` cases + `worktreeBaseBranch` in exact-payload assertions |
| `tests/functional/kanban_task_create_message_format_test.py` | edit | `Base:` wire case + `GET /api/git/branches` live tests |

## Verification (actual results, 2026-09-13)

| Gate | Command | Result |
|---|---|---|
| Zig unit/inline | `zig build test --summary all` | **3294 passed / 8 skipped / 3302 total**, exit 0 |
| Frontend unit | `pnpm exec vitest run` (in `src/apps/desktop`) | **3086 passed**, 4 failed — all 4 reproduced identically on the untouched main repo (`FilePickerDialog.windows`, `WorkspaceItemHideTasksForDesign`, `workspacesStoreNormalizeTaskDates`, `workspacesStoreNormalizeTaskImageUrls`) |
| Frontend build | `pnpm run build` | exit 0 (`vue-tsc` + `vite build`) |
| Functional (wire) | `PABRIK_BIN=…/zig-out/bin/pabrik pytest tests/functional/kanban_task_create_message_format_test.py -v` | **11 passed** — includes `Base: origin/main` in the drained `llm_history` row, the no-base regression shape, and 4 live `GET /api/git/branches` cases (order, dropped `origin` symbolic ref, 404, 400) |

## Out of Scope

- Per-task persistence of the chosen base (it is a create-time input, like the
  worktree path).
- Editing the base of an existing worktree.
- Running `git fetch` on the user's behalf (decision 4).

## Risks

- A worktree created from a **stale** `origin/main` is possible by design; the
  stub LLM/profile never fetches. The tool's error text names `git fetch origin`
  when the ref is missing, which is the common case.
- The dropdown lists every ref, which for very large repos is a long payload
  (~770 rows ≈ tens of KB). Bounded by `for-each-ref` output, no history fetched.

## Pitfalls hit (worth remembering)

1. **`zig build test` does not analyse HTTP handler bodies.** The handler's
   `catch |err| switch (err)` needed an `else` arm for the inferred
   `error.OutOfMemory`; only `zig build install` surfaced it. Always run the
   install/build gate after adding a handler.
2. **`%(refname:short)` collapses `refs/remotes/origin/HEAD` to `origin`** —
   filtering on the short name is wrong; filter the full refname / `%(symref)`.
3. **`noUncheckedIndexedAccess` is on** in the desktop tsconfig: `arr[i].field`
   needs a guard (`const x = i >= 0 ? arr[i] : undefined`).
