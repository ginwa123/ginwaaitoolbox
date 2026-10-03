# PR / MR conflict → show *which files* conflict

> **For agentic workers:** implement task-by-task with `subagent-driven-development`;
> do not batch Task 1–3 into one edit. Each task ends in its own `Commit:`.

**Goal:** When a pull/merge request is in a merge-conflict state, the right
sidebar must name **the files that conflict** — today it only shows a red
`⚠ Merge conflicts` badge plus a generic "use the web editor" banner, so the
user has to leave the app to find out which of the 11 changed files is the
problem.

**Architecture:**

1. A new read-only endpoint `GET /api/git/pr/conflicts` computes the conflicting
   path list **locally** with `git merge-tree --write-tree --name-only
   <base> <head>`. No forge CLI, no network, no auth.
2. The desktop PR tab calls it **only while the forge already reports a
   conflict** (`mergeable=CONFLICTING` / `merge_state=DIRTY` / GitLab
   `conflicted` / `not_mergeable`), preserving the existing
   quiet-when-clean contract: a clean PR costs zero extra spawns and renders
   byte-identically to today.
3. On a conflict the panel renders a **Conflicting files (N)** section above
   the PR file list, a **⚠ Conflicts only** filter toggle (URL-synced as
   `?panel=pr&conflicts=1`), and a count in the header badge. Clicking a
   conflicting file that is also in the PR diff selects it in the centre
   column, exactly like a normal PR file row.

**Tech Stack:** Zig 0.16 (`gserverz` HTTP handlers, `helpers.run_captured`),
Vue 3 + TypeScript (Pinia-free, `api/index.ts` thin client), Vitest +
`@vue/test-utils`, pytest functional harness (`tests/functional/harness.py`).

---

## Global Constraints

- **Never bind or kill port 8081.** Any manual server use goes on 8080+.
- **No live-server `curl`.** HTTP behaviour is proven with
  `tests/functional/` (boots a fresh binary on a free 8080–8199 port with an
  isolated tmpdir `HOME`). Unit/spec tests never substitute for it.
- **All child processes go through `helpers.run_captured`** — never
  `std.process.spawn` + `Child.wait` in a handler
  (`src/helpers/run_captured.zig:1-50` documents three production crashes that
  this prevents, and `git_pr_status.zig:1692` asserts the rule).
- **No `// NEW (plan: …)` tags** in source.
- **`vue-tsc --build` emits stray `.js`** next to `.ts` sources when
  `noEmit` is off — delete them before committing.
- **URL rule:** any new view/filter state is read back on mount and written
  with `router.replace`. No local-only `ref` for view state.
- **Verification gate before claiming done:** `zig build test`,
  `cd src/apps/desktop && pnpm vitest run <specs> && pnpm run build`, and the
  new pytest file.

---

## Current State (verified 2026-10-03)

| Fact | Where |
|---|---|
| Conflict flag is a `computed` over `mergeable` + `merge_state` | `src/apps/desktop/src/components/views/chat_right_sidebar/SidebarDiffPanel.vue:130-145` |
| Header badge `⚠ Merge conflicts` | `SidebarDiffPanel.vue:791-797` |
| Banner `⚠ This branch has conflicts…` | `SidebarDiffPanel.vue:938-956` |
| Conflict badge link = `<pr-url>/conflicts` (GitHub only) | `SidebarDiffPanel.vue:147`, `helpers/forgeWording.ts` |
| PR file list rows | `SidebarDiffPanel.vue:1000-1024` |
| PR load = `loadPrDiff` + `loadPrStatus`, both on tab load | `SidebarDiffPanel.vue:262-334`, `:509-513` |
| 30 s poll of `loadPrStatus` only | `SidebarDiffPanel.vue:655-659` |
| Existing conflict spec (4 cases) | `src/apps/desktop/src/components/views/__tests__/SidebarDiffPanel.prConflict.spec.ts` |
| Backend PR status handler (gh/glab via `run_captured`) | `src/http_handlers/git_pr_status.zig:629` |
| `GitPrStatusResponse` wire struct | `src/http_handlers/http_response.zig:744-771` |
| Routes `/api/git/pr/status`, `/api/git/pr/diff` | `src/main.zig:699-700` |
| Handler exports block | `src/http_handlers/mod.zig:300-301` |
| TS thin client `getPrDiff` / `getPrStatus` | `src/apps/desktop/src/api/index.ts:4873-4933` |
| GitLab conflict vocabulary handled (`conflicted`, `not_mergeable`) | `SidebarDiffPanel.vue:143-144` |

### The load-bearing discovery

**Neither forge's API lists conflicting files.**

- GitHub REST `GET /repos/{o}/{r}/pulls/{n}/files` → every changed file.
- GitHub GraphQL `PullRequest` → no conflicting-files field.
- GitLab `GET /projects/:id/merge_requests/:iid` → `changes` is the MR diff.

GitHub's web "Resolve conflicts" tab computes the list **server-side with a
three-way merge**. So must we — locally, which is cheaper and works for both
forges and for self-hosted GitLab.

### `git merge-tree` output contract (verified on git 2.55.0)

```
$ git merge-tree -z --write-tree --name-only <base> <head>
<tree-OID>\0<path>\0<path>\0\0<informational messages…>
exit 0 → clean, exit 1 → conflicts, other → failure
```

Proven twice:

- synthetic repo, both branches editing line 2 of `shared.txt`
  → `shared.txt`, exit 1;
- **live PR #784** (`mergeable=CONFLICTING`, `merge_stateStatus=DIRTY`, 11
  changed files) → exactly `tests/functional/default_tools.py`, exit 1 —
  matching GitHub's own count of 1 conflicting file.

With `-z` the record separator is NUL, so a path containing a newline cannot
desync the parser; the informational section is separated from the conflict
section by an **empty record**, which is the stop condition.

---

## Design Decisions (for reviewer)

1. **Compute conflicts locally with `git merge-tree`, not from the forge.**
   *Rejected:* deriving the list from the PR diff + status (no such data
   exists), or asking `gh`/`glab` (they cannot answer it either).
2. **Separate `GET /api/git/pr/conflicts`, not a new field on `/status`.**
   `/status` is polled every 30 s; `merge-tree` on a big repo is not free.
   A separate route means zero cost when there is no conflict and lets the
   frontend load it lazily off the badge.
3. **Resolve the base ref from local refs only — never `git fetch`.**
   Probe order `refs/remotes/origin/<base>` → `<base>` → the
   `main`/`master`/`develop` fallback ladder. *Rejected:* fetching on open.
   A panel that mutates refs, hits the network, and can block on a credential
   prompt is worse than a stale answer; and when the ref is genuinely missing
   the endpoint says so (`BaseRefNotFound` → 422, "run `git fetch`") instead of
   lying. The response echoes `base_ref` + `base_commit` so the answer is
   self-describing about which commits it used.
4. **Head = the local worktree's `HEAD`, overridable via `?head=`.**
   The panel is bound to the PR's own worktree, so "what would conflict if I
   merged what I have right now" is the actionable answer, and it stays
   correct while the user is mid-resolution.
5. **When the forge says CONFLICTING but the local merge is clean, render
   "could not reproduce locally", never an empty list.** An empty list next
   to a red badge reads as "nothing to do".
6. **Filter toggle is URL state (`?conflicts=1`)** alongside the existing
   `?panel=`. Reusing the query object rather than inventing a second
   mechanism satisfies the repo's view-in-URL rule.
7. **`-z` + `MAX_CONFLICT_FILES = 500`.** Bounded parse and bounded payload;
   `truncated` says so rather than silently dropping paths.

---

## Wire Contract

### Request

```
GET /api/git/pr/conflicts?path=<cwd>&pr_url=<url>[&provider=github|gitlab|generic][&base=][&head=]
```

`base`/`head` are optional ref overrides; both default to local resolution.

### Response — 200

```json
{
  "pr_url": "https://github.com/ginwa123/ginwaaitoolbox/pull/784",
  "base": "main",
  "base_ref": "refs/remotes/origin/main",
  "base_commit": "fb7b2dc4…",
  "head": "HEAD",
  "conflicting_files": ["tests/functional/default_tools.py"],
  "count": 1,
  "truncated": false
}
```

An empty `conflicting_files` with `"truncated": false` is a **valid** answer:
it means "your local merge of these two refs is clean".

### Error responses

| Status | `error` | Cause |
|---|---|---|
| 400 | `Missing path parameter` | no `path` |
| 400 | `Missing pr_url parameter` / `pr_url cannot be empty` | no PR |
| 400 | `provider must be "github", "gitlab", or "generic"` | bad provider |
| 404 | `not a git repository` | `path` is not a work tree |
| 422 | `could not resolve the base branch <base> locally — run \`git fetch\` and retry` | no local base ref |
| 502 | `git merge-tree failed: <stderr, capped>` | git errored / unsupported flag |

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/http_handlers/git_pr_conflicts.zig` | **new** | `useCase` (resolve refs, run `merge-tree`, parse `-z` output), handler, static wiring tests, synthetic-repo integration tests |
| `src/http_handlers/mod.zig` | edit | `pub const gitPrConflictsHandler` |
| `src/main.zig` | edit | `try authed.get("/api/git/pr/conflicts", …)` after the `/diff` route |
| `src/http_handlers/http_response.zig` | edit | `GitPrConflictsResponse` + `makeGitPrConflictsResponse` |
| `src/apps/desktop/src/api/index.ts` | edit | `GitPrConflicts` interface + `getPrConflicts()` |
| `SidebarDiffPanel.vue` | edit | conflict-file list, filter toggle, badge count, `loadPrConflicts()` |
| `src/apps/desktop/src/components/views/__tests__/SidebarDiffPanel.prConflict.spec.ts` | edit | new cases for the list + filter |
| `tests/functional/git_pr_conflicts_test.py` | **new** | wire-level proof against a real conflicting work tree |

---

## Tasks

### Task 1 — backend handler

- [ ] `src/http_handlers/git_pr_conflicts.zig`:
  - `runGit(allocator, io, path, args, timeout_ms) !GitRun` wrapping
    `run_captured.run`; map `FileNotFound`/timeout to `GitMissing`.
  - `refExists(…)` via `git rev-parse --verify --quiet <ref>^{commit}`.
  - `resolveBaseRef(…)` — override or the `origin/{main,master,develop}` then
    `{main,master,develop}` ladder.
  - `parseConflictPaths(allocator, stdout) !struct { files: [][]const u8, truncated: bool }`
    — NUL-split, skip record 0, stop at the first empty record, cap at 500.
  - `useCase(...)` — gate on `rev-parse --git-dir`, resolve base + head,
    resolve `base_commit`, run
    `merge-tree -z --write-tree --name-only <base_ref> <head>`; exit 0 → clean,
    1 → parsed list, anything else → `MergeTreeFailed` with capped stderr.
  - `gitPrConflictsHandler` mapping errors to the status codes above.
- [ ] Static wiring tests (mirroring `git_pr_diff.zig:325-340`): exported from
  `mod.zig`, route registered in `main.zig`, and **does not call
  `std.process.spawn`**.
- [ ] `Commit:` `feat(git): name the conflicting files behind a PR conflict badge`

### Task 2 — HTTP client

- [ ] `api/index.ts`: `GitPrConflicts` + `getPrConflicts(cwd, prUrl, opts)`,
  `silent: true` (the panel renders its own inline error).
- [ ] `Commit:` folded into Task 3's commit.

### Task 3 — frontend

- [ ] `loadPrConflicts()` in `SidebarDiffPanel.vue`, guarded by
  `hasPrConflict`, with a `prConflictSeq` stale-response guard mirroring
  `prSeq`; clears on `prUrl`/`cwd` change and when the PR is clean.
- [ ] `conflictsOnly` filter, read from `route.query.conflicts` on mount and
  written with `syncTabParam`-style `router.replace`.
- [ ] Template: `Conflicting files (N)` section with
  `data-testid="sidebar-pr-conflict-files"`, per-row
  `sidebar-pr-conflict-file-<path>`, a `data-testid="sidebar-pr-conflicts-only"`
  toggle, and `{{ conflictingFiles.length }}` in the header badge.
- [ ] "Could not reproduce locally" state when the forge says conflict and the
  endpoint returned zero.
- [ ] Clicking a conflicting row that is in `prFiles` calls `selectPrFile`;
  otherwise it opens the file in the code editor tab.
- [ ] `Commit:` `feat(desktop): list the files behind a PR merge conflict`

### Task 4 — Zig tests

- [ ] Build a synthetic repo in `std.testing.tmpDir`, branch, edit the same
  line on both sides, assert `useCase` returns exactly the conflicted path.
- [ ] Clean-merge repo → `conflicting_files.len == 0`.
- [ ] `parseConflictPaths` unit tests: empty output, cap + `truncated`,
  informational section ignored, path containing a space.
- [ ] `Commit:` with Task 1.

### Task 5 — vitest

- [ ] `SidebarDiffPanel.prConflict.spec.ts`: mock `getPrConflicts`; assert the
  list renders, the badge carries the count, quiet when the endpoint is not
  called (mergeable PR), the "could not reproduce" state, and the filter
  toggle round-tripping `?conflicts=1`.
- [ ] `Commit:` with Task 3.

### Task 6 — functional test

- [ ] `tests/functional/git_pr_conflicts_test.py`: create a repo with a real
  conflicting branch through the harness, call the route, assert the JSON
  names the file and that `count` matches.
- [ ] `Commit:` with Task 6.

---

## Verification — run 2026-10-03

- [x] `zig build test` — 4335/4345 pass, 10 skipped, 0 failed, 0 leaks.
- [x] `pnpm vitest run src/components/views/__tests__/SidebarDiffPanel.prConflict.spec.ts`
      — 14/14. Two mutations prove the load-bearing ones fail without the code
      under test: dropping the `hasPrConflict` guard fails *"never calls the
      conflicts endpoint when the PR is mergeable"*; forcing
      `prConflictUnreproduced` to `false` fails *"says \"could not reproduce\""*.
- [x] `pnpm run build` (`vue-tsc --build` + `vite build`) — clean.
- [x] `pytest tests/functional/git_pr_conflicts_test.py -v` — 4/4 against the
      real binary on an isolated port + tmpdir HOME.
- [x] Whole-suite check: 248/250 in `src/components/views/__tests__/`. The two
      failures (`ChatView.tool-width`, `SidebarDiffPanel.tabs` "without prUrl
      the header toggle") are **pre-existing on the base branch** — reproduced
      with this change stashed.
- [ ] Manual sanity: attach a PR that is `CONFLICTING`, confirm the badge
      shows `⚠ Merge conflicts (N)` and the section lists the same N files GitHub
      does.

## Out of Scope

- Resolving conflicts in-app (writing conflict markers, staging resolutions).
- Per-hunk conflict detail — `merge-tree` can print markers, but a file list is
  the ask.
- Surfacing the conflict list on the task cards / chat list rows
  (`prStatusCache.ts` option B from the wireframe).

## Open Questions for the reviewer

1. **Local-vs-forge divergence.** If `origin/main` is stale the list can
   disagree with GitHub. We render "could not reproduce locally" rather than a
   false empty list; a `git fetch` button on that line would fix it — wanted?
2. **Non-`origin` remotes.** Resolution only probes `origin` then bare names.
   A self-hosted GitLab under `upstream` needs `?base=refs/remotes/upstream/main`.
   Should the ladder enumerate all remotes instead?

## Risks

| Risk | Mitigation |
|---|---|
| `git` < 2.38 (no `--write-tree`) | detected as a non-0/1 exit → 502 with git's own stderr; badge + web link unaffected |
| Huge conflict sets | capped at 500 with `truncated` |
| Base ref missing locally | 422 with the exact `git fetch` hint |
| Panel now spawns git on every conflicted PR | one `merge-tree` + ≤3 `rev-parse`, 20 s cap, `run_captured` kills the process group |
