# Plan: the three left-sidebar menus — New Chat · Recent · Projects

> **For agentic workers:** use `subagent-driven-development` to execute the task list below one task per subagent. Do not
> start Task 1 before a human has answered Q1 in §"Open questions".

**Task:** `task_1790616057649_4` — *"make the 3 sidebar left menu more better"* (deliverable: this wireframe + this plan).
**Wireframe:** `docs/plans/2026-09-29-sidebar-three-menus-wireframe.html`
**Branch:** `worktree/make-the-3-sidebar-left-menu-more-better-1790616053266`

> **Review state (2026-09-29).** The human approved this plan ("okey") **for the spacing & type layer only** — the
> first wireframe was written against information architecture, the human redirected it to margins and font sizes, and
> the second wireframe is the one that was read. So:
> - **D12–D17 (spacing & type): APPROVED. Q4/Q5/Q6: answered yes.** These are ready to implement — T1 and T2.
> - **D1–D11 (information architecture): NOT yet re-reviewed.** The human redirected away before answering Q1–Q3, and
>   those decisions are unaffected by the spacing work. They are not blocked on anything in T1–T2, so the two layers can
>   proceed independently — but do not treat D1–D11 as signed off.
> - **Q1 (a search box on Projects) is still genuinely open**, and it is still the one decision that would reopen a
>   recorded 2026-09-22 choice. It gates T10 and nothing else.

**Goal, in priority order.** The sidebar is not *neat* — it uses **nine font sizes, four left edges and three row
heights** in one 210 px panel, and there is no scale for any of them to be wrong against. That is the first job (D12–D17,
T1–T2) and it is the one that ships first. Then: give each of the three menus exactly one job — New Chat **acts**,
Recent **resumes**, Projects **enumerates** — and make the two list menus render visibly different row types so a user
can tell a loose chat from a project child.

The two wireframes are one PR but two reviews. `…-spacing-type-wireframe.html` is self-contained and lands on its own.

**Architecture:** three sequential, independently-shippable changes. (1) A row-type system in the sidebar: an `item_type`
glyph map, a distinct chat-row grammar, hover-revealed actions. (2) A recency surface: RECENT capped at 5 rows with a
breadcrumb and a `See all` destination, one scroller, fold state in the route. (3) A find surface: an optional filter box
over the tree. Each lands on its own PR; none depends on the next except as noted.

**Tech stack:** Vue 3 `<script setup>` + TypeScript (Pinia stores), Tailwind utility classes with the
`--semantic-*` / `--color-*` CSS variables, Zig + SQLite backend.

---

## Global constraints

- **Never port 8081.** Functional tests use `tests/functional/harness.py`, a free port in 8080–8199, and an isolated
  `HOME` tmpdir. No `nohup ./zig-out/bin/nalar … &` + `curl`.
- **Empty-slice-binds-as-NULL.** `SqliteBackend.exec` binds `""` as SQL NULL. Any new nullable column added for this work
  must be exercised with a real `""` through the full `useCase`, not just an in-memory SQLite test.
- **Route order is a live trap.** `matchRoute` walks routes in registration order (`kabelweb src/server/router.zig:182`);
  a literal route registered after a `:param` route is captured by the param. Any new route needs a
  `tests/functional/` wire test, not a composable unit test.
- **No `// NEW (plan: …)` tags** in source. Refer to this plan by name in the PR description, not by tag in code.
- **`vue-tsc --build` emits stray `.js`** next to the `.ts` sources. Delete them before committing.
- **Cross-platform:** the sidebar is shared with the macOS/Windows webview builds. No platform-gated markup.
- **Verification gates:** `zig build test`, `(cd src/apps/desktop && pnpm run test:unit)`, and
  `python3 -m pytest tests/functional -k sidebar`.

---

## Current state (verified 2026-09-29 via 4 parallel explorers + first-hand reads)

| # | Fact | Evidence |
|---|---|---|
| 1 | The sidebar is **one** component, `Sidebar.vue`, 1649 lines, mounted once at the top of `AppLayout` outside `<main>`. There is **no per-mode sidebar**. | `AppLayout.vue:2841-2851` |
| 2 | Template order: resize handle (1367-1374) → collapse chevron (1375-1406) → header (1407-1471) → **New Chat** (1472-1513) → `<nav>` (1515-1547) → 13 modals. **No footer.** | `Sidebar.vue` |
| 3 | The three menus are New Chat (a row), RECENT (`ChatsList.vue:901-1078`), PROJECTS (`ProjectsList.vue:365-562`). | — |
| 4 | **RECENT ∩ PROJECTS ≠ ∅.** `workspace_item_tasks.id` **is** the session id (Migration 052 dropped the column), and the session list is workspace-scoped by *unioning those exact ids*. Every started task therefore renders in both menus. | `workspace_scope.zig:89-91`, `llm_history.zig:381`, `migration.zig:1048` |
| 5 | Neither list is a subset of the other. RECENT additionally holds plain chats whose `cwd` sits under a `workspace_items.path`; PROJECTS additionally holds never-started tasks, which have no `sessions` row and so can never appear in RECENT. | `workspace_scope.zig:105-120` |
| 6 | `sessions.workspace_id` exists (Migration 025) and is **dead** — never written, never read. Scoping is computed at read time. | `migration.zig:433`, `llm_history.zig:1438` |
| 7 | **No `item_type` → icon map exists anywhere in the frontend.** Every project row is `▶` + name; type is discoverable only by clicking. | `WorkspaceItem.vue:617-633` |
| 8 | The per-row count is `item.tasks?.length` — rows paged in at **10/page**, not a total. | `WorkspaceItem.vue:634-639`, `stores/workspaces.ts:915` |
| 9 | The backend computes **no `COUNT(*)`**; the response field is `.count = tasks.len` (page length) and the client does not surface it. | `http_response.zig:618`, `api/index.ts:722-726` |
| 10 | Pin / rename / delete sit at `opacity-60` on **every** child row, always visible. | `WorkspaceItemTaskRow.vue:264-317` |
| 11 | Section fold state, pane height, sidebar width and sidebar collapse are **7 `localStorage` keys**. Nothing about sidebar state is in the route. | `stores/sidebar.ts:5,9-11,68-108`, `stores/navigation.ts:5-10` |
| 12 | RECENT's pane is pinned to `DEFAULT_CHATS_HEIGHT = 40` % and is independently scrollable from PROJECTS. | `stores/sidebar.ts:14` |
| 13 | Search was removed **deliberately** in the v2 revamp, with the reason written in the source. | `ProjectsList.vue:84-85`, `:411` |
| 14 | RECENT has **no empty state** — only a `Loading…` label. PROJECTS has two. | `ChatsList.vue:1061-1063`, `ProjectsList.vue:543-562` |
| 15 | A right-click context menu already exists at all four row types via `useContextMenu()` + `OpenInNewTabMenu`. | `ChatsList.vue:972`, `WorkspaceItem.vue:604`, `WorkspaceItemTaskRow.vue:172`, `WorkspaceSwitcher.vue:270` |
| 16 | The canonical `item_type` glyph vocabulary is already committed in the tab strip. | `docs/tabs.md:148` |
| 17 | An open TBD has sat on exactly this since 2026-08-06: URL-driven single-active state + a 2 px violet left accent bar. | `docs/SPEC.md:971` |

---

## Design decisions (for the reviewer)

| # | Decision | Rejected alternative | Why |
|---|---|---|---|
| **D1** | Duplication stays. RECENT keeps task-backed chats; it gains a **breadcrumb** naming the parent project (or `no project`). A project child never gets one. | De-duplicating RECENT against the tree | The tree is collapsed most of the time, so "already visible" is not computable. Slack/VS Code/Linear all duplicate too. |
| **D2** | RECENT becomes a **5-row timeline** with `See all ›`. The resizable pane and its in-pane `Load more` are deleted. | Keeping the 40 % pane | It is the second scroller. Mirrors the Android drawer's already-locked `PREVIEW_ROWS = 5` + `See all chats ›`. |
| **D3** | Project rows get the **`docs/tabs.md:148` glyphs** (`▦ 🤖 🎨 ⏱ 📁 🧠`), fail-soft to `▤`. | The Android wireframe's `▦ ◍ ↻ ✎ ▤` | A second vocabulary for the same six types is worse than reusing the one the tab strip already ships. `item_type` is a bare `string` in TS and an unvalidated `TEXT` column, so the unknown case is real. |
| **D4** | **All count badges removed.** Honest totals move to `See all N chats ›`, and only after the backend returns a real total. | Keeping `items_count` on the header | `tasks.length` is a lie. `items_count` is server-true but the section already lists every row, so the number is free information. |
| **D5** | Row actions become **hover-revealed `⋯`** on both menus. The right-click menu is unchanged and gains `Shift F10`. | Keeping pin/rename/delete always-on | Ten children is thirty always-visible controls. |
| **D6** | **One scroller** for the nav. `chatsHeight` and its drag handle are deleted; section fold moves to `?nav=`. | Keeping the resize handle | Nothing else in the app resizes a pane by dragging, and this one is not keyboard-reachable. |
| **D7** | The **active project auto-expands from the URL**; the active chat row gets a 2 px accent bar + fill. Closes `docs/SPEC.md:971`. | Store-flag active state | Route-derived is the existing rule and the only refresh-safe one. |
| **D8** | RECENT gets a real **empty state**: *"No chats yet — press ⌘N to start one."* | The current silent `Loading…` | PROJECTS has two empty states; RECENT has none. |
| **D9** | The running indicator becomes a **labelled `◌ run` chip**. | The bare ring | It is the only state in the sidebar a user cannot read. |
| **D10** | New Chat gains **`⌘N`** and a trailing **`▾`** split (start in a chosen project/page). Weight, colour, the 40 px height and the `top-24` chevron are **untouched**. | Re-styling the row | The 2026-09-27 plan locked the bare-text treatment explicitly. The split only relocates the hover-only `+` that already exists per project row. |
| **D11** | The whole nav is **one roving-tabindex keyboard list**, with focus derived from the route like the active row. | A local `focusIndex` ref | A local ref is exactly how the highlight and the keyboard cursor drift apart — the failure `2026-08-06-sidebar-single-active-state-design.md` exists to prevent. |

### Spacing & type — the substrate (added after the user pointed at the real complaint) · **APPROVED 2026-09-29**

The decisions above are about meaning. **D12–D17 are about geometry and are the actual ask** — they land first (T1) and
every later task builds on them. Full audit in
`docs/plans/2026-09-29-sidebar-spacing-type-wireframe.html`.

| # | Decision | Rejected alternative | Why |
|---|---|---|---|
| **D12** | **Four spacing tokens** — `--sb-gutter` 12 px, `--sb-row` 32 px, `--sb-indent` 12 px, `--sb-hit` 24 px — added to `style.css` beside the ~50 existing colour vars. | A new `tailwind.config.js` | There is no Tailwind config today, so geometry is entirely un-centralised. But colour already standardised on CSS vars; a second token mechanism is worse than extending the first. |
| **D13** | **Three type sizes.** 11 px section title (600, uppercase, `0.08em`) · **13 px row label** · 11 px meta · plus a fixed 12 px icon glyph. Nine sizes → three. | 14 px for projects, 13 px for chats | Re-introduces the two-size hierarchy the wireframe exists to remove. 13 px is what `WorkspaceItem.vue:604` already uses — the value two of three row types are already at, so this is normalisation, not redesign. |
| **D14** | **The nav's `p-3` is deleted.** | Moving the list rows out to 16 px | The 8 px step at the top of the panel is caused by this one container padding, not by any row. Removing it is what makes a single left edge possible. |
| **D15** | **Every row is 32 px**, including RECENT (from 48). | Leaving RECENT roomier | 48 px exists for no reason other than that it was written first. 32 px holds a git badge, name, time pill and spinner. **Couples to `:default-item-height` on the `VirtualScroller`** — that value must move with it or the list scrolls wrong. |
| **D16** | **Both section headers become identical** — 28 px, 12 px padding, same `border-b`. | Dropping the border to match PROJECTS | Today RECENT draws a rule and PROJECTS does not, so a boundary exists between the two menus but not between PROJECTS and its own contents. A rule between peers is what keeps the boundary legible. |
| **D17** | **The stale `sidebarSpacing.spec.ts` comment is deleted**, replaced by a real spec asserting the four token values. | Writing the grep test the comment describes | The comment at `ChatsList.vue:911` claims a contract that **does not exist** — a repo-wide search for `sidebarSpacing` returns exactly one hit, the comment itself. A grep test would enshrine `py-2.5` as correct. |

**Carried forward, not reopened:** no filled primary button for New Chat; no `+` on the RECENTS header (deleted
deliberately 2026-09-22); no count badge on a collapsed project row; a project row is a **filter** and a chat row is a
**destination**; the 64 px collapsed rail keeps an icon-only New Chat with `aria-label`; the four New Chat states
(idle / hover / creating / no-workspace) are unchanged.

---

## Wire contract

No new endpoint is introduced by this work. The one backend change is additive:

| Change | Detail |
|---|---|
| `GET /api/workspaces/:wsId/items/:itemId/tasks` response gains `total: u32` | A `COUNT(*)` alongside the existing cursor-paginated `SELECT` in `tasks_list.zig`. Distinct from the existing `.count` (page length) — renaming the old field is a breaking change and is **not** proposed. |
| Query param | Unchanged: `?column_id=&limit=&cursor=` |

**Route:** no change. The one URL addition is a query param on an existing path:

```
/app/{ws}/projects/{pid}/chat/{tid}?nav=projects|recent|none
```

`?nav=` is read on mount, written on fold, defaults to `projects` when absent. `router.replace`, not `push` — folding
a section is a tab switch, not a context change.

**`?nav=`, not `?section=` — verified, not assumed.** `?section=` is already spoken for by the settings pages
(`NalarSettings.vue:94` reads it for the General/Profiles/MCP/Tools tab; `KanbanSettingsView.vue:86` for the kanban
settings tab), and `AppLayout` — which renders the sidebar — serves `/app/settings`. Reusing the key would put
`?section=tools` and `?section=recent` on the same route. `?tab=` is reserved by `helpers/tabTarget.ts:281-293`. A grep
for `query.nav` returns zero files, so `?nav=` is free.

---

## File map

| Action | File | Responsibility |
|---|---|---|
| Modify | `src/apps/desktop/src/style.css` | **The four `--sb-*` spacing tokens and the three type sizes**, beside the existing ~50 colour vars. The root fix (D12). |
| Modify | `src/apps/desktop/src/components/shell/Sidebar.vue` | Delete the nav's `p-3`; align the header and New Chat to `--sb-gutter`; replace the two stacked panes with one `<nav>` scroller; drop the chat-resize plumbing; host the filter. |
| Modify | `src/apps/desktop/src/components/views/ChatsList.vue` | Cap at 5 rows, add the breadcrumb + empty state + labelled run chip + hover actions, remove the in-pane `Load more`. |
| Modify | `src/apps/desktop/src/components/workspace/ProjectsList.vue` | Remove the `items.length` count, the deleted search comment and the `Load more`; add the optional filter; read `?nav=`. |
| Modify | `src/apps/desktop/src/components/workspace/WorkspaceItem.vue` | Add the glyph slot, drop the count badge, collapse the always-on actions to `⋯`, auto-expand from the route. |
| Modify | `src/apps/desktop/src/components/workspace/WorkspaceItemTaskRow.vue` | Collapse three buttons to one, add the time pill, add the active accent bar. |
| New | `src/apps/desktop/src/helpers/itemTypeGlyph.ts` | The `item_type → glyph` map, fail-soft to `▤`. Single source shared with the tab strip. |
| Modify | `src/apps/desktop/src/stores/sidebar.ts` | Delete `chatsHeight`; read section fold from the route instead of `localStorage`. |
| Modify | `src/apps/desktop/src/api/index.ts` | Surface `total` from the tasks response. |
| Modify | `src/http_handlers/tasks_list.zig` | Add the `COUNT(*)` and the `total` field. |
| Modify | `docs/SPEC.md` | Close the `#TBD` at line 971 with a pointer to this plan. |
| Test | `src/apps/desktop/src/__tests__/Sidebar.*.spec.ts` | Extend the existing 5 sidebar specs. |
| Test | `tests/functional/sidebar_*_test.py` | Wire-level route + payload checks. |

---

## Tasks

> **Order matters, and it changed.** This list was originally headed by the glyph map. The sidebar's real complaint is
> that it is not <i>neat</i> — different margins, different font sizes — so **T1 is now the spacing and type substrate**,
> and the IA work lands on top of it. A consistent 13 px row label and one left edge is what every later change needs in
> order to look deliberate.

- [x] **T1 — Spacing + type substrate. — DONE `ee9ee05e`** (the actual ask)** Add the four `--sb-*` tokens to `style.css`; delete the nav's
      `p-3`; set every row, section header and hit box to the token values. Split per D12–D17.
      *Ship this on its own.* It is mechanical, it is reviewable line-by-line, and it makes the screenshot measurably
      better before any behaviour changes.
      `Commit: refactor(sidebar): one spacing and type scale for the whole panel`
- [x] **T2 — Prove the substrate. — DONE `ee9ee05e`** Replace the stale `sidebarSpacing.spec.ts` comment with a real spec asserting the
      four token values and the three font sizes. Add a DOM assertion that every row in all three menus shares one
      left edge. *Without this the drift restarts within a month — that is why nine sizes accumulated in the first place.*
      `Commit: test(sidebar): assert the spacing and type tokens instead of a class string`
- [ ] **T3 — Glyph map + the project row.** `itemTypeGlyph.ts`; render the glyph on every project row; remove the
      `tasks.length` badge and the header `items.length` count. Now a `Q6` decision, because T1 made the row label 13 px.
      `Commit: feat(sidebar): project rows carry an item_type glyph and lose their lying counts`
- [ ] **T4 — Breadcrumb on RECENT.** Derive each session's parent project name server-side (the scope resolver already
      knows the task → item mapping) and render it under the row. Also add the empty state (D8) and the labelled run chip
      (D9). *This is the fix for "Recent and Projects look identical".*
      `Commit: feat(sidebar): RECENT rows name their parent project`
- [ ] **T5 — Collapse the row actions.** `⋯` on both menus, at `--sb-hit` 24 px; pin/rename/delete move into the
      existing context menu; add `Shift F10` to open it from the keyboard. *One hit-box size kills the 24/26/28 split.*
      `Commit: feat(sidebar): row actions collapse behind a single overflow control`
- [ ] **T6 — One scroller + `?nav=`.** Delete `chatsHeight` and the drag handle; move section fold into the route; write a
      mount-with-query spec and a click spec.
      `Commit: refactor(sidebar): one nav scroller, section fold in the URL`
- [ ] **T7 — `See all` destinations.** RECENT gets `See all ›`; a project with more children than fit gets
      `See all N chats ›`. Both navigate; neither closes anything.
      `Commit: feat(sidebar): See all destinations for Recent and for a project`
- [ ] **T8 — Real totals.** `COUNT(*)` in `tasks_list.zig` → `total`; surface it; only then let `See all N chats ›`
      print a number. *Blocked on its own card; the UI must render correctly with `total` absent.*
      `Commit: feat(api): return a real total alongside the paged task list`
- [ ] **T9 — URL-driven active row (closes `docs/SPEC.md:971`).** Auto-expand the active project from the route; 2 px
      accent bar on the active chat row.
      `Commit: feat(sidebar): single active row derived from the route`
- [ ] **T10 — Filter box.** *Only after Q1 is answered yes.*
      `Commit: feat(sidebar): filter the project tree`
- [ ] **T11 — `⌘N` and the New Chat split.** Shortcut + trailing `▾`; the split menu offers the default project, a named
      project, and a design page.
      `Commit: feat(sidebar): New Chat gains a shortcut and a split target menu`
- [ ] **T12 — Keyboard roving list.** `↑ ↓ → ← Enter Esc` across all three menus, focus derived from the route.
      `Commit: feat(sidebar): one keyboard-navigable list across the three menus`
- [ ] **T13 — Mirror to the Android drawer.** *Its own card, tracked separately; noted so it is not forgotten.*
      `Commit: chore(android): mirror the sidebar row grammar in the drawer`

---

## Verification

| Gate | Command | Asserts |
|---|---|---|
| Backend | `zig build test` | `tasks_list` returns `total` and the page; `COUNT` does not perturb the cursor. |
| Frontend unit | `cd src/apps/desktop && pnpm run test:unit` | **The four `--sb-*` token values and the three font sizes are asserted** (T2) — this is the gate that stops the nine-size drift returning. Plus: glyph map incl. the unknown-type fallback; no count badge; breadcrumb present on RECENT and absent on a child; `?nav=` round-trip; the active row follows the route. |
| Geometry | a DOM assertion, not a screenshot | Every row in all three menus resolves to the same left edge and the same computed font-size. Pixel-diffing a screenshot is the wrong gate here — it fails on a 1 px antialiasing change and passes on a 14 px indent regression. |
| Functional | `python3 -m pytest tests/functional -k sidebar` | The wire payload for `GET /workspaces/:ws/items/:item/tasks` carries `total`, and `?nav=` survives a real `GET /app/…`. Free port 8080–8199, never 8081, isolated `HOME`. |
| No-regression | `pnpm run test:unit` before and after | The 5 existing `Sidebar.*.spec.ts` files must stay green **without** edits; if a spec has to change, the change is the review signal. |
| Render | `functional_ui` seeded from a real `agent.db` | The breadcrumb does not truncate the chat name at 210 px; the glyph column is optically aligned. |

---

## Out of scope

- The workspace header (`▾ name  Settings  Logout`) — settled by the 2026-09-22 revamp, drawn unchanged.
- Per-mode sidebars — there is one `Sidebar.vue` and this does not split it.
- Any new route shape. Existing URL contracts stand.
- Drag-to-reorder of projects; the disabled `Add Project` row.
- Folder file listing — a `folder` project expands to its chats like every other type.
- The appbar inconsistency across modes (sibling card `3 mode workspace items have different appbar`).
- The Android drawer implementation (T11 is a tracking note, not a task).

---

## Open questions for the reviewer

| # | Question | Recommendation |
|---|---|---|
| **Q1** | Does Projects get a filter box? This **reopens** a deliberate 2026-09-22 removal (`ProjectsList.vue:411`). | **Yes.** Nine projects, one with 100+ children, and after D4 the tree is the only affordance. But the tree is only nine rows tall and a filter can hide a project you forgot existed. The human decides; the wireframe stands without it. |
| **Q2** | Does a project row keep a chevron at all? A kanban and a routine have no children, so their chevron is a dead control. | **Hide it** for childless types. A control that cannot do anything should not be drawn. |
| **Q3** | Does a project child keep its own time pill? | **Keep.** The seven identical `New Chat` rows are exactly the case where a timestamp is the only thing that distinguishes them. |

### Spacing & type questions

| # | Question | Recommendation |
|---|---|---|
| **Q4** | Does the header text move in by 4 px? D14 puts every label at 12 px, so **Settings**, **Logout** and **New Chat** shift 16 → 12. | **Yes.** 12 px is what most of the panel already uses and it is the only value that makes a single left edge possible. The alternative moves the list rows out to 16 instead, spending the same 4 px elsewhere. |
| **Q5** | Do RECENT rows drop 48 → 32 px? They carry a git badge, name, time pill and spinner. | **Yes.** 32 px holds all four, and the saving shows up as more projects visible without scrolling. 48 px is the one row height that exists for no reason other than that it was written first. |
| **Q6** | Is 13 px too small for a project name? A project is the biggest object in the panel and would render the same size as a chat under it. | **13 everywhere**, with hierarchy carried by the glyph and the indent. 14/13 re-introduces the two-size hierarchy this exists to remove — and the glyph from T3 gives a project more presence at the same text size. |

---

## Risks

| Risk | Mitigation |
|---|---|
| Removing the counts reads as a regression ("where did 119 go?") | `See all N chats ›` ships in T5 with the placeholder, and T6 makes the number real. Say so in the PR body. |
| The breadcrumb needs data the session list does not return | The scope resolver at `workspace_scope.zig:89-91` already walks task → item → workspace. T2 extends that resolver to return the parent name; no new table, no N+1. |
| ~~`?section=` collides~~ **found and fixed pre-review** | `?section=` <b>is</b> already used: `NalarSettings.vue:94` and `KanbanSettingsView.vue:86`, both on routes `AppLayout` serves. Renamed to `?nav=`, which a grep confirms is unused. `helpers/tabTarget.ts:281-293` separately reserves `?tab=`. |
| Dropping the resize handle is a perceived feature removal | It is one of seven `localStorage` keys with no keyboard path. T4's PR body lists the deleted key. |
| Two scrollers existed for a reason nobody remembers | `git log -S "chatsHeight" -- src/apps/desktop/src/stores/sidebar.ts` before T4. If a commit message names a real reason, this plan is wrong and the reviewer should hear it. |

---

## Plan saved checklist

- [x] Wireframe written — `docs/plans/2026-09-29-sidebar-three-menus-wireframe.html`
- [x] Every load-bearing fact verified first-hand (`workspace_scope.zig:89-91`, `llm_history.zig:381`, `migration.zig:1048`, `WorkspaceItem.vue:634-639`, `http_response.zig:618`, `docs/tabs.md:148`, `docs/SPEC.md:971`)
- [x] Prior approved decisions carried forward, none silently reopened except Q1, which is raised as a question
- [x] Spacing + type audited from source and re-prioritised to T1 — `docs/plans/2026-09-29-sidebar-spacing-type-wireframe.html`
- [x] Found that the `sidebarSpacing.spec.ts` contract claimed at `ChatsList.vue:911` does not exist in the repo
- [x] **User reviewed before execution** — approved 2026-09-29 ("okey"). D12–D17 decided; Q4/Q5/Q6 answered yes.
- [x] **T1 + T2 implemented** (`ee9ee05e`): 8 files, +1 spec, 8/8 new tests, 0 regressions vs an 11-failure baseline
