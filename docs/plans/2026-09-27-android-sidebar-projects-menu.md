# Plan: Android drawer — a "Projects" section, mirroring the Vue sidebar

**Task:** `task_1790446550585_1` — *sidebar left android will be show a menu Projects like in vue*
**Status:** ✅ **implemented** on `worktree/sidebar-left-android-will-be-show-a-menu-projects--1790446549734`
**Wireframe:** `docs/plans/2026-09-27-android-sidebar-projects-wireframe.html`

> This is the plan the code was built from, and the wire contract, the state
> model, the cache decision and the tap semantics are all as built. Two
> details are called out below because they changed during implementation and
> a reader comparing the two would otherwise be confused.

---

## Goal

One sentence: give the native Android drawer a **Projects** section below the
existing **Recent** list, so a phone user can see the selected workspace's
projects, open one, and read its chats — the same information the Vue sidebar's
`ProjectsList.vue` gives a desktop user, on a 390dp-wide surface.

## Confirmed decisions (human reviewed 2026-09-27)

| # | Question | Answer |
|---|---|---|
| 1 | What does tapping a Project row do? | ✅ **Expand in place** — the row folds the project's chats out under itself, Vue-style. The drawer stays **open**. |
| 2 | `folder` projects? | **Expanded to their chats like every other type**; the disk-listing Vue does for them is out of scope. `item_type = "folder"` is legacy — its create menu row is disabled with the tooltip "Coming soon" (`ProjectsList.vue:421-434`), so nothing can make one any more. |
| 3 | How does the reader see the *rest* of a project's chats? | ✅ **A `See all chats ›` button**, not an in-drawer "Load more" row. It closes the drawer and pushes a **new route** to a full-screen list of that project's sessions, which **lazy-loads on scroll**. |
| 4 | `+ Add Item` menu? | **Out of scope** — stays out; it is a separate card. |

### The assumption that was never a real question

An earlier draft of this plan left two options on the table for the project row.
One of them — "filter the Recent list" — was not a matter of taste, it was
**blocked by the wire**: `SessionInfoJson`
(`src/agentic_loop/llm_history.zig:459-484`) has no `workspace_item_id` field,
so Recent rows cannot be attributed to a project client-side. That option would
have needed a backend change. Expand-in-place was the only one that needed none.

### The one number we refuse to print

`See all chats ›` carries **no count**, and neither does a collapsed project row.
The tasks endpoint returns `count` = *page length*, not a total
(`src/http_handlers/tasks_list.zig:18`), so any total costs paging the entire list
to get it — per project, on every refresh. A button reading "See all 47 chats"
when there are 312 is a worse lie than no number at all. See §"Counts".

## Non-goals

- No new backend endpoints, no migration, no response-shape change.
- No project **board** / **agent config** / **design canvas** screen. The new
  screen this plan adds lists *chats*, not the project's own main view.
- No `+ Add Item` menu (confirmed out of scope, above).
- No per-project delete / rename / reorder / drag-and-drop.
- No per-project *exact* chat count, anywhere. See §"Counts".
- No folder **file** listing (Vue's `GET /api/system/folder?action=list&path=…`).
- Do **not** flip `is_include_items` — see §"The one call we do not make".

---

## Background — what the Vue sidebar does

`src/apps/desktop/src/components/shell/Sidebar.vue:1430-1457` composes two
stacked, independently-scrolling panes inside one `<nav>`:

```
Sidebar.vue:1430   <ChatsList>      ← the "Recent" pane, resizable, default 40%
Sidebar.vue:1432   <ProjectsList>   ← the "Projects" pane, takes the remaining flex-1
```

Both are collapsible sections with the same header shape: a `▶` chevron that
rotates 90° when expanded, an uppercase `text-xs font-semibold tracking-wider`
label in `--semantic-text-dim`, and a trailing action.

**Section header** — `ProjectsList.vue:365-386`:

| Slot | Content | Vue ref |
|---|---|---|
| Chevron | `▶`, rotates 90° when expanded | `ProjectsList.vue:378-383` |
| Label | `PROJECTS` | `ProjectsList.vue:384-388` |
| Count | `workspace.items.length`, `text-[11px]` opacity 0.7 | `ProjectsList.vue:389-395` |
| Add | literal `+`, `title="Add Item"` | `ProjectsList.vue:400-412` |

Expansion is persisted to `localStorage` under `nalar-sidebar-projects-expanded`
and **defaults to expanded** (`stores/sidebar.ts`, via
`toggleProjectsSection()` at `ProjectsList.vue:143-145`).

**Project row** — `WorkspaceItem.vue:588-709`:

| Slot | Content | Vue ref |
|---|---|---|
| Chevron | `▶`, rotates 90° when expanded | `WorkspaceItem.vue:614-626` |
| Name | `item.name \|\| 'Untitled project'`, truncate | `WorkspaceItem.vue:628-630` |
| Task count | `item.tasks?.length` when `> 0` | `WorkspaceItem.vue:631-644` |
| Loading | 12×12 spinner while folder contents load | `WorkspaceItem.vue:645-666` |
| Active dot | 6px `--color-aqua` | `WorkspaceItem.vue:667-675` |
| `+` add task | hidden for `kanban` / `routine` | `WorkspaceItem.vue:684-697` |
| `×` delete | always | `WorkspaceItem.vue:698-709` |

**Nested task (chat) row** — `WorkspaceItemTaskRow.vue:158-325`, rendered only
when expanded and the item is not a `design`/`kanban`:

| Slot | Content | Vue ref |
|---|---|---|
| Bullet | 4px dot, `#e8c87a` when active/pinned | `WorkspaceItemTaskRow.vue:186-194` |
| Pin indicator | filled pin SVG when `task.is_pinned` | `WorkspaceItemTaskRow.vue:252-262` |
| Name | `task.name`, truncate | `WorkspaceItemTaskRow.vue:263` |
| Rename / Delete | 24×24 SVG buttons | `WorkspaceItemTaskRow.vue:289-315` |
| Worker slider | `<SessionSlider :session-id="task.id">` | `WorkspaceItemTaskRow.vue:317-318` |

Pagination here is a **`Load more` button**, not infinite scroll
(`WorkspaceItem.vue:788-812`).

**Empty states** — `ProjectsList.vue:543-560`:

- workspace selected, zero items → `No projects yet — use + above to add one.`
- no workspace selected → `No workspace selected.`

There is deliberately **no search box** in the Projects section
(`ProjectsList.vue:88`, `:415`).

## Code drift since this plan was first drafted

Three sibling PRs merged into `main` while this plan was in review. The shape of
the drawer is unchanged, but two things moved and one seam got **better**:

| PR | Effect on this plan |
|---|---|
| #682 `change back button to hamburger button` | **The chat route now has its own recents drawer.** `shell/RecentsDrawer.kt` was added; `RecentsDrawerContent` (`:42`) is the single shared wrapper with **two** call sites. Chunk 4 now edits *that* file, not `MobileHomeScreen`'s two sites — one edit reaches both drawers. |
| #683 `get list recent follow query params like vue` | Recents ordering/cache changed (`d376adf0`, order by `updated_at`). Line numbers in `RecentsSidebar.kt` shifted ~20 lines. No structural change to the sidebar. |
| #684 `the android very laggy if move another session` | `0fde07f7`, "stop the UI thread doing the session switch". Touches `ChatViewModel`/`NalarNavGraph`, not the drawer. Relevant only as precedent: the codebase is actively hostile to UI-thread work, which is a point in favour of the shared-ViewModel decision in §"Open questions" 2. |

**All `file:line` citations into `RecentsSidebar.kt` in this document are
approximate and should be re-anchored by name at implementation time** — the
composable names (`RecentsSidebar`, `SidebarBody`, `ChatListFooter`,
`WorkspaceDropdown`, `ChatRow`, `StaleDataNotice`, `SidebarPlaceholder`,
`SidebarError`, `EmptyChats`) are all still present and are the stable handle.
Backend citations (`src/main.zig`, `src/http_handlers/*`) are unaffected.

## Background — what the Android drawer does today

`app/src/main/java/com/nalar/mobile/recents/RecentsSidebar.kt` (808 lines) renders
exactly two things:

```
RecentsSidebar.kt:82-126   fun RecentsSidebar( … 22 params … )   ← the only public composable
RecentsSidebar.kt:127-132   Column: fillMaxSize · NalarBackground · padding(horizontal = 12.dp)
RecentsSidebar.kt:134       Spacer(12.dp)
RecentsSidebar.kt:136-154     SidebarBody(Modifier.weight(1f))      :173-360
RecentsSidebar.kt:158-164     AccountFooter(…)                      :371-430
```

`SidebarBody`'s order (`:198-360`):

1. `:200-228` — `workspaces.isEmpty()` → `SidebarPlaceholder` / `SidebarError` + `return@Column`
2. `:230-234` — `WorkspaceDropdown(…)` (`:475-578`)
3. `:236-245` — `StaleDataNotice` when rows survived a failed refresh
4. `:246` — `Spacer(24.dp)`
5. `:248-255` — `Text("Recent")`, `labelLarge`, `NalarDim`, `heading()` semantics
6. `:257` — `Spacer(8.dp)`
7. `:285-359` — `LazyColumn` of `ChatRow`s (`:580-683`)

**There is no Projects concept anywhere in the Android app.** A repo-wide grep for
`[Pp]roject` over `app/src` returns 9 incidental hits. No route, no model, no API
path, no Room table.

`RecentsApi.kt:29` makes the omission explicit:

```kotlin
const val WORKSPACES_PATH = "/api/workspaces?is_include_items=false"
```

…with a KDoc saying "The sidebar only shows names, so the parameter is always
sent explicitly and the payload stays one row per workspace." That KDoc is the
thing this task deliberately changes, and the KDoc has to change with it.

## Background — the wire contract (verified against the Zig handlers)

### The one call we do **not** make

`GET /api/workspaces` **already** returns items **and** tasks when
`is_include_items` is true — that is the server default
(`src/http_handlers/workspaces_list.zig:42`, response struct
`WorkspaceWithItemsResponse` at `:8-18`, with `items_count` populated either
way). So the entire feature is reachable from **one** call.

We are not taking it. It fans out to *every* workspace's items and tasks for
*every* workspace the user owns, on every refresh, to render one screen. The Vue
app does the same thing and is paying for it; a phone on a metered connection
should not. The plan follows Vue's *lazy* shape instead: workspaces first, then
the selected workspace's items, then an item's tasks only when it is opened.

### The three calls we do make

**A. Projects for the selected workspace**

`src/main.zig:689`

```
GET /api/workspaces/:workspace_id/items
```

Handler `workspaceItemsListHandler` (`src/http_handlers/workspace_items_get.zig:20-43`)
→ `makeWorkspaceItemListObjectResponse` (`http_response.zig:484-489`):

```json
{
  "items": [
    { "id": "item_…", "workspace_id": "ws_…", "item_type": "kanban",
      "name": "sprint board", "path": "/home/me/…",
      "created_at": "…", "updated_at": "…" }
  ],
  "count": 1
}
```

Field source: `WorkspaceItemFullResponse` (`http_response.zig:8`). No
pagination, no cursor, no query params. `name` and `path` are nullable.

`item_type` ∈ `folder | kanban | design | agent | routine` (the `folder` and
`memory` create branches at `Sidebar.vue:527-548` are unreachable from the
current UI; `memory` was normalised to `standard` in Migration 084).

**B. One project's chats**

`src/main.zig:794`

```
GET /api/workspaces/:workspace_id/items/:item_id/tasks
    ?limit=20&sort_by=updated_at&direction=desc[&cursor=…]
```

Handler doc `src/http_handlers/tasks_list.zig:1-18`; response
`{ tasks: [...], count, has_more, next_cursor }`. `count` is the **page length**,
not a total. Cursor is `"<sort_value>|<id>"` — parse it, never synthesize it.

Each task (`WorkspaceItemTaskResponse`, `http_response.zig:497-545`):

```json
{ "id": "task_…", "name": "…", "workspace_item_id": "item_…",
  "description": "", "task_type": "standard",
  "created_at": "…", "updated_at": "…",
  "is_pinned": false, "pinned_position": 0,
  "kanban_column_id": null, "kanban_position": 0,
  "is_auto_retry_until_stop": "", "last_finish_reason": "" }
```

**The load-bearing fact: `task.id` *is* the session id.** The backend says so in
its own comment (`http_response.zig:531-534`, "where `task.id == session.id`
per the project convention"), and the Vue app relies on it by routing task taps
to `/app/{ws}/projects/{pid}/chat/{taskId}` (`router/index.ts:61-63`).

So a task row already carries **everything a chat row needs** — `id`, `name`,
`updated_at` — and opening one is the *same* `onChatSelected(sessionId)` call the
Recent list makes today. No join, no second lookup, no new route.

**C. Nothing.** The Recent list keeps using `/api/session` untouched.

### Counts — why nothing in this feature prints a number

Vue shows `item.tasks.length` on the collapsed row. There is no cheap way to get
that on Android: the tasks endpoint reports `count` = page length
(`src/http_handlers/tasks_list.zig:18`), so an exact count needs `limit=100`
(the cap, `tasks_list.zig:37`) plus a `has_more` check, **per project**, every
refresh. For a 12-project workspace that is 12 round-trips to render 12 numbers.

**The rule this feature follows: never print a number we cannot get for free.**

So:

| Place | Shows |
|---|---|
| Collapsed project row | nothing |
| `See all chats ›` | nothing — just the words and a chevron |
| The project-chats screen | nothing, until the reader scrolls; the footer then says `Scroll for older chats` / `No older chats` |

The only number that ever appears is the one the *page already in hand* proves:
on the new screen, the footer flips from `Scroll for older chats` to
`No older chats` when `has_more` goes false. That is the existing
`ChatListFooter` (`RecentsSidebar.kt:433-473`) reused verbatim.

If a count turns out to matter, it becomes its own task with a real endpoint
(`count` on the items list, say) rather than a fan-out smuggled into a refresh.

---

## Proposal

### UX

```
┌ Drawer (390dp) ──────────────────────┐
│ ┌ WORKSPACE ───────────────────────┐ │
│ │ kabelweb                        ⌄│ │  ← unchanged
│ └──────────────────────────────────┘ │
│                                      │
│ RECENT                               │  ← unchanged
│   identify-model                2m  │
│   fix the drawer                1h  │
│   …                                  │
│                                      │
│ ── drag handle ────────────────────  │  ← NEW: fixed-weight split
│ PROJECTS                        (7)  │  ← NEW
│   ▾ ⬛ sprint board             4    │  ← NEW (expanded)
│     • rename the drawer         2d  │  ← NEW (preview, first 5)
│     • drawer plan               5d  │
│     • workspace scoping         6d  │
│     • collapse on tablet        8d  │
│     • load more for projects    9d  │
│     See all chats ›                 │  ← NEW: a destination, not a filter
│   ▸ ◆ agentic coding                  │  ← NEW
│   ▸ ◆ design system                   │  ← NEW
│   ▸ ⚙ mobile pipeline                 │  ← NEW
│                                      │
├──────────────────────────────────────┤
│ SIGNED IN AS                         │  ← unchanged
│ ginwa@ginwa.site                     │
│ Log out                              │
└──────────────────────────────────────┘
```

### Why a **fixed-weight split** rather than a resizable one

Vue makes the Recent pane resizable and the Projects pane `flex-1`
(`Sidebar.vue:1430-1457`). A 390dp-wide drawer cannot host two independently
scrollable panes plus a 48-row Recent list plus a Projects list — the Recent list
would get ~120dp, which is four rows.

**Both sections scroll together in one `LazyColumn`,** Recent first, then the
Projects header and its rows. The `Load more` sentinel row at the end of Recent
already exists (`RecentsSidebar.kt:348-355`, `LOAD_MORE_KEY`); the Projects
header becomes a row in the same list rather than a second scroller.

The cost is that on a device with hundreds of chats, Recent pushes Projects
off-screen. The `See all chats ›` destination covers the *reader*-side of that
(there is always a full screen behind the button), but not the *navigation*-side
(the reader must scroll the drawer to reach the project list at all).

The section therefore **defaults to expanded**, matching
`sidebarStore.projectsExpanded`, and the reader can fold it away in one tap. A
sticky header would be the real fix and is a mechanism this codebase does not
have anywhere, so it is not proposed. Revisit after real use.

### State

| State | Owner | Lifetime |
|---|---|---|
| `isProjectsExpanded` (section) | `HomeViewModel.uiState` | process |
| `expandedProjectIds: Set<String>` | `HomeViewModel.uiState` | process |
| `projectChats: Map<String, ProjectChatsPage>` | `HomeViewModel.uiState` | process |
| `projectsLoading` / `projectsError` | `HomeViewModel.uiState` | process |

Expansion state is `rememberSaveable` today only inside `WorkspaceDropdown`
(`RecentsSidebar.kt:481`). Projects expansion is **view-model state, not
composable state**, because a process death must not re-fetch 12 projects'
chats, and because the caches are keyed per project id. This is the same reason
`chatsCursor` is ViewModel state but deliberately *not* in `HomeUiState`
(`HomeViewModel.kt:128-133`).

**One page size, one fetch, two renderers.** `PAGE_LIMIT = 20`. The drawer renders
`page.chats.take(PREVIEW_ROWS)` where `PREVIEW_ROWS = 5`; the project-chats
screen renders the whole page and pages onward. So opening a project in the drawer
fetches 20 rows and shows 5, and the screen picks up from the *same cached page*
rather than refetching. Two different page sizes would mean two cache entries per
project and a "the screen and the drawer disagree" class of bug.

### Behaviours

1. **Tapping the `PROJECTS` header** toggles the section. Default **expanded**,
   matching `sidebarStore.projectsExpanded`.
2. **Tapping a project row** toggles that project's chats. First open fetches
   page 1; a second open is instant from `projectChats` and does **not** refetch
   unless the workspace changed or the pull-refresh ran. The drawer stays **open**.
3. **Tapping a nested chat row** is byte-for-byte the existing chat-row gesture:
   `onChatSelected(id)` + `onOpenChat()`. It closes the drawer and pushes
   `chat/{sessionId}`. **No new code path** — the nested row and the Recent row
   call the same lambda. This is the whole point of the assumption.
4. **Tapping `See all chats ›`** is a **destination**: it closes the drawer and
   pushes `project/{workspaceId}/{itemId}`, which renders that project's chats
   full-screen with scroll paging. The button is shown whenever
   `page.chats.size > PREVIEW_ROWS || page.hasMore` — i.e. whenever the drawer
   is actually hiding something. A project with three chats shows no button,
   because the drawer already showed all three.
5. **Switching workspace** clears `projects`, `expandedProjectIds` and
   `projectChats` for the old workspace before loading the new one — the same
   clear-then-load order `selectWorkspace` already uses for chats
   (`HomeViewModel.kt:248-268`, comment at `:265-267`, "After the state, not
   before").
6. **The project-chats screen pages on scroll** with the server's `next_cursor`,
   and stops on `has_more` — **not** on cursor presence, for the reason the README
   §Recents already documents at length. Its footer is the existing
   `ChatListFooter` reused verbatim.
7. **A failed project fetch keeps the rows it already has** and shows a retry on
   the failed slice only, matching `StaleDataNotice` (`:685-716`). A failed
   *section* fetch shows `SidebarError` (`:760-798`) in the Projects slot.
8. **The worker spinner on a nested row** reuses the existing
   `runningSessionIds: Set<String>` (`RecentsSidebar.kt:116`) — the ids are the
   same session ids, so no new subscription.

### Project type glyphs

`material-icons-extended` is already a dependency (`app/build.gradle.kts:76`)
and the sidebar today uses exactly two icons, `Icons.Filled.ExpandMore` and
`Icons.Filled.Check` (`RecentsSidebar.kt:524`, `:563`). The section adds one
more family:

| `item_type` | Icon | Rationale |
|---|---|---|
| `kanban` | `Icons.Filled.ViewKanban` | the thing it opens |
| `agent` | `Icons.Filled.SmartToy` | Migration 081 "Agent Mode" |
| `routine` | `Icons.Filled.Autorenew` | Migration 084, workspace-level routine |
| `design` | `Icons.Filled.Brush` | design canvas |
| `folder` | `Icons.Filled.Folder` | literal |
| unknown | `Icons.Filled.Folder` | fail soft; a new type must not blank the row |

**No glyph for `folder` projects' entries in v1** — Vue lists folder contents as
sub-entries (`WorkspaceItem.vue` folder branch, fetched via
`GET /api/system/folder?action=list&path=…`, `api/index.ts:511-513`). That is a
second endpoint and a second cache; it is out of scope. A `folder` project simply
expands to its chats.

---

## Implementation chunks

### Chunk 1 — the wire layer

**New file** `app/src/main/java/com/nalar/mobile/projects/ProjectsApi.kt`

- `object ProjectsApi`
  - `const ITEMS_PATH_TEMPLATE = "/api/workspaces/%s/items"`
  - `const TASKS_PATH_LIMIT = 20` (matches `tasks_list.zig` `DEFAULT_PAGE_SIZE`)
  - `fun itemsPath(workspaceId: String): String` — path segment through
    `UriEncoding.encode` (`NalarNavGraph.kt:146-163`), **not** `URLEncoder`
  - `fun tasksPath(workspaceId: String, itemId: String, cursor: String?, limit: Int = TASKS_PATH_LIMIT): String`
  - `fun parseItems(body: String): List<ProjectSummary>`
  - `fun parseProjectChats(body: String, itemId: String): ProjectChatsPage`

`fun itemsPath` must **not** be a `const` template with `%s`: a workspace id
containing a `/` would silently produce a different route. The encoder is
non-const (`UriEncoding.encode` is a function), so this is a function by
construction.

**New file** `app/src/main/java/com/nalar/mobile/projects/ProjectsModels.kt`

```kotlin
data class ProjectSummary(
    val id: String,
    val workspaceId: String,
    val itemType: String,
    val name: String,
    val path: String,
) { val displayName get() = name.trim().ifEmpty { "Untitled project" } }

data class ProjectChat(
    val id: String,          // == the session id
    val projectId: String,
    val name: String,
    val updatedAtEpochMillis: Long,
    val isPinned: Boolean,
) { val displayName get() = name.trim().ifEmpty { "New Chat" } }

data class ProjectChatsPage(
    val chats: List<ProjectChat>,
    val hasMore: Boolean,
    val nextCursor: String?,
)
```

Every timestamp goes through the **existing** `RecentsApi.parseTimestampEpochMillis`
(`RecentsApi.kt:190-213`) — it already handles the SQLite-UTC-string and
bare-unix-millis forms. Do not re-implement it. Make it `internal` if it is
private today; do not copy it.

**New file** `app/src/main/java/com/nalar/mobile/projects/ProjectsClient.kt`

Mirrors `RecentsClient.kt` exactly: `RecentsResult.Loaded | SignedOut |
Unavailable`, cookie-only auth from `SessionCookieStore`, no `Authorization`
header, no CSRF (`:61-67`).

⚠️ **`RecentsClient.messageForStatus` hard-codes the word "sidebar"**
(`RecentsClient.kt:86-90`). A projects client that reuses those strings will
say *"The server could not load your sidebar."* on a projects failure. Either
give `ProjectsClient` its own messages, or parameterise the shared one. The plan
prefers a separate small `projectsMessageForStatus` — a wrong word in a user-
facing error is the kind of lie this codebase's comments repeatedly refuse.

**No `RecentsCache` change in this chunk.** See Chunk 3.

### Chunk 2 — the ViewModel

**Edit** `HomeViewModel.kt`

- `HomeUiState` (`:28-74`) gains: `isProjectsExpanded: Boolean = true`,
  `projects: List<ProjectSummary>`, `expandedProjectIds: Set<String>`,
  `projectChats: Map<String, ProjectChatsPage>`,
  `isLoadingProjects: Boolean`, `projectsError: String?`
- New private `projectsJob: Job?` alongside `workspacesJob`/`chatsJob` (`:106`)
- `loadProjects(workspaceId)` — called from `selectWorkspace` (`:248-268`) and
  from `refresh` (`:168-222`) **after** the state clears, never before
- `toggleProjectExpanded(itemId)` — on first open calls `loadProjectChats`;
  afterwards only flips the id in the set
- `loadMoreProjectChats(itemId)` — guards: not loading, no cursor, no
  `hasMore`, correct workspace, and a per-item generation counter
- `ensureProjectChatsLoaded(itemId)` — what the **new screen** calls on mount.
  No-ops when `projectChats` already holds the project, so
  drawer-expand → `See all` → screen is one fetch, not two. A deep link into
  `nalar://project/…` with nothing cached falls through to a real fetch.
- `onSignedOut` (`:484-506`) clears the new state alongside the existing resets
- `factory` (`:521-535`) composes `ProjectsClient(RecordingAuthTransport(HttpsAuthTransport(AuthConfig.BASE_URL)))`
  — the `RecordingAuthTransport` wrap is what makes the new calls show up in the
  in-app network inspector for free

The **per-item generation counter is not optional.** `loadMoreChats` guards its
appends with `chatsGeneration` (`:135-141`); a project that is expanded, then
collapsed, then expanded again while a page is in flight will otherwise append
page 2's rows to a project whose page 1 was replaced underneath it. It is worse
now that the screen pages too: the drawer's `See all` hands the project to a
screen that may page it while a drawer-initiated fetch is still in the air. This
is the same class of bug as the one that made the empty-refresh guard necessary
in `ChatsList.vue:455-497`.

### Chunk 3 — the cache, and the honest reason

`RecentsCache.kt:13-27` says, in a KDoc, that its scope is **exactly two
endpoints** and that "adding a third endpoint here should be a deliberate change
to this interface, not a side effect of some new caller."

This task is that deliberate change. Two options:

| | Scope | Cost |
|---|---|---|
| **(a) Extend `RecentsCache`** | Add `readProjects` / `writeProjects` / `readProjectChats` / `writeProjectChats` to the existing interface, plus a Room entity + DAO. | Violates the stated contract; the contract exists to keep this interface honest. |
| **(b) New `ProjectsCache`** (chosen) | Its own `interface ProjectsCache` + `RoomProjectsCache` + a table in `NalarCacheDatabase`, encrypted with the **same** `SealingCipher` and key alias. | One more interface, but `RecentsCache`'s KDoc stays true. |

Choose **(b)**. The existing KDoc is a correct and useful warning; "we read it
and decided to break it anyway, in place" is strictly worse than adding the
interface the warning asked for.

Cache-then-revalidate, matching the app's existing posture: paint projects from
cache on workspace switch, then revalidate.

### Chunk 4 — the UI

**Edit** `RecentsSidebar.kt`. The 22-param signature (`:84-125`) is already at
the limit, and this feature adds six more pieces of state plus three callbacks.
**Do not grow it to 31.** Extract a holder:

```kotlin
@Stable
class ProjectsState(
    val expanded: Boolean,
    val items: List<ProjectSummary>,
    val expandedItemIds: Set<String>,
    val chats: Map<String, ProjectChatsPage>,
    val isLoading: Boolean,
    val errorMessage: String?,
) {
    val visibleItems: List<ProjectSummary>
}

@Stable
class ProjectsActions(
    val onToggleSection: () -> Unit,
    val onToggleItem: (String) -> Unit,
    val onOpenAllChats: (workspaceId: String, itemId: String) -> Unit,
    val onRetry: () -> Unit,
)
```

Two new params on `RecentsSidebar` (`projects: ProjectsState`,
`projectActions: ProjectsActions`) instead of nine. This is the same move the
drawer already made for auth (`:117-125` is a block of tightly related auth
params), just taken one step further.

`onOpenAllChats` is a **destination** callback, so it joins `onOpenChat` and must
be wired at **both** call sites, permanent drawer included.

New private composables, following the file's existing conventions (private,
`modifier: Modifier = Modifier` **last**, long prose KDoc explaining *why*, a
`testTag` on every interactive node, inline shape/colour literals rather than
`NalarShapes`):

- `ProjectsSectionHeader(expanded, itemCount, onToggle)` — `labelMedium` eyebrow,
  `NalarDim`, `Icons.Filled.ExpandMore` (expanded → rotated 90°), count in
  `NalarMuted`
- `ProjectRow(project, isExpanded, isRunning, onClick)` — glyph, name, active
  fill, trailing expand/collapse chevron
- `ProjectChatRow(chat, isSelected, isRunning, onClick)` — reuse the *visual*
  language of `ChatRow` (`:580-683`) at a smaller indent. It calls the same
  `onChatSelected` + `onOpenChat` pair, which is what keeps this free of new
  navigation code.
- `SeeAllChatsRow(projectId, onClick)` — `testTag("project_see_all_$projectId")`,
  `Icons.Filled.ChevronRight`, no number (see §"Counts"). Rendered only when the
  drawer is actually hiding rows.
- `ProjectsEmpty(...)` / `ProjectsError(...)` — reuse `SidebarPlaceholder`
  (`:718-758`) and `SidebarError` (`:760-798`) with the Vue strings:
  `No projects yet — create one on the web app.` (the Vue "+ above" wording
  refers to a button this task does not add) and `No workspace selected.`

**Restructure `SidebarBody`'s scroller** from one `LazyColumn` of chats
(`:285-359`) to one `LazyColumn` holding: recent chat rows → the existing
`LOAD_MORE_KEY` sentinel (`:348-355`) → the Projects header → project rows →
nested chat rows (`.take(PREVIEW_ROWS)`) → `SeeAllChatsRow`.

The `loadMoreLatched` mechanism (`:298-327`) is keyed off
`lastVisibleIndex >= totalItemsCount - 1 - LOAD_MORE_INDEX_THRESHOLD`; that
threshold must now be evaluated **only when the last visible item is a recent
chat**, or scrolling to the bottom of the Projects section will page Recent
forever. Add a `contentType` per row type so the watcher can tell them apart —
the `contentType` parameter is already in use (`:348`).

**Edit** `shell/RecentsDrawer.kt` — this is now the only wiring point.

Since PR #682, `RecentsDrawerContent` (`RecentsDrawer.kt:42-…`) is the single
shared wrapper the drawer content lives in, with **two** call sites: the shell's
permanent drawer and the one the chat route's hamburger opens. Its own KDoc says
why (`:29-40`): *"there are two of them — the shell's own drawer, and the one the
chat route's hamburger opens — and a second copy of this wiring would be a second
copy of every drawer bug."*

Add `projects: ProjectsState` and `projectActions: ProjectsActions` here, and
forward them into its `RecentsSidebar(…)` call. **One edit reaches both
drawers.** Do not wire `MobileHomeScreen`'s two call sites separately — that is
exactly the duplication the KDoc warns against, and it would leave the Projects
section missing from the chat screen's drawer.

`onOpenAllChats` is a **destination** callback, so it must also be supplied at
**both** of `RecentsDrawerContent`'s call sites (`NalarNavGraph.kt`, the shell
branch and the `chat/{sessionId}` branch) — the permanent drawer gets no
`onOpenChat` today because it has no sheet to dismiss, but navigating is
meaningful there too.

### Chunk 5 — the project-chats screen (new destination)

This is the chunk that exists because the human chose **"a button, not a Load
more row"**. It is the only new destination this feature adds.

**Edit** `NalarNavGraph.kt`

```kotlin
const val PROJECT = "project/{workspaceId}/{itemId}"
const val ARG_WORKSPACE_ID = "workspaceId"
const val ARG_ITEM_ID = "itemId"
fun project(workspaceId: String, itemId: String): String =
    "project/${UriEncoding.encode(workspaceId)}/${UriEncoding.encode(itemId)}"
```

Both ids go through `UriEncoding.encode` (`:146-163`) — the existing
unreserved-only encoder — and a deep link `nalar://project/{workspaceId}/{itemId}`
so the screen is linkable, matching the app's existing
`nalar://chat/{sessionId}` / `nalar://network` policy (README §Deep links).

The new `composable(...)` is a **sibling** of `NalarRoutes.CHAT` (`:306-305`),
not nested under it. Its Back behaviour falls out of the existing
`goBackToPreviousOrShell()` (`:120-136`) for free: Back from the project screen
returns to the shell, and Back from the shell exits — no new `BackAction`, no
edit to `backActionFor`.

**New file** `app/src/main/java/com/nalar/mobile/projects/ProjectChatsScreen.kt`

- A `Scaffold` with a `TopAppBar` (back arrow + the project name) over one
  `LazyColumn` of `ProjectChatRow`s.
- It **reuses `HomeViewModel`'s `projectChats` map** rather than owning a second
  copy. Opening it after a drawer expansion is therefore instant; opening it from
  a deep link with nothing cached does a single fetch.
- Its `loadMoreProjectChats(itemId)` is the same ViewModel function the drawer
  would have called — this is why there is no "Load more" row in the drawer at
  all.
- The footer row is the **existing** `ChatListFooter` (`RecentsSidebar.kt:433-473`),
  moved from `private` to `internal` in `RecentsSidebar.kt`, unchanged.
- The scroll watcher and its latch are the same pattern as `SidebarBody`
  (`:298-327`), with its own `contentType` sentinel — the two lists must not
  share a latch, or scrolling the screen would page the drawer.
- Empty state: `No chats in this project yet.` The endpoint can legitimately
  return zero for a fresh `kanban` or `agent`.

**Edit** `NalarNavGraph.kt` `:276-301` — pass
`onOpenAllChats = { ws, item -> navController.navigate(NalarRoutes.project(ws, item)) }`
into `MobileHomeScreen`. Note the ordering already in that block: for chat the
code calls `onOpenSession(sessionId)` *before* `navigate`, with a comment saying
the route stays on the back stack so returning must not show an empty transcript
(`:283-289`). **Do the same here** — call `onOpenProjectChats(itemId)` first, or
Back from the project screen returns to a project that has no chats painted.

### Chunk 6 — tests

**Unit** (`app/src/test/java/com/nalar/mobile/projects/`) — JUnit 4,
`org.junit.Assert.*`, hand-rolled fakes, the two-`TestCoroutineScheduler`
`Schedulers` helper from `HomeViewModelCacheTest.kt:37-49`:

- `ProjectsApiTest`
  - `itemsPathEncodesAWorkspaceIdWithQueryUnsafeCharacters`
  - `parseItemsReadsEveryItemTypeAndSkipsRowsWithoutAnId`
  - `parseItemsLeavesNameAndPathEmptyWhenTheServerSendsNull` — the
    `stringField` convention (`RecentsApi.kt:198-199`) maps JSON `null` to `""`;
    `ProjectSummary.displayName` must then say "Untitled project"
  - `tasksPathOmitsABlankCursor` — the same trap as `chatsPath`
    (`RecentsApi.kt:56-57`)
  - `parseProjectChatsStopsOnHasMoreNotOnCursorPresence` — the README §Recents
    decoy, pinned on the **projects** path so a future reader of this file does
    not have to know it from the chats test
  - `parseProjectChatsReadsTheSameTimestampFormatAsTheChatList`
- `ProjectsClientTest` — cookie header sent, `401` → `SignedOut`, and
  `projectsFailureMessagesDoNotSaySidebar` (the `messageForStatus` string trap)
- `ProjectsModelsTest` — `displayName` fallbacks, `hasMore` arithmetic
- `HomeViewModelProjectsTest`
  - `switchingWorkspaceClearsThePreviousWorkspacesProjects`
  - `expandingAProjectFetchesItsChatsOnceAndReplaysFromStateAfterwards`
  - `openingTheProjectScreenAfterTheDrawerAlreadyFetchedDoesNotRefetch` — the
    `ensureProjectChatsLoaded` contract, and the reason the plan uses one page
    size
  - `openingTheProjectScreenFromADeepLinkFetchesWhenNothingIsCached` — the
    negative half of the same test
  - `closingAProjectMidFlightDiscardsTheLatePage` — the generation-counter test
  - `aFailedProjectPageKeepsTheRowsItAlreadyHas` — the stale-while-revalidate
    contract, same shape as `HomeViewModelCacheTest`
  - `signingOutClearsProjects`
- `RoomProjectsCacheTest` — Robolectric, mirroring `RoomRecentsCacheTest.kt`

**Instrumentation** (`app/src/androidTest/java/com/nalar/mobile/projects/`):

- `ProjectsSectionTest`
  - `projectsSectionShowsTheSelectedWorkspacesItems`
  - `tappingAProjectRevealsItsChatsAndLeavesTheDrawerOpen` — mirrors
    `RecentsSidebarTest.kt:62-88`
    (`workspaceSelectionScopesRecentsAndKeepsTheDrawerOpen`)
  - `tappingANestedChatClosesTheDrawerAndOpensTheChat` — the drawer test. Note
    the README rule from `RecentsSidebarTest.kt:441-443`: a closed
    `ModalDrawerSheet` still exists in the semantics tree, so
    `assertIsNotDisplayed()`, **not** `assertDoesNotExist()`.
  - `theDrawerShowsNoSeeAllButtonWhenItAlreadyShowsEveryChat` — the
    `page.chats.size > PREVIEW_ROWS || page.hasMore` gate
  - `tappingTheProjectsHeaderCollapsesAndExpandsTheSection`
  - `scrollingTheProjectsSectionDoesNotPageTheRecentList` — the shared-`LazyColumn`
    hazard from Chunk 4, pinned
  - `aWorkspaceWithNoProjectsSaysSo`
  - `aFailedProjectsFetchShowsARetryAndKeepsTheRecentList`
  - `everyProjectTypeRendersAGlyph` — so a new `item_type` cannot silently
    render a nameless row
- `ProjectChatsScreenTest`
  - `seeAllClosesTheDrawerAndOpensTheProjectChatsScreen`
  - `theProjectScreenListsTheProjectsChatsAndPaginatesOnScroll`
  - `theFooterSaysNoOlderChatsWhenTheServerHasNoMore` — the `has_more`
    terminator, visible in the UI rather than only in a parser test
  - `aFailedPageKeepsTheRowsAndOffersRetryInPlace` — no error banner over real
    rows
  - `aProjectWithNoChatsSaysNoChatsInThisProjectYet`
- `NalarNavGraphProjectTest`
  - `backFromTheProjectChatsScreenReturnsToTheShell`
  - `backFromTheShellAfterTheProjectScreenStillExits` — the
    `goBackToPreviousOrShell()` contract (`:120-136`) must not dead-end
  - `theProjectChatsScreenIsReachableFromItsDeepLink`
  - `returningFromTheProjectScreenFindsTheProjectStillExpandedInTheDrawer` —
    the reason `onOpenProjectChats` is called before `navigate`

**CI** — `./gradlew :app:testDebugUnitTest` and the connected-instrumentation
job already exist (merged task `task_1790399629648_3`); this chunk adds no new
pipeline.

---

## What was actually built

**Files added**

| File | What |
|---|---|
| `projects/ProjectsApi.kt` | the two paths, both parsers, the page merge |
| `projects/ProjectsModels.kt` | `ProjectSummary`, `ProjectChat`, `ProjectChatsPage`, `ProjectTypes` |
| `projects/ProjectsClient.kt` | cookie-only transport, its own error wording |
| `projects/ProjectsCache.kt` | the interface + `RoomProjectsCache` |
| `projects/ProjectRows.kt` | `ProjectsState`, `ProjectsActions`, and the four row composables |
| `projects/ProjectChatsScreen.kt` | the destination behind `See all chats` |
| `cache/ProjectsCacheDao.kt` | the two tables' SQL, replace-not-merge |
| `projects/ProjectsApiTest.kt` (22) | the wire, pinned |
| `projects/ProjectsClientTest.kt` (10) | auth, status mapping, the "never say sidebar" rule |
| `projects/HomeViewModelProjectsTest.kt` (17) | the state machine |
| `androidTest/…/ProjectsSectionTest.kt` (10) | the gestures |
| `androidTest/…/ProjectChatsScreenTest.kt` (8) | the screen and its footer |

**Files changed:** `recents/HomeViewModel.kt`, `recents/RecentsApi.kt`,
`recents/RecentsCache.kt`, `recents/RecentsSidebar.kt`,
`shell/RecentsDrawer.kt`, `shell/MobileHomeScreen.kt`,
`network/NalarNavGraph.kt`, `cache/CacheEntities.kt`,
`cache/NalarCacheDatabase.kt`, `MainActivity.kt`, and four existing test files.

**Verification:** `:app:compileDebugKotlin` and `:app:testDebugUnitTest` pass —
**779 tests, 0 failures**, of which 49 are new.
`:app:assembleDebugAndroidTest` compiles; the instrumentation tests themselves
have not been executed (see below).

### Two deviations from this plan, and why

**1. The Projects section is rendered inside the recents `LazyColumn`, and the
recents empty/error state became a *row* rather than a weighted sibling.**

The plan described the restructure; this is the same idea, and the detail worth
recording is *why the chats-empty state moved*. It used to be a
`Modifier.weight(1f)` placeholder that took the whole remaining height. Now that
Projects sits below it, a weighted placeholder would push Projects off-screen
precisely when the reader most wants somewhere else to go — while the recents
are loading, empty or broken. So it is a row in the same list, and the paging
trigger is scoped to the chat region's index range rather than to
`totalItemsCount`. That scoping is not cosmetic: the old
"last index is near totalItemsCount" test would have fired every time the reader
scrolled to the bottom of the *Projects* section, paging chats they are not
looking at, forever.

**2. `See all chats ›` carries no number — unchanged from the plan, but now
load-bearing in a new place.**

`PREVIEW_ROWS` is 5 and `TASKS_PAGE_LIMIT` is 20, so the drawer fetches 20 rows
and shows 5. The button appears when `chats.size > 5 || hasMore`. Nothing on
screen ever prints a count, including the new screen's footer, which is the
existing `ChatListFooter` reused verbatim.

### The environment, which is a real problem for this repo

**The Android build does not run on this machine out of the box.** The default
JDK is **openjdk 27**, and Gradle 8.10.2's Kotlin DSL throws
`IllegalArgumentException: 27` while compiling `build.gradle.kts` — before any
app code is reached. Verified that **unmodified `main` fails identically**, so
this is pre-existing and not caused by this work.

It is also **not caught by CI**: neither `.github/workflows/ci.yml` nor
`ci-cancel-on-merge.yml` references `gradlew`, `android_mobile` or `setup-java`.
So an Android build has no automated verification at all today.

Everything above was verified with a **Temurin JDK 21** unpacked to
`/tmp/jdk/jdk-21.0.12.1+1` (a scratch dir; the system was not modified):

```bash
export JAVA_HOME=/tmp/jdk/jdk-21.0.12.1+1
export PATH="$JAVA_HOME/bin:$PATH"
./gradlew :app:testDebugUnitTest
```

**Worth fixing on its own card:** pin a JDK toolchain in
`android_mobile/build.gradle.kts` and add a workflow that runs
`:app:testDebugUnitTest`. The first makes the build work for anyone with a
recent JDK; the second stops the next Android change from being unverifiable.

## Risks

| Risk | Mitigation |
|---|---|
| **Route-order shadowing.** `matchRoute` walks routes in registration order. | Two new paths are built by hand, so both must be encoded. The API path is `/api/workspaces/{ws}/items/{item}/tasks`; the Compose route is `project/{workspaceId}/{itemId}`. Every segment goes through `UriEncoding.encode` (`NalarNavGraph.kt:146-163`), which is unreserved-only, so a `/` in an id cannot split a segment. Pinned by `itemsPathEncodes…` and by the deep-link instrumentation test. |
| **Empty slice as SQL NULL.** Not reachable — the Android client is a JSON consumer and sends no SQL. But `name`/`path` arrive as JSON `null`, which the *parser* must map to `""`, not to a crash or a literal `"null"`. Pinned by `parseItemsLeavesNameAndPathEmptyWhenTheServerSendsNull`. |
| **The scroll watcher paging Recent from the bottom of Projects.** | `contentType` per row type + a type check inside the `snapshotFlow`. Pinned by `scrollingTheProjectsSectionDoesNotPageTheRecentList`. |
| **The screen and the drawer paging the same project from two scrollers.** | Each list owns its own `contentType` sentinel and its own latch. They never share one. |
| **Back from the project screen lands on a project with no chats painted.** | `NalarNavGraph.kt:283-289` already documents this trap for chat ("open the session *before* navigating"). The same ordering is required for the project route. Pinned by `returningFromTheProjectScreenFindsTheProjectStillExpandedInTheDrawer`. |
| **`onOpenAllChats` missing from a drawer.** | It must be supplied at **both** of `RecentsDrawerContent`'s call sites in `NalarNavGraph.kt` (the shell branch and the `chat/{sessionId}` branch). The shell's permanent drawer gets no `onOpenChat` because it has no sheet to dismiss, but navigating is meaningful there too. |
| **The Projects section only reaching one of the two drawers.** | `RecentsDrawerContent` (`shell/RecentsDrawer.kt:42`) is the single shared wrapper; the two params go there, not into `MobileHomeScreen`'s two call sites. Its KDoc (`:29-40`) exists precisely to stop a second copy of this wiring. |
| **`RecentsCache` scope creep.** | Chunk 3 chooses a separate `ProjectsCache` specifically so the existing KDoc stays true. |
| **The `RecentsSidebar` 22-param wall.** | Chunk 4 introduces `ProjectsState` / `ProjectsActions`; two new params, not nine. |
| **The Projects section is off-screen on a chat-heavy workspace.** | Mitigated by the `See all chats ›` destination: the reader is never trapped in the drawer, because there is a full screen behind the button. What is *not* mitigated is not being able to see the project list at all without scrolling; revisit after real use. |

## Open questions for the reviewer

The four design questions from the first draft are answered (see the decision
table at the top). Questions 1 and 2 were then put back to me; both are now
decided with reasons rather than left open.

### 1. Route shape → **fully qualified: `nalar://project/{workspaceId}/{itemId}`**

I checked whether the workspace could be left out and resolved from app state.
It cannot, and the reason is structural rather than stylistic:

> **There is no endpoint that resolves a project by id alone.** Every item route
> in `src/main.zig:688-792` is nested under `/api/workspaces/:workspace_id/items/…`
> — including the read one, `GET /api/workspaces/:workspace_id/items/:item_id`
> (`:691`). There is no `GET /api/items/:id` and no `GET /api/items/:id/tasks`.

So `nalar://project/{itemId}` cannot build its own request. A deep link can
arrive at a **cold process** (a link tapped in another app, or
`adb shell am start`), and at that moment `HomeViewModel` has not run and
`workspaces` is empty — there is nothing to resolve the workspace from. The only
escape would be `GET /api/workspaces?is_include_items=true` and grep it, which is
precisely the every-workspace-every-task fetch §"The one call we do **not** make"
refuses to do.

The contrast with the existing routes is what makes this principled rather than
arbitrary. `nalar://chat/{sessionId}` is genuinely single-id because
`GET /api/llm/session/{id}/messages?limit=1` needs nothing but the session id. A
project is not single-id, so it takes two.

This also means **one builder, no special case**: the in-app route needs both ids
anyway, because they are the API path segments, so the deep link and the route
have the same shape and the same `UriEncoding.encode` treatment.

### 2. Own ViewModel or shared → **shared `HomeViewModel`, screen fed a narrow slice**

The instinct is that a separate ViewModel is "cleaner". On this path it is both
slower and riskier. The actual arithmetic:

| Cost | Shared | Separate ViewModel |
|---|---|---|
| Requests on the hot path (drawer-expand → `See all`) | **1** | 2 — a second identical fetch, unless seeded |
| Memory | ~2.4 KB per project (20 rows × ~120 B); ~48 KB at 20 projects | same |
| Paging rules to keep correct | **one copy** | two, free to disagree |
| Recomposition of a back-stack `LazyColumn` | churns on unrelated `HomeUiState` emissions | isolated |

**Network dominates.** A round-trip to `agent.ginwa.site` costs tens to hundreds
of milliseconds and metered bytes. A duplicated request on the most common tap in
the feature is real; the memory figure is noise next to the Room chat cache the
app already keeps.

**The recomposition cost is free to remove, and is the actual reason people
reach for a second ViewModel.** `HomeUiState` is one `StateFlow` of one data
class, so every field change emits a fresh object and every collector recomposes.
The fix is to not hand the screen the whole state:

```kotlin
// in NalarNavGraph, for the project route only
val page by homeViewModel.uiState
    .map { it.projectChats[itemId] }        // StateFlow<ProjectChatsPage?>
    .collectAsStateWithLifecycle()
```

A `LazyColumn` whose `List` reference is unchanged does not rebuild, so the screen
gets a stable input *and* a shared owner. No second ViewModel required.

**What a second ViewModel would really cost:** it cannot share `projectChats`
without the shell's cache, so it duplicates the paging job, the generation
counter, the error state, the cursor map, and the "a page that adds nothing ends
the scroll" rule — five chances to re-introduce the exact bug the chat pager
already got wrong once (`next_cursor` vs `has_more`), now in two places that can
drift apart.

One refinement that follows from this: **the per-project cursor stays OUT of
`HomeUiState`**, following the precedent at `HomeViewModel.kt:128-133` ("it is
protocol, not view state"). A private `Map<String, String>` keyed by item id.

Worth revisiting only if projects ever grow their own mutations (rename, delete,
pin) — at which point a dedicated ViewModel stops being duplication and starts
being ownership.

### 3. `PREVIEW_ROWS = 5` → accepted, flagged for tuning after a week of use

## References

- Vue: `Sidebar.vue:1430-1457`, `ProjectsList.vue:365-412` / `:489-604`,
  `WorkspaceItem.vue:588-709` / `:715-812`, `WorkspaceItemTaskRow.vue:158-325`,
  `api/index.ts:553-559` / `:677-728`, `router/index.ts:61-78`
- Android: `RecentsSidebar.kt` (all), `MobileHomeScreen.kt:155-162` / `:188-275` / `:305-321`,
  `HomeViewModel.kt:28-74` / `:248-268` / `:400-481` / `:484-506` / `:521-535`,
  `RecentsApi.kt:29` / `:45-61` / `:190-213`, `RecentsClient.kt:49-93`,
  `RecentsCache.kt:13-27`, `NalarNavGraph.kt:65-76` / `:255-301`, `ui/Color.kt:5-17`,
  `ui/Theme.kt:37-86`
- Backend: `src/main.zig:689` / `:794`, `http_response.zig:8` / `:484-489` / `:497-545`,
  `workspace_items_get.zig:20-43`, `tasks_list.zig:1-18`, `workspaces_list.zig:8-18` / `:42`,
  `llm_history.zig:459-484` / `:4431-4439`
- Prior art: `docs/plans/2026-09-22-revamp-workspace-ui-dropdown-projects.md` (the
  Vue dropdown + Projects section this mirrors)
