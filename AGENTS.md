
#Mandatory
DONT KILL THE PORT 8081 SERVER,
for testing use another port like 8080

## Verification — Always Use Functional Tests, Never a Live Server

When verifying HTTP behavior (route order, wire payloads, error messages, JSON
serialization, authentication), do NOT spin up a live `nalar` binary and `curl`
it. Three recurring failure modes only surface from a real wire round-trip and
NONE of them are visible from unit tests:

1. **Route-order shadowing** — `matchRoute` walks routes in registration order
   (see `kabelweb repo src/server/router.zig:182`), so a literal
   `/foo/reorder` registered AFTER `/foo/:bar` is captured with `bar="reorder"`.
   Unit tests on the useCase don't exercise routing.
2. **Empty-slice-as-NULL binding** — `SqliteBackend.exec` binds `""` slices as
   SQL NULL, which violates `NOT NULL` columns (precedent: Migration 079's
   `content` column). Unit tests that pass `""` directly to a SQLite column via
   `INSERT VALUES ('')` work, but PATCH flows that pass `""` through
   `useCase` don't — the bind collapses to NULL mid-execution.
3. **Strict validators treating `""` as a value** — `std.fs.path.isAbsolute("")`
   is false, so an empty `file_path` from an "atomic mode switch" payload fails
   validation. Unit tests usually pass a non-empty path; the empty case is only
   exercised by the frontend's real wire body.

**What to do instead — write an isolated functional test** that boots a fresh
`nalar` binary against an isolated tmpdir HOME per test, then replays the EXACT
JSON body the frontend sends:

```python
# tests/functional/agent_knowledge_edit_test.py — PR #291 follow-up
def test_text_mode_save_clears_file_path_and_sets_content(harness):
    """The edit dialog's Text-mode save sends {label, content, file_path:""}."""
    ws = _create_workspace(harness)
    agent = _create_agent(harness, ws)
    row = _add_file_knowledge(harness, agent)
    updated = _patch(harness, agent, row["id"], {
        "label": "Switched to text",
        "content": "inline body after switch",
        "file_path": "",
    })
    assert updated["file_path"] == ""
    assert updated["content"] == "inline body after switch"
```

The harness at `tests/functional/harness.py` does all the heavy lifting:
- Picks a free port in 8080..8199 (excluding 8081 — see the mandatory note above).
- Sets `HOME` to an isolated tmpdir (`/tmp/nalar-func-<uuid>/`) — the harness's
  `is_safe_tmp()` validator gates every `rmtree` so your real `$HOME` is never
  touched (see `tests/functional/README.md` ⛔ section).
- Tears down the binary + tmpdir on test exit (even on assert-fail).
- Runs `zig-out/bin/nalarcore-linux-x86_64` (or whatever `$NALAR_BIN` points at).

For static checks (route order, function signatures, error mappings), prefer a
Zig static-contract test in the same file as the impl (`<feature>_test.zig`
inline with `pub const` exports + greps). For Zig-only behavior, an in-memory
SQLite test in the same `useCase` file is enough — but for any HTTP route or
wire payload, ALWAYS graduate to the python functional harness.

**Anti-pattern: `nohup ./zig-out/bin/nalar... --port 8080` + `curl`.** Leaks the
process across tool calls, conflicts with the harness, and is exactly what
missed the bugs in PR #291.



**Concrete example** (task_1786507100896, PR #215): backend's `onEventSendSessions` had an `event_type_name` if/else that knew about `created` and `deleted` and fell through to `session_unknown` for everything else. `action="updated"` (the most common case — fired by the auto-rename-on-first-message cascade in `workflow.zig` and the unattended toggle in `llm_history.zig`) reached the wire as `event: session_unknown`, which the frontend's `additionalEventTypes` didn't pre-register. The browser silently dropped it. Sidebar task rows kept showing "New Chat" until a manual page refresh.

## Code Exploration with Graphify — graph-first, grep-second

> **Audience:** any AI agent (Claude, GPT, sub-agent, future-me) that writes,
> edits, reviews, or tests code in this repo. Humans may also find it useful.
>
> **Authority:** this file is loaded automatically by every agent at session
> start. Treat the rules below as non-negotiable. If a rule conflicts with a
> specific task, surface the conflict to the user before acting.

Before exploring or making changes in an unfamiliar module, query the knowledge
graph instead of manually grepping. Graphify combines Tree-sitter static
analysis with LLM-driven semantic extraction into `graphify-out/` (`graph.json`
+ interactive `graph.html` + `GRAPH_REPORT.md`). It only sends semantic
descriptions to the model — never raw source code.

### 0. Freshness check (do this first — graph goes stale fast)

```bash
stat -c '%y %n' graphify-out/graph.json  # if >1 day old, refresh:
graphify update .                        # re-extract, no LLM needed, fast
```

- `graph.json` older than ~1 day → run `graphify update .` before trusting
  query results (this repo moves fast — 9k+ nodes, 600+ communities).
- Missing `graphify-out/` entirely → full build (slow, LLM-backed) is needed;
  ask the user before running it.
- Never hand-edit `graph.json` / `.graphify_labels.json` — they are generated.

### 1. MCP tools (preferred — you already have these connected)

| Goal | Tool | Example |
|---|---|---|
| Project overview | `mcp_graphify_graph_stats` | node/edge/community counts + confidence |
| Find core abstractions | `mcp_graphify_god_nodes` (`top_n: 10`) | hubs like `vue`, `useWorkspacesStore`, `FunctionalHarness` |
| Ask a question | `mcp_graphify_query_graph` (`mode: bfs`, `depth: 2-3`, `token_budget: 4000-6000`) | `"agentic loop workflow tools execution"` |
| Node detail | `mcp_graphify_get_node` (`label: "Agent"`) | file, location, community |
| What depends on X | `mcp_graphify_get_neighbors` (`label: "useWorkspacesStore"`) | callers + callees with edge types |
| Whole subsystem | `mcp_graphify_get_community` (`community_id: N`) | all nodes in one cluster |
| How A reaches B | `mcp_graphify_shortest_path` (`source`, `target`, `max_hops`) | e.g. `ChatView.vue` → `workflow.zig` |
| PR review | `mcp_graphify_list_prs` / `get_pr_impact` / `triage_prs` | blast radius before merging |

Always pass `project_path: /home/ginwa/ginwaaitoolbox` (or the worktree path)
so queries hit the right `graphify-out/graph.json`.

### 2. CLI fallback (shell / sub-agents without MCP)

- `graphify query "<question>" --budget 4000` (add `--dfs` to trace one path)
- `graphify god-nodes --top 10`
- `graphify path "A" "B"` / `graphify explain "X"` / `graphify affected "X" --depth 2`

### 3. Recommended workflow

1. `graph_stats` → scale check (2026-09-03 refresh: ~14.9k nodes / ~22k edges / ~906 communities).
2. `god_nodes` → orient (frontend: `vue`/`useWorkspacesStore`; backend:
   `Agent` in `src/modules/agent/Agent.zig`, `workflow.zig` + `tools.zig` in
   `src/ai_workflow/tui/agentic_loop/`; DB: `migration.zig` + `SqliteBackend`;
   tests: `FunctionalHarness` in `tests/functional/harness.py`).
3. `query_graph` BFS depth 2–3 with a focused keyword set per layer
   (backend: `agentic loop tools execution`; frontend: `ChatView kanban sidebar`;
   DB: `sqlite migration llm_history sessions`). One broad query returns README
   noise — split by layer.
4. `get_node` / `get_neighbors` on the hits that matter, then `read_file` at the
   cited `src=… loc=L…` to confirm (graph snippets are ~100 chars — never quote
   them as source).
5. Before refactoring: `shortest_path` (blast radius) + `affected` (reverse deps).

### 4. Pitfalls

- **Truncated BFS is normal.** Large queries return `TRUNCATED: showing 130/1000
  nodes` — raise `token_budget` or narrow with `context_filter: ["call"]` /
  a specific `get_node` instead of re-asking broadly.
- **Stale graph lies.** A month-old `graph.json` misses new `tools_exec_*.zig`
  files and renamed Vue components. Check `stat` first (see §0).
- **Community IDs are unstable** across rebuilds — cite node labels + file paths,
  not `community=N`, in plans and PR descriptions.
- **MCP `project_path` matters in worktrees.** In a git worktree, point it at
  the worktree root so you query the worktree's `graphify-out/`, not main's.


## Code Comments — No `// NEW (plan: ...)` Tags

Do NOT annotate new code with `// NEW (plan: YYYY-MM-DD-<slug>)` (or
`<!-- NEW (plan: ...) -->` in templates). The repo's history already
carries a few of these from older work — do not add more, and strip
any you just introduced before committing.

Why: the tag states *when* code landed, never *why* it exists. `git
blame` + the plan doc already answer "when"; the comment should
answer "why" in one plain sentence, or not exist at all.

- ❌ `// NEW (plan: 2026-09-11-foo). Mirror of handleSave's X — see ...`
- ✅ `// Mirror of handleSave's X (baked into queue_message).`
- ✅ No comment at all when the code is self-evident (`useGitWorktree:
  useGitWorktree.value` needs no annotation).

Plan-doc references belong in the plan file and the PR description —
not inline in source.


## Frontend — Every View Switch Must Update the Browser URL

Any in-app navigation — tab switches, view toggles, dialog opens that
represent a distinct view — MUST sync to the browser URL (route path or
query param, e.g. `?panel=files|pr|commits` in `SidebarDiffPanel.vue`
via `readTabParam`/`syncTabParam` + `router.replace`). A view that only
lives in component state is unreachable by refresh, Back/Forward, and
shared links.

Why: the commits tab first shipped as a local `showCommits` boolean —
switching Files → Commits left the URL unchanged, so refresh lost the
view and Back/Forward skipped it. The fix folded the tab into the
existing `?panel=` param so mount restores it.

- ✅ New tab/toggle reuses the view's existing URL param (extend the
  union, don't invent a second param).
- ✅ Mount reads the param back (deep-linkable); clicks write it
  (`router.replace`, not `push`, for tab switches).
- ✅ Cover with a spec: click asserts the query value, mount-with-query
  asserts the restored view (see `SidebarDiffPanel.tabs.spec.ts`).
- ❌ Local-only `ref` booleans for view state in routed components.


## Frontend — Banned Code in Vue/TS (the `useEffect` ban)

`src/apps/desktop/` enforces the Vue/TS analogue of React's **"You Might Not
Need an Effect"** doctrine. The bans are LINT RULES, not advice — the full
table, the React→Vue mapping, and the "what is NOT banned" list live in
**`docs/vue-ts-banned-code.md`**. Read that before arguing with a lint error.

| Rule | Bans | Fix |
|---|---|---|
| `local/no-watch-effect` | `watchEffect()` — implicit deps | `watch(src, cb)`, or `computed()` |
| `local/no-derived-state-watch` | a `watch` whose body only assigns computable state | `computed()`, or `toRef()` |
| `local/no-silent-fallback-catch` | a `catch` that returns `[]`/`null`/`''` with no log, no error ref, no comment | put the failure in the type (`sync/runtime.ts`) |
| `@typescript-eslint/ban-ts-comment` | `@ts-ignore`, `@ts-nocheck` | fix the type; `@ts-expect-error -- reason` is allowed |
| `@typescript-eslint/no-explicit-any` | bare `any` | narrow it, or add an inline `--reason` disable |

**`watch(() => props.id, () => load())` is ALLOWED** — it is the legitimate
`useEffect` equivalent and the dominant idiom here (46 of 103 real call
sites). The derived-state rule requires the callback body to contain **no
call at all** before it fires. Do not "fix" a lint error by rewriting a real
side-effect watcher as `computed`; that deletes the behaviour.

The two ratcheted rules are pinned by `src/apps/desktop/eslint-suppressions.json`
(113 sites). Fixing a site is good; adding one turns CI red. Regenerate with
`pnpm run lint:banned-baseline` **only after** fixing debt — never to silence
a new violation. Note that `--suppress-rule` records only `error`-severity
violations, so those rules must stay at `error`; softening one to `warn`
silently disables its baseline.

`src/__tests__/bannedCodeRules.spec.ts` pins both directions (that each ban
fires, and that the legitimate shapes stay silent). If you change a rule,
run it.


## Frontend — No `try`/`catch` in the desktop app; use Effect-TS

New frontend code in `src/apps/desktop/` MUST express fallibility in the
**type**, not in a `try`/`catch` block. `src/apps/desktop/src/sync/` is the
reference implementation; the `effect` package is already a dependency.

**Why — this is not a style preference, it is a correctness rule.**
`SyncError.ts` says it outright: before Effect, *"a backend outage, a corrupt
IndexedDB database and a legitimately empty result all reached the UI as the
same value. The engine's callers could not tell 'there is nothing new' from
'we could not check'."*

PR #719 is that exact bug, live, in the chatview:

```ts
// ❌ The catch swallows the failure into a plausible-looking success.
try {
  const data = await api.getChatHistory(sid, PAGE_SIZE, undefined)
  messages.value = data.messages
} catch {
  return { messages: [], has_more: false, next_cursor: null, skills: [] }
}
```

`getChatHistory` returned `messages: []` on transport failure *and* on a real
empty session, so `error` stayed `null`, and the empty state's
`v-if="!isLoading && !error && messages.length === 0"` was true. A slow
backend rendered **"How can I help you?"** for sessions full of messages. The
`chat-load-error` block and its Retry button were **dead code** — the only
route to them was a `catch` around a function that could never throw.

### The rules

- **A fallible operation returns `Effect<A, E>`, not a promise that may reject
  and not a promise that may return a fake empty.** Declare the failure as a
  tagged error (`Data.TaggedError`), as `sync/SyncError.ts` does.
- **The caller picks the policy, and the policy is visible in the type.** Do
  not hard-code "degrade to empty" inside the API layer — that is the move
  that caused the bug. Offer both a rejecting variant and an explicitly
  named best-effort wrapper, and make call sites say which one they want.
- **Reuse the existing seam.** `runSyncEffect` / `runSyncEffectOr` /
  `runSyncVoid` (`sync/runtime.ts`) are the Vue-`<script setup>` bridge: they
  run an `Effect`, log the squashed cause in dev, and degrade to a value the
  caller named. `Effect.runPromise(Effect.exit(effect))` + `Exit.isSuccess` is
  the shape to copy for a new seam.
- **Reserve `try`/`catch` for the genuinely exceptional**: a Vue event handler
  that must not reject, a `finally` that releases a resource, or a parser
  around untrusted input. Even there, say in a comment why the failure cannot
  be handled by the type.
- **Never let a caught error disappear into a value the UI cannot
  distinguish from a legitimate answer.** If a fallback value is returned,
  the reason must still reach a log or a ref.

### Checklist before you commit frontend code

- [ ] Did I add a `try`/`catch`? Can the failure live in the error channel instead?
- [ ] Does any "empty" value get returned on the failure path? If so, is
      "empty" still distinguishable from "unavailable" downstream?
- [ ] Is any `error` ref effectively **write-only** (set, never rendered)?
      That is the fingerprint of a swallowed failure.
- [ ] Does the spec prove the failure path? A test that only seeds the happy
      path will pass on code that has this bug.

Repo-specific notes: `scrollLogger.*({ reason })` takes a closed `ScrollReason`
union (a retry is not a scroll reason — use `console.warn`); `oxlint`'s
`no-useless-catch` rejects a `catch (e) { throw e }` wrapper; and prettier
wraps long `v-if` expressions across lines, so source-contract regexes must be
whitespace-tolerant. See
`.nalar/skills/chatview-empty-state-gate/SKILL.MD` for a worked example.


