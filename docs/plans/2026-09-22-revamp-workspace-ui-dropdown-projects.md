# Plan: revamp workspace UI — workspace selector dropdown + sidebar "Projects" section

> **Superseded in part (2026-09-23):** the "CHATS stay **global**" non-goal
> below is DONE — see `docs/plans/2026-09-22-revamp-ui-chats-workspace-scoped.md`.
> CHATS are now workspace-scoped end-to-end (`?workspace_id=` on
> `GET /api/llm/session`), the `+` new-chat button is removed, URLs are
> path-based (`/app/{ws}/chat/{sid}`, `/app/{ws}/projects/{pid}`), items
> load lazily per workspace, and `/app` is a landing with workspace
> creation. The rest of this doc (dropdown, Projects section, push on
> switch) stands as written.

## Goal
One-sentence: replace the sidebar's stacked multi-workspace list with (a) a workspace selector **dropdown in the sidebar header** and (b) a single **"Projects" section that shows only the selected workspace's items** — so the sidebar stops being a cluttered tree of every workspace at once.

Non-goals (v1): no backend/schema changes; CHATS list stays **global** (not scoped per workspace); no new Project domain entity; no workspace SSE events; no workspace drag-reorder UI in the dropdown (user-confirmed — API/store kept); the "Add Project" (folder) menu option stays disabled as today.

## Decision log
- 2026-09-22 (user): "dropdown to select a workspace … remove the sidebar list workspaces, change with Projects." Screenshot arrow points at the header word (`AnakMagang`) as the dropdown's home.
- 2026-09-22 (plan): "Projects" = the selected workspace's existing `workspace_items` (folder/kanban/design/agent/routine) rendered flat — NOT a new entity. Workspace create/rename/delete move into the dropdown.
- 2026-09-22 (user, review answers): "Projects" = **ALL** workspace items (confirmed); **no** workspace drag-reorder UI in v1; CHATS stay **global** for now; workspace switch **must create a browser-history entry** → `router.push` (deliberate exception to the tab-switch `replace` precedent: switching workspace is a context change, like task navigation).

## Background (what exists today)

### Sidebar structure
- `src/apps/desktop/src/components/shell/Sidebar.vue` (1624 lines): header block L1385–1447 renders a **hard-coded** `AnakMagang` word (L1409; collapsed monogram L1413–1418) + Settings (L1422) / Logout (L1435). Nav L1450–1513 composes `<ChatsList>` (L1452) + `<WorkspaceList>` (L1455–1481, 20+ forwarded events) plus a collapsed fallback of per-workspace monogram tiles + `+` (L1489–1512, `workspaceMonogram()` at L104–131).
- `components/views/ChatsList.vue`: CHATS collapsible section (header L600–647: chevron, title, sort toggle, `+` new chat). Loads **all** sessions globally (`loadChats` L270 → `GET /api/llm/session`, no workspace filter).
- `components/workspace/WorkspaceList.vue` (822 lines): WORKSPACES section — header L506–536 (title + `workspaces-add-workspace-button`), workspace rows L557–645 (HTML5 DnD `application/x-workspace-id`, expand ▶, name, count badge, rename ✎, delete ×), nested `<WorkspaceItem>` rows L649–684, per-workspace `+ Add Item` menu L685–765 (Add Project [disabled "Coming soon"], Kanban, Design, Agent, Routine).
- Collapse state lives in `stores/sidebar.ts`: `navExpanded`, `workspacesExpanded` (localStorage `pabrik-sidebar-workspaces-expanded`), `chatsHeight`.

### State model — there is no "active workspace" today
- `stores/workspaces.ts`: `Workspace { id, name, icon, items, expanded }` (L81–86). Selection bottoms out at `activeWorkspaceItemId` (L510); the `activeWorkspace` getter (L946) is *derived* — the workspace containing the active item, `undefined` when no item is open.
- Relevant actions: `init` L700, `toggleWorkspace` ~L1029, `setActiveWorkspaceItem` L1070, `addWorkspace` L1093, `renameWorkspace` L3427, `removeWorkspace` L3769, `reorderWorkspaces` L3811.

### URL contract (repo rule: every view switch syncs the browser URL)
- View state lives in query params: `?view=workspace&workspaceId=X&itemId=Y[&pageId=Z][&sorts=…]`, written by `AppLayout.handleNavigate` L554–605 + the store→URL watcher L370–430, restored on mount by `pendingUrlRestore` L215–264. Helpers: `composables/useCurrentMainView.ts`, `helpers/buildTaskUrlQuery.ts`.
- Today `workspaceId` means *"workspace of the open item"*. v1 extends it to be valid **standalone** (`?view=workspace&workspaceId=X` with no `itemId`). Spec-pair precedent: `components/views/__tests__/SidebarDiffPanel.tabs.spec.ts` (click writes query / mount restores).

### Backend (unchanged in v1)
- `workspaces(id, name, created_at, updated_at, position)` (migrations 024/027/043) — no icon/settings/privacy columns; `icon: "📁"` hard-coded server-side (`http_handlers/workspaces_list.zig:9`). Full CRUD + reorder routes already exist (`src/main.zig:648–659`).
- **No Project entity exists anywhere** (no table, route, store, or component). Closest concept: folder-type `workspace_items`, surfaced as the (disabled) "Add Project" add-menu option.

### Reusable dropdown patterns (no UI library in repo — everything hand-rolled)
- ⭐ `components/kanban/GitBaseBranchSelect.vue` — trigger + panel, filter, ↑/↓/Enter/Esc keyboard nav, v-model contract. Best skeleton for the switcher.
- `components/kanban/KanbanSortMenu.vue` (minimal menu), profile-picker pattern (`ChatView.vue` L4982+), `components/shell/OpenInNewTabMenu.vue` (Teleport-to-body — needed so the panel escapes sidebar overflow in collapsed mode).

## Proposal

### UX
```
┌ Sidebar ─────────────────────────┐
│ ▾ kabelweb ⌄        Settings  Logout│  ← header = WorkspaceSwitcher trigger
├──────────────────────────────────┤
│ ▼ CHATS                  ↓    +  │  (unchanged, still global)
│   identify-model            now  │
│   …                              │
├──────────────────────────────────┤
│ ▼ PROJECTS                  +    │  ← replaces "WORKSPACES"
│   ▸ kabelweb repo           (3)  │     items of the SELECTED workspace only
│   ▸ designs                 (2)  │
│   ▸ agents                       │
│   + Add Item                     │
└──────────────────────────────────┘
```
Dropdown panel (trigger = active workspace name):
```
┌ Select workspace ─────────────┐
│ ✓ kabelweb             (5)   │   ← row hover reveals ✎ rename / × delete
│   agentic coding       (11)  │
│   work                 (13)  │
├───────────────────────────────┤
│ + New workspace               │
└───────────────────────────────┘
```

Behaviors:
1. Trigger renders `activeWorkspace.name` + `▾` — this **fixes the hard-coded `AnakMagang` header** as a side effect. No workspace yet → "Select workspace".
2. Selecting a workspace → sets `activeWorkspaceId`, clears item/task selection that belonged to the previous workspace, `router.push({ query: { view: 'workspace', workspaceId: id } })` (drops `itemId`/`pageId`/`session` from the old context; **push, not replace** — Back/Forward must cross workspace switches), Projects section re-renders. CHATS intentionally unchanged.
3. Per-row hover actions reuse existing flows: rename → `RenameWorkspaceModal`; delete → `ConfirmDialog` → `removeWorkspace`.
4. `+ New workspace` → existing `WorkspaceModal`.
5. A11y/keyboard per `GitBaseBranchSelect`: Enter/Space open, ↑/↓ move, Enter select, Esc close, click-outside close, `role="listbox"` + option rows.
6. Collapsed sidebar: **one** monogram for the active workspace (replaces the per-workspace tiles + `+`); clicking it opens the same panel, Teleported to `body`.

### State & URL
- New `activeWorkspaceId: ref<string | null>` + `setActiveWorkspace(id)` in `stores/workspaces.ts`: validates the id, clears `activeWorkspaceItemId`/`activeTaskId` when they fall outside the target workspace, expands the target, persists `localStorage['pabrik-active-workspace']`.
- Resolution precedence for what the dropdown + Projects show:
  1. URL `workspaceId` (via `pendingUrlRestore` on mount),
  2. `activeWorkspaceId` from localStorage,
  3. workspace containing `activeWorkspaceItemId` (today's behavior, keeps in-flight tabs sane),
  4. first workspace in list.
- Re-point the `activeWorkspace` getter to id-first with item-derived fallback so existing consumers (e.g. `AppLayout.vue:2735 :project-name="activeWorkspace?.name"`) keep working — and get better behavior.
- Deleting the active workspace → fall back down the precedence chain and `router.replace` the stale id out of the URL.
- `stores/sidebar.ts`: rename `workspacesExpanded` → `projectsExpanded` under key `pabrik-sidebar-projects-expanded`, seeding once from the old key so users don't get a silently re-collapsed section.
- **History:** workspace switches use `router.push` (user decision — Back/Forward must cross switches); other tab/selector switches keep `replace`. Cleanup of a stale id after workspace *deletion* still uses `router.replace` (that's not a navigation).

### Component-by-component changes
| Change | File |
|---|---|
| NEW switcher: trigger + panel + hover rename/delete + New workspace; emits `select/addWorkspace/renameWorkspace/deleteWorkspace` (same event-up pattern Sidebar already uses) | `components/workspace/WorkspaceSwitcher.vue` |
| Header word → `<WorkspaceList>` swapped for `<ProjectsList>`; drop workspace-row event forwards that moved into the switcher; collapsed tiles → active monogram + switcher | `components/shell/Sidebar.vue` |
| REFACTOR `WorkspaceList.vue` → `ProjectsList.vue`: props become `{ workspace: Workspace \\| null }`; delete workspace-row DnD / expand / rename / delete / count code; title "Projects"; promote `+ Add Item` to the section header; keep `WorkspaceItem` rows, tasks, design pages and **item-level** DnD (`reorderWorkspaceItems`); add empty state ("No projects yet") | `components/workspace/ProjectsList.vue` (replaces `WorkspaceList.vue`) |
| `activeWorkspaceId`, `setActiveWorkspace`, getter re-point, localStorage | `stores/workspaces.ts` |
| `projectsExpanded` key (+ one-time seed from old key) | `stores/sidebar.ts` |
| Restore standalone `workspaceId` on mount; write it on switch; treat `workspaceId`-without-`itemId` as a valid workspace view | `AppLayout.vue`, `composables/useCurrentMainView.ts`, `helpers/buildTaskUrlQuery.ts` |

Removals: workspace-row DnD handlers in `WorkspaceList` (item DnD stays), sidebar call sites of `toggleWorkspace` (the store action + wire `expanded` field are kept but no longer drive the sidebar tree), `collapsed-add-workspace-button` / per-workspace `collapsed-workspace-button` tiles.

## Implementation steps (each step leaves the tree green)

1. **State + URL groundwork (no visual change).** Add `activeWorkspaceId` / `setActiveWorkspace` + precedence + localStorage; extend `pendingUrlRestore`, the URL watcher, `useCurrentMainView`, `buildTaskUrlQuery` for standalone `workspaceId`. New spec: `__tests__/stores.activeWorkspace.spec.ts` (precedence, clearing rules, delete-fallback). Existing UI untouched → all current specs stay green.
2. **WorkspaceSwitcher (header swap).** Build off the `GitBaseBranchSelect` skeleton; mount in the `Sidebar` header replacing the `AnakMagang` word; forward events to existing Sidebar handlers (`handleAddWorkspace` L766, `handleRenameWorkspace` L741, `handleDeleteWorkspace` L513). New specs: `WorkspaceSwitcher.spec.ts` (open, select, rename, delete-confirm, create, empty list) and `workspaceSwitcher.url.spec.ts` — the mandated pair: *click writes* `?view=workspace&workspaceId=…` (no `itemId`) / *mount-with-query restores* the active trigger + workspace — plus assert the switch **pushed** a history entry (Back returns to the pre-switch URL).
3. **Projects section swap.** Refactor `WorkspaceList.vue` → `ProjectsList.vue` per table; Sidebar passes `workspacesStore.activeWorkspace`; rename `workspacesExpanded` → `projectsExpanded`. Repoint specs: `WorkspaceList.expandedNoActiveBg.spec.ts` → `ProjectsList.*`, delete workspace-DnD cases from `workspaceListDragDrop.spec.ts`, repoint `workspaceListItemDragDrop.spec.ts` + `workspaceListProcessingSpinner.spec.ts`; `workspacesStoreReorder.spec.ts` stays (action/API kept).
4. **Collapsed mode + dead-code sweep.** Active-workspace monogram opens the Teleported switcher; remove the tile grid. Grep contract per repo deletion rule: `rg 'WorkspaceList|workspacesExpanded|collapsed-workspace-button|workspaces-add-workspace-button|AnakMagang' src/apps/desktop/src` must return nothing outside this plan doc (the `AnakMagang` brand remains only in `LoginView.vue` — out of scope, noted). Update every spec referencing the removed testids (`sidebarSingleActive.spec.ts`, `Sidebar.*.spec.ts`, …).
5. **Docs + verification.** Update any live docs/screenshots that describe the sidebar WORKSPACES section. Comment style: plain why-comments only — no `// NEW (plan: …)` tags (repo rule).

## Verification
- Frontend unit: `cd src/apps/desktop && pnpm run test` (`vitest --run`) — must include the new URL spec pair and switcher behavior specs.
- Static grep contracts from step 4 (route/testid removal has precedent as a `pub const`-style grep contract).
- `pnpm run build` (the pre-push hook runs it).
- **No live-server curl.** v1 ships **no wire changes**, so no new python functional test is required; a follow-up that scopes CHATS per workspace MUST ship with a `tests/functional/*_test.py` harness test (free port 8080–8199, never 8081) covering the real wire payload — not just vitest.

## Risks / open questions
Resolved by user 2026-09-22: (1) "Projects" = ALL workspace items; (2) no workspace drag-reorder UI in v1 — the `reorderWorkspaces` API, store action and `workspacesStoreReorder.spec.ts` are kept, only the sidebar UI goes away; (3) CHATS stay global for now; (5) workspace switch uses `router.push`, so Back/Forward crosses switches — a deliberate exception to the tab-switch `replace` precedent, because a workspace switch is a context change like task navigation.

Remaining risks:
1. **CHATS stay global** — switching workspace does NOT change the chat list (`sessions.workspace_id` is still always NULL; scoping already specced in `docs/plans/2026-09-15-workspace-scoped-chat-history.md`). Confirmed "for now"; when revisited, that follow-up ships with a python functional harness test, not vitest.
2. **`workspace.expanded` / `pabrik-workspace-expanded` become vestigial** (no per-workspace tree rows anymore). v1 keeps the wire field but stops reading it for the sidebar; full removal is a cleanup PR.
3. **No workspace SSE** — create/delete/rename from another tab won't live-update the dropdown (pre-existing gap, unchanged by this work).
4. **Spec blast radius** — ~10 sidebar/workspace specs need repointing or deletion (steps 2–4); budget test time accordingly.
