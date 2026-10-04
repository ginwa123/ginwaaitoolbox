# RightSidebar inside ChatView — Implementation Plan (GIT DIFF ONLY)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal (narrowed per human review 2026-09-14):** Move the right-sidebar ownership from `AppLayout` (global, currently DISABLED since 2026-06-29) into `ChatView` (per-chat, per-cwd). The sidebar is **git diff only** — no Preview tab, no Detail tab, no Explorer/Skills resurrection. Single panel: working-tree changes for the active chat's cwd. Toggleable, resizable, persisted per chat-type.

**Why ChatView-owned, not AppLayout-owned:** today `rightSidebarCwd` in `AppLayout.vue:2061` is derived from `activeWorkspaceItem.path || chatSessionCwd` — a global guess that breaks when kanban-task chat, agent chat, and standalone chat each have different cwds. `ChatView` already owns `sessionId / sessionCwd / gitStatus / effectiveCwd` (L1000+, L1040-1065) and the SSE bus filter (`event.session_id===sid` L474-483). Co-locating the sidebar kills the cwd-plumbing bug class entirely.

**Spec:** this document IS the spec (approved on kanban card `rightsidebar inside chatview component` in `in_review_planning`; scope narrowed to git-diff-only per human comment).

**Worktree:** `/home/ginwa/.config/pabrik/.worktrees/rightsidebar-inside-chatview-component-1789413707849` on branch `worktree/rightsidebar-inside-chatview-component-1789413707849`.

**Base:** `origin/main` at `4f1f345c` (2026-09-14).

---

## 0. Current state (verified 2026-09-14, sub-agent survey)

| Area | File | State |
|---|---|---|
| `ChatView.vue` | `src/apps/desktop/src/components/views/ChatView.vue` (4344 lines) | Root is 2-pane `flex` with NO right column. Main chat col `flex-1 min-w-0` L3001-3004. Only right slide-over is `SubAgentPeekHost` L3984-3998 (gated on `nav.peekPanel && !embedded`). |
| `RightSidebar.vue` | `src/apps/desktop/src/components/shell/RightSidebar.vue` (430 lines) | DEAD CODE. Import + mount commented out `AppLayout.vue:5,2903-2912` (`// DISABLED 2026-06-29 — task disable-rightsidebar-vue`). Tabs `Explorer\|Git\|Skills` L60-79, `props:{cwd?,width?}`, emits `file-click/skill-click/code-editor-file-click/resize`. Git list via `api.getGitChanges(cwd)` L141 on `watch(cwd,{immediate:true})`. |
| `GitChanges.vue` | `src/apps/desktop/src/components/git/GitChanges.vue` | Standalone duplicate of the Git tab (adds Stage/Unstage buttons RightSidebar lacks). No importer found — likely also unmounted. This is the markup source for the new panel. |
| `GitFileViewer.vue` | `src/apps/desktop/src/components/git/GitFileViewer.vue` (602 lines) | LIVE but fullscreen overlay, not inline pane. Mounts `AppLayout.vue:2404-2413` on `currentView==='gitfile'`. `parseUnifiedDiff()` L115-220, `openMiniChat()` L52-89 → `emit('submitReview')` → `AppLayout:868-882` sends review text into active chat via `api.sendChatMessage`. |
| `DiffView.vue` | `src/apps/desktop/src/components/tool_outputs/_shared/DiffView.vue` (509 lines) | NOT git — renders `before/after` strings for `TextReplace` tool outputs. Out of scope for this plan. |
| Backend git | `src/http_handlers/git_*.zig` + routes `src/main.zig:555-560` | REST only. `GET /api/git/changes?path=`, `GET /api/git/file/diff?path=&file=&staged=`, `GET /api/git/file/read`, `POST /api/git/stage|unstage`. No SSE, no store. |
| State | `src/apps/desktop/src/stores/sidebar.ts` | Only width persistence (`pabrik-right-sidebar-width`). No visibility state. |
| Wrappers | `StandardTaskChatView.vue` (73 lines), `AgentChatView.vue` (54 lines) | Thin forwarders to `<ChatView>` — inherit the sidebar for free. |

Key constraint: `ChatView.vue` is already 4344 lines. Do NOT grow it — new sidebar code lives in NEW files under `components/views/chat_right_sidebar/`.

---

## Global Constraints

- **Cross-platform**: frontend-only change, but any Zig touch MUST verify `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc` + `-target aarch64-macos -lc`.
- **No `// NEW (plan: ...)` tags** in source. Explain *why*, not *when*.
- **No port 8081**: functional tests boot isolated binary via `tests/functional/harness.py` (free port 8080..8199, tmpdir HOME). Never `nohup ... --port 8080` + curl.
- **Behavioural tests only**: Vitest `@vue/test-utils` `mount` + `setActivePinia(createPinia())`; mock fetch via `vi.fn()` returning `{ok,status,json,text}`. No `expect(source).toContain(...)` static-contract tests.
- **TDD discipline**: failing test → minimal code → commit, per task.
- **No ChatView.vue bloat**: ChatView edits limited to (a) right-column mount point, (b) toggle button, (c) composable wiring. Everything else in new files.

---

## 1. Proposed UX (git diff only — no tabs)

```
┌ ChatView (flex row) ──────────────────────────────┐
│ ┌ main (flex-1 min-w-0) ┐ ┌ sidebar (w-80..w-[480])┐ │
│ │ header + toggle [◫]   │ │ 🌿 branch + refresh   │ │
│ │ messages (unchanged)  │ │ Staged (n) / Changes  │ │
│ │ composer (unchanged)  │ │ / Untracked groups    │ │
│ │                       │ │ inline diff (selected)│ │
│ └───────────────────────┘ │ ↕ resize handle (left)│ │
└───────────────────────────┴───────────────────────┘
```

- **Toggle**: header button `◫` + `Cmd/Ctrl+B` flips `isOpen`. `embedded` / `hideInput` (peek) modes force closed — peek owns the right edge.
- **Panel** (single, no tabs):
  - Header: `🌿 <branch>` + change-count badge + refresh button. States: loading spinner / `⚠️ Failed to load` + Retry / `🌿 Not a git repository` / `✓ Working tree clean`.
  - Groups: `Staged Changes (n)` / `Changes (n)` / `Untracked (n)` with per-file status icon (`M/A/D/R/C/??`), stage/unstage buttons + `Stage All / Unstage All` + right-click menu (port from `GitChanges.vue`, NOT the button-less `RightSidebar` variant).
  - Click file → inline diff below the list (NOT fullscreen route). Keep `Wrap` toggle + `+added/-removed` stats + line-number gutters from `GitFileViewer`. Keep `openMiniChat → submitReview` flow but emit upward to ChatView (which owns `sessionId`, so the `AppLayout:868-882` no-active-chat no-op disappears).
- **Responsive**: `< 1024px` → overlay drawer (absolute right, shadow, `✕` closes). `>= 1024px` → inline flex column (messages keep `min-w-0`, VirtualScroller unaffected).
- **Persistence** (localStorage, per chat-type suffix `chat|task` from ChatView `type` prop): `width` (reuse `pabrik-right-sidebar-width`), `open` (`pabrik-chat-right-sidebar-open:<type>`), selected file NOT persisted.
- **Out of scope**: Preview/Detail tabs, approve/reject, hunk-stage/discard, commit/stash/restore, inline threads, syntax highlight, split/unified toggle. Follow-up plans only.

---

## 2. Architecture

New directory `src/apps/desktop/src/components/views/chat_right_sidebar/`:

| File | Responsibility |
|---|---|
| `ChatRightSidebar.vue` | Shell: header (branch + badge + refresh), resize handle, overlay-vs-inline breakpoint, empty states. `props:{cwd,sessionId,open}` + emits `update:open/submit-review`. Zero API calls — delegates list+diff to child. |
| `SidebarDiffPanel.vue` | Git list + inline diff. Extracted from `GitChanges.vue` (list) + `GitFileViewer.vue` (diff render + `parseUnifiedDiff` + `openMiniChat`). Props `{cwd,sessionId}`. |
| `useChatRightSidebar.ts` | State: `isOpen/width/selectedFile`, persistence load/save, `toggle()` helper, `Cmd+B` listener with cleanup. Consumed ONLY by ChatView. No tab state (single panel). |
| `parseUnifiedDiff.ts` | Pure extraction of `GitFileViewer.vue:115-220` parser + stats so old viewer and new panel share it. Unit-tested. |

Data flow:
- `ChatView` passes its ALREADY-OWNED `effectiveCwd` (today fed to `api.getGitStatus` polling L1040-1065) + `sessionId` down. No AppLayout plumbing.
- Diff list/diff content keep today's REST calls (`getGitChanges`, `getGitFileDiff`) unchanged. Refresh triggers: panel mount, `cwd` change, manual refresh button, + NEW: existing ChatView `gitStatus` 30s poll tick → if branch/dirty-flag changed, invalidate list (cheap, no new backend).
- `submitReview` emits `SidebarDiffPanel → ChatRightSidebar → ChatView → api.sendChatMessage(sessionId, ...)` directly.
- `SubAgentPeekHost` keeps precedence: when `nav.peekPanel` opens, sidebar force-overlays-closed; closing peek restores prior `isOpen`.

What we DELETE (after ChatView sidebar ships):
- Commented `RightSidebar` block `AppLayout.vue:2903-2912` + dead handlers `_handleRightSidebarFileClick/SkillClick` L557-570,636-668 (verify no other importer first).
- `?view=gitfile` route + `gitViewerFile` refs L2404-2413,2118-2140,586-625 IF inline diff fully replaces the overlay (keep `GitFileViewer.vue` file itself until a follow-up decides — only remove the ROUTE).

---

## 3. API / backend (NO changes)

Reuse EXACTLY: `GET /api/git/changes`, `GET /api/git/file/diff`, `GET /api/git/file/read`, `POST /api/git/stage|unstage`. No new routes, no SSE, no migration. If the 30s tick + manual refresh proves stale during agentic loops, file a follow-up plan (optional `?since=`/304 or `git_changed` SSE) — NOT this plan.

---

## 4. File map

| File | Action | Why |
|---|---|---|
| `components/views/chat_right_sidebar/ChatRightSidebar.vue` | NEW | Sidebar shell (header/resize/overlay) |
| `components/views/chat_right_sidebar/SidebarDiffPanel.vue` | NEW | Git list + inline diff (extracted) |
| `components/views/chat_right_sidebar/useChatRightSidebar.ts` | NEW | Open/width/selection state + persistence + shortcut |
| `components/views/chat_right_sidebar/parseUnifiedDiff.ts` | NEW | Shared pure parser (extracted from GitFileViewer) |
| `components/views/ChatView.vue` | EDIT (small) | Mount right column + toggle button + composable wiring only |
| `components/views/__tests__/useChatRightSidebar.spec.ts` | NEW | Composable: defaults, persistence, toggle |
| `components/views/__tests__/ChatRightSidebar.spec.ts` | NEW | Shell: header/badge/resize emit/overlay breakpoint |
| `components/views/__tests__/SidebarDiffPanel.spec.ts` | NEW | List groups, diff load, retry, submitReview emit (mocked api) |
| `components/views/__tests__/parseUnifiedDiff.spec.ts` | NEW | Parser: hunks, stats, new-file, empty |
| `tests/functional/chat_right_sidebar_git_test.py` | NEW | Wire test: dirty worktree → changes + diff + stage round-trip (harness boot, NOT live server) |
| `components/AppLayout.vue` | EDIT (cleanup only) | Remove dead RightSidebar block/handlers + `gitfile` route IF replaced |
| `components/git/GitFileViewer.vue` | EDIT (cleanup only) | Import shared parser (no behaviour change) |

---

## 5. Phases

### Phase 0 — Scaffolding (no behaviour change)
- [ ] Task 0.1: Create `chat_right_sidebar/` dir + `ChatRightSidebar.vue` shell with static empty-states + `useChatRightSidebar` composable (open/width + localStorage). Mount in ChatView behind `v-if="false"` (dead mount, proves compile + types). Vitest: composable defaults + toggle.

### Phase 1 — Diff panel live
- [ ] Task 1.1: `parseUnifiedDiff.ts` extraction + `parseUnifiedDiff.spec.ts` (hunks/stats/new-file/empty/error). `GitFileViewer.vue` imports it (behaviour unchanged).
- [ ] Task 1.2: `SidebarDiffPanel.vue` — port `GitChanges.vue` list (groups, counts, stage/unstage, context menu) + inline `GitFileViewer` diff (Wrap toggle, stats, Retry). Props `{cwd,sessionId}`, emits `submit-review`. Vitest with mocked `api.*`.
- [ ] Task 1.3: Wire `ChatView`: right flex column + header `◫` toggle + `Cmd+B` + `effectiveCwd/sessionId` props + `submitReview → api.sendChatMessage`. Overlay under 1024px. Vitest: toggle opens/closes, cwd change reloads.
- [ ] Task 1.4: Functional `chat_right_sidebar_git_test.py` — harness boots isolated binary, creates repo with staged/unstaged/untracked files, asserts `GET /api/git/changes` groups + `GET /api/git/file/diff` content + `POST /stage|unstage` round-trip.

### Phase 2 — Cleanup
- [ ] Task 2.1: Delete dead `RightSidebar` block/handlers in AppLayout + `?view=gitfile` route IF inline diff covers it (keep file, remove route). Update `AppLayout.*.spec.ts` references. Decision gate: keep overlay as fallback if reviewers object.

---

## 6. Tests

| Layer | File | What it proves |
|---|---|---|
| Vitest | `useChatRightSidebar.spec.ts` | open/width defaults + persistence round-trip + `Cmd+B` toggle + peek-precedence |
| Vitest | `ChatRightSidebar.spec.ts` | header/badge render, resize emits width, overlay class under 1024px |
| Vitest | `SidebarDiffPanel.spec.ts` | groups render, stage/unstage calls api, diff error → Retry, review submit emits payload |
| Vitest | `parseUnifiedDiff.spec.ts` | hunk parse, +/- stats, new-file synthetic diff, empty → `No changes` |
| Functional | `tests/functional/chat_right_sidebar_git_test.py` | REAL wire: isolated binary + tmpdir HOME, dirty repo → changes/diff/stage round-trip |
| Typecheck | `pnpm --filter desktop vue-tsc --build` | no type regressions |
| Manual | ChatView narrow/wide, kanban-task + agent + standalone chats, peek open/close | sidebar follows correct cwd per chat; no layout breakage |

---

## 7. Risks / open questions

1. **Overlay `GitFileViewer` fate?** Plan retires its ROUTE but keeps the file. If you love fullscreen diffs, keep both — one-line decision in Phase 2.1.
2. **ChatView size?** Hard cap: ChatView diff must stay under ~100 added lines. Enforced in review.
3. **Peek vs sidebar conflict?** Plan gives peek precedence. Alternative: stack them. Peek is rare; precedence is simpler — confirm.
