# Read Workspace Session Card Implementation Plan (rev 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `read_workspace_session` tool card legible and actionable — real timestamps, working match highlights, hits grouped by conversation, visible role facets, openable rows, and the `full_contents` it already fetches.

**Architecture:** Two independent halves that meet at the JSON wire. (1) **Backend, one line of SQL** — `searchMessagesFts` selects `created_at_nano` aliased to `created_at`; switch it to `created_iso`, which the table already stores and which the tool's own `since`/`until` filters *already compare against*. (2) **Frontend, one component** — `ReadWorkspaceSession.vue` keeps its shape, header, and role badges; gains bare-bracket snippet parsing, session grouping, a role-facet footer, row→session navigation, and a `full_contents` pane. No migration, no schema change, no new endpoint.

**Tech Stack:** Zig 0.16 + SQLite FTS5; Vue 3 + TypeScript + Tailwind v4 under `src/apps/desktop/`; Vitest + `@vue/test-utils`.

## Global Constraints

- **Never kill or bind port 8081.** It is another agent's server. The functional harness picks a free port in 8080–8199 excluding 8081.
- **No live-server curl.** Verify HTTP/wire behaviour with `tests/functional/harness.py` (boots a fresh binary against an isolated `HOME` tmpdir). Do not `nohup ./zig-out/bin/... &` — that leaks a process across tool calls.
- **Impl + tests in ONE file** (repo convention, reinforced 2026-09-30). No new `*_test.zig`.
- **No `// NEW (plan: …)` tags** anywhere, including inside this plan's code snippets.
- **Empty slice binds as SQL NULL** in `SqliteBackend.exec` — a `""` through a `NOT NULL` column fails. Relevant if any new query binds a possibly-empty filter.
- **Zig must compile for Linux + macOS + Windows.** Use the compile-only cross-check before declaring done.
- **`vue-tsc --build` emits stray `.js`** next to `.ts` sources here. Delete them before committing.
- **Worktrees need `node_modules` symlinked** from the main checkout or vitest cannot resolve.
- **Keep `.chat-tool-card` invariants** — `ChatView.tool-width.spec.ts` regex-asserts `width:100%`, `min-width:0`, and `.chat-tool-card pre { max-width:100%; overflow-x:auto }`.
- **New `ToolCardHeader`-based cards must mount `<ToolParameters>`** — `ChatView.tool-parameters.spec.ts:48` asserts the card name is in the stub list.
- **Cross-platform**: no `std.os.linux`-only API in shared code paths.

## Current State (verified 2026-09-30 in this worktree, first-hand)

### The four defects

| # | Defect | Evidence |
|---|-------|----------|
| ① | `created_at` is a **nanosecond epoch**, not a timestamp | `llm_history.zig:2458` → `COALESCE(h.created_at_nano, '') AS created_at`. Real value from the live DB: `"1790706338823948836"`. |
| ② | Match highlight **can never fire** | Backend `llm_history.zig:2454` → `snippet(messages_fts, 0, '[', ']', '...', 10)` emits bare brackets (`[portal]`). `parseSnippet` (`ReadWorkspaceSession.vue:371`) recognises only `[match]`/`[/match]`. Ran the shipped parser against a real snippet → **zero** match segments. |
| ③ | **88% of hits are machine noise** | Measured on the screenshot's own query: `tool` 19,775 / `assistant` 2,568 / `user` 236. FTS indexes `response_content`, which for a tool row is the whole JSON envelope. |
| ④ | `full_contents` **returned, never rendered** | `full_contents` appears **0×** in `ReadWorkspaceSession.vue`. |

### `created_iso` is already there — and already the filter key

`llm_history` has both columns. `created_iso` is written on insert via
`helpers.currentTimeIsoLocal(allocator, io)` (`llm_history.zig:1529`, `:3282`) and holds
`"2026-09-30 19:53:35"`.

**The tool already filters on `created_iso`** (`llm_history.zig:2508`, `:2513`):
```zig
if (opts.since) |s| { try sql.appendSlice(allocator, " AND h.created_iso >= ?"); ... }
if (opts.until) |u| { try sql.appendSlice(allocator, " AND h.created_iso <= ?"); ... }
```
Its public contract already says `since`/`until` are `"YYYY-MM-DD HH:MM:SS"`. So today's tool
**accepts an ISO date and returns an epoch** — the fix removes an inconsistency, it does not invent a format.

### Blast radius of the ① fix — verified, it is one caller

`searchMessagesFts` has **exactly one** production caller:
`read_workspace_session.zig:506`. Everything else is tests (`llm_history.zig:9182`+).

The four other `created_at_nano AS created_at` sites — `:775`, `:794`, `:827`, `:846` — are a
**different function** (`getSessionMessages`, feeding `SessionMessage` for the chat transcript, where
the value is used as a sort key and by other consumers). **Do not touch them.** They are listed here
only so a future reader does not "fix" them by grep.

### The snippet parser, verbatim (`ReadWorkspaceSession.vue:371`)

```ts
function parseSnippet(snippet: string): { text: string; match: boolean }[] {
```
It walks `[`…`]` and only emits `{match:true}` when the inner text is exactly `match` or `/match`.
A real snippet `...a [portal] that refuses...` yields three `{match:false}` chunks — the brackets
render as literal text. The specs **pass today only because their fixtures hand-write `[match]`**,
a format the backend has never emitted.

### Wire shape today (`read_workspace_session.zig`)

| Behaviour | Discriminator | Array key | Entry keys |
|---|---|---|---|
| LIST | `behavior:"list"` | `sessions` | `id name status message_count last_activity preview` |
| SEARCH / SEARCH-WITHIN | `behavior:"search"\|"search-within"` | `results` (+`full_contents`) | `id session_id session_name role created_at snippet` |
| READ | `behavior:"read"` | `message_index` | `id role created_at preview tool_call_id tool_name content content_truncated` |

**Absent everywhere:** `hint`, `has_more`, `truncated`/`TRUNCATED`, `returned`, `is_error`.
`session_id` + `session_name` are already on **every** search hit → grouping needs **no wire change**.

### Existing tests

- Zig: 10 inline tests, `read_workspace_session.zig:988–1327`, in-memory SQLite (`setupDb` at `:893`).
  **No test asserts the output shape** — SEARCH asserts only `id` via `hasResultId` (`:884`).
- Frontend: `ReadWorkspaceSession.spec.ts` (14 `it()`s, fixtures at `:29–155`),
  `.emptyArgs.spec.ts`, `.inprogress.spec.ts`.
- Functional: `tests/functional/agent_workspace_history_test.py` — registry naming + enable/disable only.
  Its own docstring (`:11–15`) says the tool itself is covered by the Zig tests.

### Rendering seam (`ChatView.vue:4874`)

```vue
<ReadWorkspaceSession
  v-else-if="msg.tool_name === 'read_workspace_session'"
  :content="innerToolData(msg)"
  :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
  :parameters="getParametersForMessage(msg)"
/>
```
`innerToolData` (`ChatView.vue:1772`) hands the card the **unwrapped `data`** object.

## Design Decisions (for reviewer)

1. **Fix ① in SQL, not in the UI.** Alternative: format the epoch client-side. Rejected — it would
   need the nanosecond→date conversion in TS, and `created_iso` is already stored *and already the
   key `since`/`until` compare against*. Selecting it makes the output match the tool's own documented
   input format. One line, one caller.

2. **Fix ② in the UI, not in SQL.** Alternative: change `snippet()`'s delimiters to `[match]`. Rejected —
   it alters an FTS expression shared with anything else querying `messages_fts`, and a "match" literal
   inside message text would then be mis-rendered. Bracket-parsing is 4 lines in one component.

3. **Grouping is client-side.** `session_id` is already on every hit. Sorting + grouping in the card
   avoids a second SQL query and a wire change. Sorted by `created_at` desc within session, sessions
   ordered by their best hit.

4. **Facets are display-only + a "copy as tool call" escape hatch.** The card cannot re-run the tool
   (it has no execute path), so clicking a facet must not pretend to filter server-side. It copies
   `{"query": "...", "role": "user"}` to the clipboard — the agent pastes it as the next call.

5. **Navigation is a router push in ChatView, not inside the card.** Cards stay presentation-only;
   `ChatView` owns routing (its own header docstring at `:173` says exactly this). Precedent:
   `SpawnSubAgent` emits `@peek` → `nav.openPeek` (`ChatView.vue:4965`).

6. **Row height unchanged.** A hit that is scannable should not cost more vertical space than one
   that is not. Same `text-meta` snippet line, same badge.

7. **Fixture repair is part of the ② fix.** Update the spec fixtures to bare brackets *and* add a
   test with a real backend snippet. Otherwise the suite keeps asserting a format nobody produces.

## Wire Contract

**Change ① — one line, `llm_history.zig:2458`:**
```zig
// before
        COALESCE(h.created_at_nano, '') AS created_at,
// after  — created_iso is 'YYYY-MM-DD HH:MM:SS'; fall back to nano only
//          for pre-migration rows that predate the column.
        COALESCE(NULLIF(h.created_iso, ''), h.created_at_nano, '') AS created_at,
```
`SearchHit.created_at` (`:1971`) stays `[]const u8`; its `deinit` is unaffected.
`JsonHit.created_at` (`:550`) stays `?[]const u8`; `:583` already maps `""` → `null`.

No change to: `JsonHit`, `JsonFull`, `JsonEntry`, the `behavior` discriminator, or any array key.

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/agentic_loop/llm_history.zig` | modify | Emit `created_iso` as `created_at` on the FTS path (`:2458`). Add a Zig test asserting an ISO-shaped value. |
| `src/apps/desktop/src/components/tool_outputs/ReadWorkspaceSession.vue` | modify | Fix `parseSnippet`; group hits by session; add role facets; make rows openable; render `full_contents`; emit `openSession`. |
| `src/apps/desktop/src/components/tool_outputs/__tests__/ReadWorkspaceSession.spec.ts` | modify | Repair fixtures to bare-bracket reality; add tests for highlight, grouping, facets, full_contents, navigation emit. |
| `src/apps/desktop/src/components/views/ChatView.vue` | modify | Handle `@openSession` → `router.replace` with the canonical path URL. |
| `tests/functional/agent_workspace_history_test.py` | modify | One wire-shape assertion that `created_at` is not a raw nano epoch. |
| `docs/superpowers/specs/2026-09-30-read-workspace-session-card-wireframe.html` | (already committed) | The design this plan implements. |

## Tasks

### Task 1 — Backend: emit a readable `created_at` on the FTS path

- [ ] Add a failing test in `llm_history.zig`'s existing test block: insert a row, run `searchMessagesFts`, assert `hits[0].created_at` matches `^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$` (and is NOT a bare integer).
- [ ] Run `zig build test` filtered to that name; confirm it fails with the current `created_at_nano` value.
- [ ] Apply the `COALESCE(NULLIF(...))` change at `:2458` only. **Do not touch `:775`, `:794`, `:827`, `:846`.**
- [ ] Re-run the test; confirm green.
- [ ] Run the full `llm_history.zig` test set — the FTS sanitization tests (`:9190`+) must still pass.
- [ ] `Commit:` `fix(llm_history): emit created_iso as FTS search created_at`

### Task 2 — Frontend: fix `parseSnippet` to match the backend

- [ ] Update the spec fixtures in `ReadWorkspaceSession.spec.ts` (`:29–155`) to use **bare brackets** as the backend emits. Add a fixture with a verbatim real snippet: `...error: 'linux.file [dialog].test.a [portal] that refuses the...`
- [ ] Add a failing test asserting that fixture renders `<mark>` around `dialog` and `portal` (not around the brackets).
- [ ] Rewrite `parseSnippet` (`ReadWorkspaceSession.vue:371`) to treat `[`…`]` as a match. Keep the `[match]`/`[/match]` branch as a tolerated input so any older persisted transcript still highlights.
- [ ] Ensure a nested `[` (e.g. `[xdg-[portal]`) does not swallow content — take the **first** `]` and keep scanning.
- [ ] Run the spec; confirm green, including the pre-existing `[match]` fixture if kept.
- [ ] `Commit:` `fix(read-workspace-session): parse bare-bracket FTS snippets`

### Task 3 — Frontend: group search hits by session

- [ ] Add a failing test: two hits in `session_A`, one in `session_B` → exactly 2 group headers, in best-hit order, with hit counts.
- [ ] Add a `groupedResults` computed: sort hits by `created_at` desc (ISO sorts lexicographically — **the ① fix is what makes this correct**), group by `session_id`, order groups by their newest hit.
- [ ] Render a group header row: `session_name` (fall back `session_id`), hit count, newest relative age.
- [ ] Keep the existing per-hit anatomy inside each group — role badge, id, highlight, snippet. Same row height.
- [ ] Null-safety: hits with no `session_id` group under an unnamed bucket rather than throwing.
- [ ] Run the spec; confirm the existing per-entry testids (`search-entry-role-*`, `-id-*`, `-snippet-*`) still resolve — **keep those ids or update the tests that assert them**.
- [ ] `Commit:` `feat(read-workspace-session): group search hits by session`

### Task 4 — Frontend: role facets footer

- [ ] Add a failing test: a footer listing each role present in the page with its count.
- [ ] Compute counts **from the current page's hits only**, and label the footer as such — do not present page counts as total counts (`total_count` is a page-independent SQL total; the role split is not available without a new query, which is out of scope).
- [ ] Each facet copies `{"query": <query>, "role": <role>}` to the clipboard on click, and shows a "copied" confirmation.
- [ ] Style as a footer strip inside the entries pane, using the existing dim-text/violet-active idiom.
- [ ] Run the spec; confirm green.
- [ ] `Commit:` `feat(read-workspace-session): add role facet footer`

### Task 5 — Frontend: make rows and session headers openable

- [ ] Add a failing test: clicking a session header calls `wrapper.emitted('openSession')` with that `session_id`.
- [ ] `defineEmits<{ openSession: [sessionId: string] }>()` on the card.
- [ ] Emit from the group header; add a quiet `open` affordance on hover, matching the `⎘` copy-button idiom (opacity 0 → 1 on row hover).
- [ ] Keep the hit-row click → `openSession(session_id)` too.
- [ ] Run the spec; confirm green.
- [ ] `Commit:` `feat(read-workspace-session): emit openSession from rows`

### Task 6 — Frontend: render `full_contents`

- [ ] Add a failing test: content containing `full_contents: [{ id, session_id, role, content, content_truncated }]` renders the body with the existing `content-toggle` idiom and shows `(truncated)` when `content_truncated` is true.
- [ ] Render `full_contents` as a collapsible pane below the hit it belongs to (match on `id`).
- [ ] Absent / null `full_contents` → nothing rendered (today's behaviour stays).
- [ ] Run the spec; confirm green.
- [ ] `Commit:` `feat(read-workspace-session): render full_contents`

### Task 7 — ChatView wiring for `openSession`

- [ ] Add `@open-session="onOpenWorkspaceSession"` to the `ReadWorkspaceSession` usage at `ChatView.vue:4874`.
- [ ] Implement `onOpenWorkspaceSession(sessionId)` alongside `onPeekOpenFull` (`:806`): resolve the current workspace and `router.replace` with `buildAppUrl({ workspaceId, chatSessionId })` (`helpers/appUrl.ts:11` → `/app/{ws}/chat/{sessionId}`).
- [ ] **Do not** reuse the legacy `{ path: '/app', query: { view: 'chat', session } }` form from `onPeekOpenFull` — `appUrl.ts` documents that query shape as rewritten at boot and never emitted.
- [ ] Handle the no-workspace case by falling back to the current behaviour rather than building `/app/chat/...`.
- [ ] Run `ChatView` specs; confirm green.
- [ ] `Commit:` `feat(chatview): navigate to the session a search hit came from`

### Task 8 — Functional wire-shape gate

- [ ] Add one test to `tests/functional/agent_workspace_history_test.py` that seeds a session, runs the tool, and asserts `created_at` is not a bare integer. Use the existing harness (isolated tmpdir `HOME`, free port excluding 8081). Never boot a server by hand.
- [ ] Run `python3 -m pytest tests/functional/agent_workspace_history_test.py -q`.
- [ ] Run the sibling `agent_knowledge_edit_test.py` too, to prove the harness is not broken by the new test.
- [ ] `Commit:` `test(functional): assert FTS created_at is not a nano epoch`

### Task 9 — Full gates

- [ ] `zig build test` — whole suite green.
- [ ] Cross-platform compile check for Linux/macOS/Windows (`zig build -Dtarget=...` compile-only).
- [ ] `cd src/apps/desktop && pnpm run build` and `pnpm run test:unit`.
- [ ] Delete stray `.js` files emitted by `vue-tsc` before committing.
- [ ] Update the stale component docstring at `ReadWorkspaceSession.vue:16–79` — it still documents an XML `<read_workspace_session>` envelope; the backend emits JSON.
- [ ] `Commit:` `chore(read-workspace-session): refresh stale envelope docstring`

### Task 10 — PR

- [ ] Push the branch; `gh pr create --base main`.
- [ ] PR body: Goal / the four defects with `path:line` / why backend+frontend are one change (the wire is the contract) / task table / the "don't touch :775/:794/:827/:846" warning / decisions needing a reviewer.
- [ ] Note explicitly: **the pre-push hook does not run in a worktree** (`core.hooksPath=.husky/_`, and `.husky/_` is uncommitted and absent in fresh worktrees). "Pre-push passed" proves nothing; the gates in Task 9 were run by hand.
- [ ] `set_pull_request` to bind the PR to the session.

## Verification

- `zig build test` green, including the 10 existing `read_workspace_session` tests and the FTS sanitization tests.
- New Zig test: FTS `created_at` is `YYYY-MM-DD HH:MM:SS`, not a bare integer.
- `ReadWorkspaceSession.spec.ts` green — 14 pre-existing `it()`s plus new ones. **Fixture repair is required**, not optional.
- `ChatView` specs green; `.chat-tool-card` width invariants and the `ToolParameters` contract test still pass.
- `pnpm run build` + `pnpm run test:unit` green in `src/apps/desktop/`.
- Functional: `agent_workspace_history_test.py` green, and its sibling still green (harness not broken).
- Cross-platform compile check green for Linux + macOS + Windows.
- `git show HEAD:<file> | grep -c 'test "'` matches the working tree for every touched Zig file — proves relocated tests are committed, not just green.

## Out of Scope

- **Dropping tool rows from `messages_fts`.** Fixes ③ at the source, but changes recall for every consumer of the index. Backend decision, separate plan.
- **Real per-role totals.** Requires a `GROUP BY role` query over the full match set. Task 4 shows page-scoped counts and labels them as such.
- **A new right-hand read panel.** `SubAgentPeekPanel` already exists and re-embeds `ChatView`; reuse it rather than building a third surface.
- **LIST's fake `total_count`** (`read_workspace_session.zig:444` sets it to `count`, so the "N of M" badge is unreachable on LIST). A real bug, not this card's problem.
- **`tool_name` on search entries.** The filter works but the field is dropped pre-serialization; restoring it changes the wire contract for the LLM.

## Open Questions for the reviewer

1. **Grouping vs sorted-flat.** This plan implements full session headers. If you'd rather keep the flat list and only sort by session (adjacent rows share a quiet label), Task 3 shrinks to a sort — say so and I'll re-scope before implementation starts.
2. **Facet semantics.** Task 4's facets copy a ready-made tool call rather than filtering in place. If you want live in-card filtering, that needs the per-role totals query (currently out of scope).
3. **Should the ① fix also apply to the `getSessionMessages` sites?** They return the same epoch shape to the chat transcript. Deliberately excluded here; confirm that's right.

## Risks

| Risk | Mitigation |
|---|---|
| Grouping breaks existing `search-entry-*` testids | Keep the ids on the per-hit elements; assert in Task 3. |
| Fix ② could mis-highlight `[xdg-[portal]` | Parser takes the **first** `]`; covered by a Task 2 test. |
| Task 4's page-scoped counts read as totals | Footer is labelled as page-scoped; the total stays `total_count`. |
| `zig build test` count stays green while a test is merely absent | `git show HEAD:<file> | grep -c 'test "'` after any test relocation. |
| Worktree pre-push hook silently absent | Task 9 gates are run by hand; stated in the PR body. |