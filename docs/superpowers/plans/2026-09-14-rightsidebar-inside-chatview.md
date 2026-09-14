# RightSidebar inside ChatView — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the right-sidebar ownership from `AppLayout` (global, currently DISABLED since 2026-06-29) into `ChatView` (per-chat, per-cwd). The sidebar becomes a contextual companion to the active chat: `Diff` (git working-tree changes, the only feature today) + `Preview` (agent `present_files` / `show_preview` output, sibling task in progress) + `Detail` (click a tool row → see full output). Closed by default on narrow screens, toggleable via header button, width resizable + persisted per-chat-type.

**Why ChatView-owned, not AppLayout-owned:** today `rightSidebarCwd` in `AppLayout.vue:2061` is derived from `activeWorkspaceItem.path || chatSessionCwd` — a global guess that breaks when kanban-task chat, agent chat, and standalone chat each have different cwds. `ChatView` already owns `sessionId / sessionCwd / gitStatus / effectiveCwd` (L1000+, L1040-1065) and the SSE bus filter (`event.session_id===sid` L474-483). Co-locating the sidebar kills the cwd-plumbing bug class entirely.

**Spec:** this document IS the spec (no separate design doc — approved on kanban card `rightsidebar inside chatview component` moving to `in_review_planning`).

**Worktree:** `/home/ginwa/.config/nalar/.worktrees/rightsidebar-inside-chatview-component-1789413707849` on branch `worktree/rightsidebar-inside-chatview-component-1789413707849`.

**Base:** `origin/main` at `4f1f345c` (2026-09-14).

---

## 0. Current state (verified 2026-09-14, sub-agent survey)

| Area | File | State |
|---|---|---|
| `ChatView.vue` | `src/apps/desktop/src/components/views/ChatView.vue` (4344 lines) | Root is 2-pane `flex` with NO right column. Main chat col `flex-1 min-w-0` L3001-3004. Only right slide-over is `SubAgentPeekHost` L3984-3998 (gated on `nav.peekPanel && !embedded`). |
| `RightSidebar.vue` | `src/apps/desktop/src/components/shell/RightSidebar.vue` (430 lines) | DEAD CODE. Import + mount commented out `AppLayout.vue:5,2903-2912` (`// DISABLED 2026-06-29 — task disable-rightsidebar-vue`). Tabs `Explorer\|Git\|Skills` L60-79, `props:{cwd?,width?}`, emits `file-click/skill-click/code-editor-file-click/resize`. Git list via `api.getGitChanges(cwd)` L141 on `watch(cwd,{immediate:true})`. |
| `GitChanges.vue` | `src/apps/desktop/src/components/git/GitChanges.vue` | Standalone duplicate of the Git tab (adds Stage/Unstage buttons RightSidebar lacks). No importer found — likely also unmounted. |
| `GitFileViewer.vue` | `src/apps/desktop/src/components/git/GitFileViewer.vue` (602 lines) | LIVE but fullscreen overlay, not inline pane. Mounts `AppLayout.vue:2404-2413` on `currentView==='gitfile'`. `parseUnifiedDiff()` L115-220, `openMiniChat()` L52-89 → `emit('submitReview')` → `AppLayout:868-882` sends review text into active chat via `api.sendChatMessage`. |
| `DiffView.vue` | `src/apps/desktop/src/components/tool_outputs/_shared/DiffView.vue` (509 lines) | NOT git — renders `before/after` strings for `TextReplace` tool outputs. `ChatView.vue:3554-3561` fallback. Split/unified toggle in `localStorage:diffview.mode`. |
| Backend git | `src/http_handlers/git_*.zig` (`changes/status/file_diff/file_read/stage/unstage/branches_list/pr_create/worktree_info`) + routes `src/main.zig:555-560` | REST only. `GET /api/git/changes?path=`, `GET /api/git/file/diff?path=&file=&staged=`, `POST /api/git/stage|unstage`. No SSE, no store. `git_changes.zig:15` → `{is_git_repo,branch,staged,modified,untracked}` via `git status --porcelain`. `git_file_diff.zig:16-56` → `git -C <path> diff [--cached] -- <file>` + `buildNewFileDiff()` synthetic header for untracked files. |
| `present_files` | sibling task `agent-tool-present-files` (in progress) | NO backend match for `present_files` in `src/` as of survey. Closest analogue: `show_preview` tool (`src/modules/agent/tools/show_preview.zig` + `src/agentic_loop/tools_exec_show_preview.zig`, registered `tools_equipped.zig:240`). Plan assumes Preview tab consumes whatever envelope that task lands (`<present_files>` or `<show_preview>`); Phase 1 must NOT block on it. |
| State | `src/apps/desktop/src/stores/sidebar.ts` | Only width persistence (`nalar-right-sidebar-width`). No visibility / tab / selection state. |
| Wrappers | `StandardTaskChatView.vue` (73 lines), `AgentChatView.vue` (54 lines) | Thin forwarders to `<ChatView>` — inherit the sidebar for free once ChatView owns it. |

Key constraint: `ChatView.vue` is already 4344 lines. Do NOT grow it — new sidebar code lives in NEW files under `components/views/chat_right_sidebar/`.

---

## Global Constraints

- **Cross-platform**: frontend-only change, but any Zig touch (Phase 4 SSE) MUST verify `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc` + `-target aarch64-macos -lc`.
- **No `// NEW (plan: ...)` tags** in source. Explain *why*, not *when*.
- **No port 8081**: functional tests boot isolated binary via `tests/functional/harness.py` (free port 8080..8199, tmpdir HOME). Never `nohup ... --port 8080` + curl.
- **Behavioural tests only**: Vitest `@vue/test-utils` `mount` + `setActivePinia(createPinia())`; mock fetch via `vi.fn()` returning `{ok,status,json,text}`. No `expect(source).toContain(...)` static-contract tests.
- **TDD discipline**: failing test → minimal code → commit, per task.
- **No ChatView.vue bloat**: ChatView edits limited to (a) right-column mount point, (b) toggle button in header/composer toolbar, (c) `useChatRightSidebar` composable wiring. Everything else in new files.

---

## 1. Proposed UX

```
┌ ChatView (flex row) ────────────────────────────────┐
│ ┌ main (flex-1 min-w-0) ┐ ┌ sidebar (w-80..w-[480]) ┐ │
│ │ header + toggle [◫]   │ │ tabs: Diff|Preview|Detail│ │
│ │ messages (unchanged)  │ │ ─────────────────────── │ │
│ │ composer (unchanged)  │ │ tab content (scroll)    │ │
│ └───────────────────────┘ │ ↕ resize handle (left)  │ │
└───────────────────────────┴─────────────────────────┘
```

- **Toggle**: header button `◫` (and `Cmd/Ctrl+B` shortcut) flips `isOpen`. `embedded` and `hideInput` (peek) modes force closed — peek already owns the right edge.
- **Tabs**:
  - `Diff` (default when dirty, badge = change count): file groups `Staged / Changes / Untracked` (reuse `GitChanges.vue` markup, NOT RightSidebar's button-less variant). Click file → inline diff below the list (NOT fullscreen route). Keep `Wrap` toggle + `+added/-removed` stats from `GitFileViewer`. Keep `openMiniChat → submitReview` flow but emit upward to ChatView (which owns `sessionId`, so the "no active chat" no-op in `AppLayout:868-882` disappears).
  - `Preview` (default when agent presents files, badge = file count): renders `present_files` / `show_preview` payloads. Phase 1 = placeholder empty-state (`No preview yet — agent-presented files will appear here`) so Phase 1 never blocks on the sibling tool task. Phase 3 wires the real payload.
  - `Detail` (default when user clicks a tool row in messages): shows the clicked tool's full output (`TextReplace` diff via existing `DiffView`, `Bash` stdout, etc.). Click-again or `✕` returns to previous tab. This is the highest-value tab (kills the "scroll up to find that output" pain) and the cheapest (data already in `messageGroups`).
- **Responsive**: `< 1024px` → sidebar becomes overlay drawer (absolute right, shadow, `✕` closes). `>= 1024px` → inline flex column squeezing messages (messages keep `min-w-0`, VirtualScroller unaffected).
- **Persistence** (localStorage, per chat-type key suffix): `width` (reuse `nalar-right-sidebar-width`), `open` (`nalar-chat-right-sidebar-open:<type>`), `tab` (`nalar-chat-right-sidebar-tab:<type>`). Type = `chat|task` from ChatView `type` prop. Never persist selected file (stale across sessions).
- **Out of scope**: approve/reject buttons, hunk-stage/discard, commit/stash/restore, inline comment threads, syntax highlighting, split/unified toggle for git diffs (lives in `DiffView`, not git viewer). These are Phase 5 candidates, NOT this plan.

---

## 2. Architecture

New directory `src/apps/desktop/src/components/views/chat_right_sidebar/`:

| File | Responsibility |
|---|---|
| `ChatRightSidebar.vue` | Shell: tabs, badge counts, resize handle, overlay-vs-inline breakpoint, empty states. `props:{cwd,sessionId,open,tab}` + emits `update:open/update:tab/submit-review`. Zero API calls — delegates to tab components. |
| `SidebarDiffTab.vue` | Git list + inline diff. Extracted from `GitChanges.vue` (list) + `GitFileViewer.vue` (diff render + `parseUnifiedDiff` + `openMiniChat`). Props `{cwd,sessionId}`. |
| `SidebarPreviewTab.vue` | Phase 1: static empty-state. Phase 3: renders presented-file list (props `{items}`). |
| `SidebarDetailTab.vue` | Renders one `messageGroups` entry full-size. Props `{entry}` (opaque object, no tool-specific imports beyond existing `DiffView`). |
| `useChatRightSidebar.ts` (composable, same dir) | State: `isOpen/tab/width/selectedFile/detailEntry`, persistence load/save, `openDetail(entry)` / `openPreview()` / `toggle()` helpers, `Cmd+B` listener with cleanup. Consumed ONLY by ChatView. |
| `parseUnifiedDiff.ts` | Pure extraction of `GitFileViewer.vue:115-220` parser + stats so both old viewer and new tab share it (no duplication). Unit-tested. |

Data flow:
- `ChatView` passes its ALREADY-OWNED `effectiveCwd` (today fed to `api.getGitStatus` polling L1040-1065) + `sessionId` down. No AppLayout plumbing.
- Diff list/diff content keep today's REST calls (`getGitChanges`, `getGitFileDiff`) unchanged in Phase 1. Refresh triggers: tab mount, `cwd` change, manual refresh button, + NEW: `gitStatus` poll tick already in ChatView (30s) → if branch/dirty-flag changed, invalidate list (cheap, no new backend).
- `submitReview` emits `ChatRightSidebar → ChatView → api.sendChatMessage(sessionId, ...)` directly (ChatView owns sessionId; deletes the AppLayout hop + its no-active-chat no-op).
- `SubAgentPeekHost` keeps precedence: when `nav.peekPanel` opens, sidebar force-overlays-closed (peek is modal-ish); closing peek restores prior `isOpen`.

What we DELETE (Phase 2, after ChatView sidebar ships):
- Commented `RightSidebar` block `AppLayout.vue:2903-2912` + dead handlers `_handleRightSidebarFileClick/SkillClick` L557-570,636-668 (verify no other importer first).
- `?view=gitfile` route + `gitViewerFile` refs L2404-2413,2118-2140,586-625 IF the inline diff fully replaces the overlay (keep `GitFileViewer.vue` file itself until Phase 5 decides — only remove the ROUTE).
- `RightSidebar.vue` Explorer/Skills tabs move ONLY if someone asks — this plan ports the Git tab; Explorer/Skills stay dead until a follow-up plan claims them.

---

## 3. API / backend (NO changes in Phase 1-3; Phase 4 optional)

Phase 1-3 reuse EXACTLY: `GET /api/git/changes`, `GET /api/git/file/diff`, `GET /api/git/file/read`, `POST /api/git/stage|unstage`. No new routes, no SSE, no migration.

Phase 4 (ONLY if polling proves janky — do NOT pre-build): `GET /api/git/changes` gains `?since=<dirtyHash>` returning `304 Not Modified` when `git status --porcelain` hash unchanged, OR a `git_changed` SSE event on the existing `unifiedSSE` bus filtered by `session_cwd`. Decision gate at end of Phase 2 (measure: does the 30s tick + manual refresh feel stale during an agentic loop that writes files every few seconds?).

---

## 4. File map

| File | Action | Why |
|---|---|---|
| `components/views/chat_right_sidebar/ChatRightSidebar.vue` | NEW | Sidebar shell (tabs/resize/overlay) |
| `components/views/chat_right_sidebar/SidebarDiffTab.vue` | NEW | Git list + inline diff (extracted) |
| `components/views/chat_right_sidebar/SidebarPreviewTab.vue` | NEW | Preview placeholder → real in Phase 3 |
| `components/views/chat_right_sidebar/SidebarDetailTab.vue` | NEW | Tool-row detail view |
| `components/views/chat_right_sidebar/useChatRightSidebar.ts` | NEW | Open/tab/width/selection state + persistence + shortcut |
| `components/views/chat_right_sidebar/parseUnifiedDiff.ts` | NEW | Shared pure parser (extracted from GitFileViewer) |
| `components/views/ChatView.vue` | EDIT (small) | Mount right column + toggle button + composable wiring only |
| `components/views/__tests__/useChatRightSidebar.spec.ts` | NEW | Composable: defaults, persistence, toggle, tab memory |
| `components/views/__tests__/ChatRightSidebar.spec.ts` | NEW | Shell: tabs render, badge counts, resize emit, overlay breakpoint |
| `components/views/__tests__/SidebarDiffTab.spec.ts` | NEW | List groups, diff load, retry, submitReview emit (mocked api) |
| `components/views/__tests__/parseUnifiedDiff.spec.ts` | NEW | Parser: hunks, stats, new-file, empty |
| `tests/functional/chat_right_sidebar_git_test.py` | NEW | Wire test: dirty worktree → `GET /changes` + `GET /file/diff` return expected payloads (harness boot, NOT live server) |
| `components/AppLayout.vue` | EDIT (Phase 2 only) | Remove dead RightSidebar block/handlers + `gitfile` route IF replaced |
| `components/git/GitFileViewer.vue` | EDIT (Phase 2 only) | Import shared parser (no behaviour change) |

---

## 5. Phases

### Phase 0 — Scaffolding (1 task, no behaviour change)
- [ ] Task 0.1: Create `chat_right_sidebar/` dir + `ChatRightSidebar.vue` shell rendering `Diff|Preview|Detail` tabs with static empty-states + `useChatRightSidebar` composable (open/tab/width + localStorage). Mount in ChatView behind `v-if="false"` (dead mount, proves compile + types). Vitest: composable defaults + tab switching.

### Phase 1 — Diff tab live (the "for now gitdiff" parity)
- [ ] Task 1.1: `parseUnifiedDiff.ts` extraction + `parseUnifiedDiff.spec.ts` (hunks/stats/new-file/empty/error). `GitFileViewer.vue` imports it (behaviour unchanged).
- [ ] Task 1.2: `SidebarDiffTab.vue` — port `GitChanges.vue` list (groups, counts, stage/unstage, context menu) + inline `GitFileViewer` diff (Wrap toggle, stats, Retry). Props `{cwd,sessionId}`, emits `submit-review`. Vitest with mocked `api.*`.
- [ ] Task 1.3: Wire `ChatView`: right flex column + header `◫` toggle + `Cmd+B` + `effectiveCwd/sessionId` props + `submitReview → api.sendChatMessage`. Overlay under 1024px. Vitest: toggle opens/closes, cwd change reloads.
- [ ] Task 1.4: Functional `chat_right_sidebar_git_test.py` — harness boots isolated binary, creates repo with staged/unstaged/untracked files, asserts `GET /api/git/changes` groups + `GET /api/git/file/diff` content + `POST /stage|unstage` round-trip. (Covers the Empty-slice-as-NULL + strict-validator wire failure modes unit tests miss.)

### Phase 2 — Cleanup + Detail tab
- [ ] Task 2.1: `SidebarDetailTab.vue` — click tool row in messages → `openDetail(entry)` switches tab; `✕` returns. No new API (data from `messageGroups`).
- [ ] Task 2.2: Delete dead `RightSidebar` block/handlers in AppLayout + `?view=gitfile` route IF inline diff covers it (keep file, remove route). Update `AppLayout.*.spec.ts` references. Decision gate: keep overlay as fallback if reviewers object.
- [ ] Task 2.3: Measure refresh staleness during agentic loop → GO/NO-GO for Phase 4 backend work.

### Phase 3 — Preview tab (depends on sibling `present_files` task)
- [ ] Task 3.1: `SidebarPreviewTab.vue` real render — consume whatever envelope the sibling task lands (`<present_files>` or `<show_preview>`). Badge count, click-to-open via existing `readGitFile`/editor flow. BLOCKED until sibling merges; Phase 1 placeholder means zero idle wait.

### Phase 4 — Backend refresh (OPTIONAL, gated)
- [ ] Task 4.1 (only if Phase 2.3 says stale): `?since=` / `304` or `git_changed` SSE. Functional test proves no stale list mid-loop. Otherwise SKIP.

---

## 6. Tests

| Layer | File | What it proves |
|---|---|---|
| Vitest | `useChatRightSidebar.spec.ts` | open/tab/width defaults + persistence round-trip + `Cmd+B` toggle + peek-precedence |
| Vitest | `ChatRightSidebar.spec.ts` | three tabs render, badges, resize emits width, overlay class under 1024px |
| Vitest | `SidebarDiffTab.spec.ts` | groups render, stage/unstage calls api, diff error → Retry, review submit emits payload |
| Vitest | `parseUnifiedDiff.spec.ts` | hunk parse, +/- stats, new-file synthetic diff, empty → `No changes` |
| Vitest | `SidebarDetailTab.spec.ts` | renders entry, close returns to prior tab |
| Functional | `tests/functional/chat_right_sidebar_git_test.py` | REAL wire: isolated binary + tmpdir HOME, dirty repo → changes/diff/stage round-trip (catches route-order + NULL-bind + validator bugs) |
| Typecheck | `pnpm --filter desktop vue-tsc --build` | no type regressions |
| Manual | ChatView narrow/wide, kanban-task + agent + standalone chats, peek open/close | sidebar follows correct cwd per chat; no layout breakage |

---

## 7. Risks / open questions (for human review)

1. **Scope of "featuresss"?** This plan assumes Diff-parity + Detail + Preview-placeholder. If you wanted Explorer/Skills tabs resurrected too, say so — that's +2 tasks (port `FolderExplorer` + skills list into new shell) but trivial once the shell exists.
2. **Overlay `GitFileViewer` fate?** Plan retires its ROUTE but keeps the file. If you love fullscreen diffs, keep both (inline for quick look, fullscreen for big diffs) — one-line decision in Phase 2.2.
3. **`present_files` envelope?** Sibling task still in progress (no `src/` match). Phase 3 is deliberately decoupled — confirm the envelope name when it lands.
4. **ChatView size?** Hard cap: ChatView diff must stay under ~100 added lines. Enforced in review.
5. **Peek vs sidebar conflict?** Plan gives peek precedence. Alternative: stack them (sidebar shrinks further). Peek is rare; precedence is simpler — confirm.
