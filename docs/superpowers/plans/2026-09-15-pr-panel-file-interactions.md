# PR-panel file interactions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three follow-ups from live use of the PR-changes panel (screenshot: #511 attached, 5 files listed, diff cramped in a narrow sidebar):

1. **Click a file → open in code browser.** Today a click only expands the inline diff. A plain click should open the file in the code editor (`view=code-editor`, i.e. the app URL changes), jumping to the first added line when the click lands on a diff row.
2. **Right-click → Open in new tab.** File rows get the app's standard right-click menu opening the code-editor URL in a real browser tab; Ctrl/Cmd+click and middle-click do the same (browser gesture, ChatsList precedent).
3. **Center-stage diff, inline sidebar (confirmed 2026-09-15 wireframe).** Today the inline diff is capped at `40vh` inside a file-list-first layout. When a file is selected, the file list collapses to a breadcrumb/back row and the diff takes the full panel height (list ↔ diff toggle, selection persists).

**Why this shape:** every piece reuses an existing funnel — `openInCodeEditor` (AppLayout provide/inject, `useInjectOpenInCodeEditor`), `openInNewTab(router, {path:'/app', query})` single funnel, `useContextMenu` + `OpenInNewTabMenu`, `isBackgroundOpenEvent`/`auxclick` (ChatsList pattern). No new navigation primitives, no backend changes (all three are frontend-only).

**Spec:** this document IS the spec (kanban card `rightsidebar inside chatview component`, planning review 2026-09-15).

**Worktree:** `/home/ginwa/.config/nalar/.worktrees/pr-panel-file-interactions-1789417100001` on branch `worktree/pr-panel-file-interactions-1789417100001`.

**Base:** `origin/main` (post-#509).

---

## 0. Current state (verified 2026-09-15)

| Area | File | State |
|---|---|---|
| Panel rows | `SidebarDiffPanel.vue` — worktree rows (`selectFile`) + PR rows (`selectPrFile`) | Click only sets `selectedPath` + parses inline diff. No navigation, no context menu. |
| Code-editor open | `AppLayout.vue:698` `openInCodeEditor({filePath, cwd, fileName?, line?})` → `api.readFileContent` → `router.replace({view:'code-editor', file:btoa, cwd, line?})` | Provided via inject; ChatView consumes via `useInjectOpenInCodeEditor` (currently a fallback no-op path). Clears git/skill overlays first. |
| New-tab funnel | `helpers/openInNewTab.ts` — `openInNewTab(router, {path, query})` → `router.resolve().href` → `window.open(href,'_blank','noopener')` | Single funnel used by chat/workspace/task rows, menus, Ctrl/Cmd+click, middle-click. |
| Context menu | `composables/useContextMenu.ts` (position + Escape/outside dismiss) + `components/shell/OpenInNewTabMenu.vue` (`open-new-tab-menu`, `open-new-tab-item`, opt-in details/stop items) | Chat-specific label ("Open chat in new tab"); needs a file item. |
| Bg-open gesture | `helpers/tabTarget.ts` `isBackgroundOpenEvent` (Ctrl/Meta/middle) + ChatsList `onChatRowClick`/`onChatRowAuxClick` pattern | Copy for file rows. |
| Diff cap | Panel inline diff container `maxHeight: '40vh'` | The cramped rendering in the screenshot. |
| Code-editor route | `view=code-editor` (tabTarget: `shouldTabify('/app',{view:'code-editor',...}) === false` — renders in place, not tabified) | New-tab opening bypasses tabify via direct `window.open` (same as chats). |

---

## Global Constraints

- **Frontend-only.** No migration, no new endpoint, no Zig changes.
- **No `// NEW (plan: ...)` tags** in source. Explain *why*, not *when*.
- **No port 8081**: functional tests via `tests/functional/harness.py` (not needed here — no backend change; Vitest only).
- **Behavioural Vitest** (`@vue/test-utils` mount, mocked `api.*`); ChatView-source assertions via the static-contract grep pattern (`ChatView.prSidebar.spec.ts` precedent).
- **TDD discipline**: failing test → minimal code → commit, per task.
- **No ChatView.vue bloat**: ChatView edits limited to the `open-file` handler + prop drilling. Tracked `.vue` edits MUST go through python patching, not `text_replace` (it reformats whole files).
- **PR files may not exist at `cwd/path`** (diff is base…head, worktree may differ) — `openInCodeEditor` already surfaces read failures inline (`codeEditorError`); the panel passes through and does not pre-check.

---

## 1. Design decisions (locked)

1. **Click = navigate, not just expand.** Plain left-click on a file row (both worktree and PR modes) calls `openInCodeEditor({filePath, cwd})` AND still sets the inline selection (so the panel keeps context). Clicking a diff `add`/`remove` row passes `line: newLineNum/oldLineNum` so the editor lands on that line (AppLayout already supports `line` via `codeEditorRequestedLine`). The review mini-chat keeps precedence on those rows? No — mini-chat opens on diff-row click today. Decision: diff-row click keeps opening mini-chat (review flow); a small "open file" affordance (⤴ button in the selected-file header bar) + file-row click navigate. This preserves the review flow while making navigation one click away on rows and headers.
   - Simpler alternative (chosen): file-row click navigates; diff-row click keeps mini-chat; selected-file header gets an explicit `⤴ Open` button (same action, discoverable).
2. **Menu reuse, not a new menu.** Extend `OpenInNewTabMenu.vue` with an opt-in file item (`showFileInNewTab` prop + `openFile` emit, label "Open file in new tab") following the existing `showDetails`/`showStop` pattern. Panel hosts `useContextMenu()` per file list (one menu instance, payload = right-clicked file).
3. **New-tab URL = code-editor deep link.** `{path:'/app', query:{view:'code-editor', file:btoa(path), cwd}}` via the `openInNewTab` funnel (consistent window features). `line` omitted for row opens (row has no single line); included for diff-row `⤴`? No — keep row-level only (line comes from plain diff-row mini-chat flow, unchanged).
4. **Inline sidebar + center diff view (confirmed 2026-09-15 wireframe — supersedes the overlay direction).** `ChatRightSidebar` stays a flex sibling (narrow list, original 280/200/600 widths — the overlay change is dropped). Row click emits `show-diff {path, lines, added, removed, staged}` (parsed lines travel with the event, no copy); ChatView swaps its main column messages/composer to a full-height diff view with `‹ Back to chat` breadcrumb, filename, stats, `⤴ editor` + review actions. Back clears the center view (panel list highlight persists). The panel hides its own inline diff section while the center view is active (`centerActive` prop) so the diff renders once, full height, own scroll. Header `⤴`, right-click menu, and Ctrl/Cmd+click/middle-click keep their editor/new-tab behavior from Phases 0-1. Peek keeps precedence.

## 2. File map

| File | Action | Why |
|---|---|---|
| `components/views/chat_right_sidebar/SidebarDiffPanel.vue` | EDIT | File-row click → `open-file` emit (+ keep inline selection); diff header `⤴ Open` button; right-click menu wiring; list-collapse + full-height diff |
| `components/views/chat_right_sidebar/ChatRightSidebar.vue` | EDIT | Re-emit `open-file` + `show-diff` upward; stays inline flex sibling (no overlay) |
| `components/views/ChatView.vue` | EDIT (medium) | center swap + handler `onChatSidebarOpenFile({path, line?})` → `openInCodeEditor({filePath, cwd: effectiveCwd, line})` |
| `components/shell/OpenInNewTabMenu.vue` | EDIT | Opt-in file item (`showFileInNewTab` + `openFile` emit) |
| `components/views/__tests__/SidebarDiffPanel.open.spec.ts` | NEW | Behavioural: click emits open-file, no navigation on mini-chat rows, right-click menu opens, back button restores list, diff fills height |
| `components/views/__tests__/ChatView.prOpen.spec.ts` | NEW | Static-contract: `open-file` handler + `openInCodeEditor` call shape |
| `components/shell/__tests__/OpenInNewTabMenu.file.spec.ts` | NEW | Behavioural: file item renders only with prop, emits `openFile` |

---

| `components/views/chat_right_sidebar/SidebarDiffView.vue` | NEW | Shared presentational diff (props: path/lines/added/removed/staged/wrap/showBack; emits: back/open/review): full-height table + mini-chat, used by panel (compact) and center (full) |
| `components/views/chat_right_sidebar/SidebarDiffPanel.vue` | EDIT | Row click emits `show-diff` (not `open-file`); `centerActive` prop hides inline diff; header/menu unchanged |

## 3. Phases

### Phase 0 — Open in code browser (click)
- [ ] Task 0.1: Panel emits `open-file {path, line?}` on file-row click (both modes; inline selection unchanged) + `⤴ Open` button in selected-file header (passes first-add line if known, else no line). Shell re-emits. Vitest: click emits with path; header button emits.
- [ ] Task 0.2: ChatView `onChatSidebarOpenFile` → `openInCodeEditor({filePath: path, cwd: effectiveCwd, line})` (python-patched, ~15 lines). Static-contract spec.

### Phase 1 — Right-click open in new tab
- [ ] Task 1.1: `OpenInNewTabMenu.vue` file item (`showFileInNewTab`, `openFile` emit). Behavioural spec.
- [ ] Task 1.2: Panel `useContextMenu` wiring on file rows (both modes): right-click opens menu with file payload; `openFile` → `openInNewTab(router, {path:'/app', query:{view:'code-editor', file:btoa, cwd}})`; Ctrl/Cmd+click + `auxclick` (middle) same target. Vitest: right-click shows menu, item click calls `window.open` with code-editor href; Escape dismisses.

### Phase 2 — Center-stage diff view (replaces overlay direction; PR #514 superseded)
- [ ] Task 2.1: Extract shared `SidebarDiffView.vue` from the panel's selected-diff section (same markup/behavior, props + back/open/review emits). Panel uses it compact (`showBack=false`); no behavior change yet. Vitest: existing panel specs still pass.
- [ ] Task 2.2: Panel row click emits `show-diff {path, lines, added, removed, staged}` instead of `open-file`; `centerActive` prop hides the inline diff section. Shell re-emits. Vitest: show-diff payload shape; inline hidden when centerActive.
- [ ] Task 2.3: ChatView main-column swap: `centerView` state (`chat`/`diff`), back-to-chat breadcrumb + filename/stats/editor/review header, full-height `SidebarDiffView`, composer hidden while diff shown (messages state preserved, just hidden). Back clears. Vitest static-contract + a mount test for the swap. Drop the overlay shell change and the width bump (revert to 280/200/600) and the list-collapse (list always visible).
- [ ] Task 2.4: `vue-tsc --build` + views/git vitest sweep (tool-width failure pre-exists on main — verify no NEW failures).

### Phase 3 — All-files stacked center + scroll-spy + URL sync (follow-up, approved 2026-09-15)

**Behavior:** the center diff shows ALL changed files stacked vertically (not just the clicked one). Clicking a file in the list scrolls the center to that file's section and updates the browser URL. Scrolling the center auto-advances the current file (scroll-spy) and the URL follows. Back clears the center view + URL param. Deep-link restore: opening a chat URL carrying the param auto-opens the center on that file.

- [ ] Task 3.1: Panel emits full list. Keep instant `show-diff {clicked}` (center opens immediately); add `show-diff-list {files: DiffSelection[]}` with the FULL ordered list — PR mode parses all chunks synchronously right after; worktree mode fetches all changed files' diffs in parallel (`Promise.allSettled`, failures become `{error}` entries, never reject the batch). Shell re-emits both. Vitest: PR list payload shape/count; worktree parallel fetch calls; failure entry shape.
- [ ] Task 3.2: ChatView holds `centerFiles: DiffSelection[]` (ordered) + `currentPath`. Opens/merges on both emits (union by path, list order wins; click on a loaded file scrolls only, no refetch). Sections render stacked, each `id="center-diff-<slug>"` (slug = base64url path, no padding). Vitest: merge/union logic via static-contract + mount test for stacked render.
- [ ] Task 3.3: Scroll-spy + URL sync. `IntersectionObserver` (root = center scroll container, `rootMargin: -40% 0px -55%`) sets `currentPath` to the most-visible section; watcher writes the browser URL via `router.replace({ query: { ...route.query, diff: btoa(path) } })` (needs `useRoute` import — ChatView has `useRouter` only today). Back button deletes the param. No navigation occurs (same view, replace only). Vitest: observer callback mapping (mock IO); URL replace called with merged query; back removes param.
- [ ] Task 3.4: Click-to-scroll + deep-link restore. List click on a loaded file → `document.getElementById` + `scrollIntoView({block:'start'})` inside the center container + current/URL update (no fetch). On panel first list load, if `route.query.diff` decodes to a listed path, auto-select it (panel reads `useRoute`; invalid value ignored). Vitest: click scrolls (scrollIntoView stub); restore selects on load; bad param ignored.
- [ ] Task 3.5: `vue-tsc --build` + views/git sweep (tool-width failure pre-exists — verify no NEW failures).

**File map additions:** `SidebarDiffPanel.vue` (show-diff-list emit, parallel fetch, auto-restore), `ChatRightSidebar.vue` (re-emit), `ChatView.vue` (`centerFiles/currentPath`, observer, URL sync, scroll-to, `useRoute`), specs (`show-diff-list` payload, merge logic, observer mapping, URL replace/remove, restore).

**Tests additions:** Vitest `SidebarDiffPanel.list.spec.ts` (full-list payloads), `ChatView.centerSpy.spec.ts` (static: observer setup, URL sync, restore); manual: attach PR, click file 3 → URL gains `diff=` → scroll to bottom → current file + URL advance → reload URL → center reopens on file → back clears URL.

**Risks:** (a) Large changesets fan out N worktree fetches — `Promise.allSettled` bounds failure, not load; 50+ file PRs rely on the endpoint's 1MB cap + `truncated` note (no extra cap proposed — confirm). (b) `router.replace` on every scroll crossing spams history? `replace` (not `push`) avoids history entries — confirm no history growth. (c) `btoa` on non-Latin paths throws — wrap in try/catch, fall back to `encodeURIComponent` (same guard needed in existing `codeEditorQuery` — opportunistic fix, one line).

## 4. Tests

| Layer | File | What it proves |
|---|---|---|
| Vitest | `SidebarDiffPanel.open.spec.ts` | open-file emit on row click, header button, menu open/emit/dismiss, collapse + back, overlay shell classes, no stage buttons in PR mode (existing) |
| Vitest | `ChatView.prOpen.spec.ts` | handler exists, calls openInCodeEditor with filePath + effectiveCwd |
| Vitest | `OpenInNewTabMenu.file.spec.ts` | file item gated by prop, emits openFile |
| Typecheck | `vue-tsc --build` | no regressions |
| Manual | Attach PR, click file → editor + URL change; right-click → new tab; select → full diff + back | end-to-end feel |

---

## 5. Risks / open questions (for human review)

1. ~~Click-navigates vs click-expands?~~ Answered 2026-09-15: **click navigates away**. Original text said click navigates; kept for reference: `⤴`/menu, say so — Task 0.1 flips in one line.
2. ~~PR files missing from worktree?~~ Accepted 2026-09-15: **editor inline read error, no pre-check**.
3. ~~"Full git diff" interpretation?~~ Answered 2026-09-15: **wider overlay sidebar** (overlaps chat, ~560px) + list-collapse + full-height diff.
