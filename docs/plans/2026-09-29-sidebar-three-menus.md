# Plan: the three left-sidebar menus — New Chat · Recent · Projects

> **For agentic workers:** use `subagent-driven-development` to execute the task list below one task per subagent. Do not
> start Task 1 before a human has answered Q1 in §"Open questions".

**Task:** `task_1790616057649_4` — *"make the 3 sidebar left menu more better"* (deliverable: this wireframe + this plan).
**Wireframe:** `docs/plans/2026-09-29-sidebar-three-menus-wireframe.html`
**Branch:** `worktree/make-the-3-sidebar-left-menu-more-better-1790616053266`

**Goal:** give each of the sidebar's three menus exactly one job — New Chat **acts**, Recent **resumes**, Projects
**enumerates** — and make the two list menus render visibly different row types so a user can tell a loose chat from a
project child.

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
| Modify | `src/apps/desktop/src/components/shell/Sidebar.vue` | Replace the two stacked panes with one `<nav>` scroller; drop the chat-resize plumbing; host the filter. |
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

- [ ] **T1 — Glyph map + the project row.** Add `itemTypeGlyph.ts`; render the glyph on every project row; remove the
      `tasks.length` badge and the header `items.length` count. *No behaviour change yet — this is the scannability fix
      and it is the piece most worth landing first.*
      `Commit: feat(sidebar): project rows carry an item_type glyph and lose their lying counts`
- [ ] **T2 — Breadcrumb on RECENT.** Derive each session's parent project name server-side (the scope resolver already
      knows the task → item mapping) and render it under the row. Also add the empty state (D8) and the labelled run chip
      (D9). *This is the fix for the actual complaint in the screenshot.*
      `Commit: feat(sidebar): RECENT rows name their parent project`
- [ ] **T3 — Collapse the row actions.** `⋯` on both menus; pin/rename/delete move into the existing context menu;
      add `Shift F10` to open it from the keyboard.
      `Commit: feat(sidebar): row actions collapse behind a single overflow control`
- [ ] **T4 — One scroller + `?nav=`.** Delete `chatsHeight` and the drag handle; move section fold into the route;
      write a mount-with-query spec and a click spec.
      `Commit: refactor(sidebar): one nav scroller, section fold in the URL`
- [ ] **T5 — `See all` destinations.** RECENT gets `See all ›`; a project with more children than fit gets
      `See all N chats ›`. Both navigate; neither closes anything.
      `Commit: feat(sidebar): See all destinations for Recent and for a project`
- [ ] **T6 — Real totals.** `COUNT(*)` in `tasks_list.zig` → `total`; surface it; only then let `See all N chats ›`
      print a number. *Blocked on its own card; the UI must render correctly with `total` absent.*
      `Commit: feat(api): return a real total alongside the paged task list`
- [ ] **T7 — URL-driven active row (closes `docs/SPEC.md:971`).** Auto-expand the active project from the route; 2 px
      accent bar on the active chat row.
      `Commit: feat(sidebar): single active row derived from the route`
- [ ] **T8 — Filter box.** *Only after Q1 is answered yes.*
      `Commit: feat(sidebar): filter the project tree`
- [ ] **T9 — `⌘N` and the New Chat split.** Shortcut + trailing `▾`; the split menu offers the default project, a named
      project, and a design page.
      `Commit: feat(sidebar): New Chat gains a shortcut and a split target menu`
- [ ] **T10 — Keyboard roving list.** `↑ ↓ → ← Enter Esc` across all three menus, focus derived from the route.
      `Commit: feat(sidebar): one keyboard-navigable list across the three menus`
- [ ] **T11 — Mirror to the Android drawer.** *Its own card, tracked separately; noted so it is not forgotten.*
      `Commit: chore(android): mirror the sidebar row grammar in the drawer`

---

## Verification

| Gate | Command | Asserts |
|---|---|---|
| Backend | `zig build test` | `tasks_list` returns `total` and the page; `COUNT` does not perturb the cursor. |
| Frontend unit | `cd src/apps/desktop && pnpm run test:unit` | Glyph map incl. the unknown-type fallback; no count badge; breadcrumb present on RECENT and absent on a child; `?nav=` round-trip; the active row follows the route. |
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
- [ ] **User reviewed before execution** ← the human's job
