# PR-panel file interactions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three follow-ups from live use of the PR-changes panel (screenshot: #511 attached, 5 files listed, diff cramped in a narrow sidebar):

1. **Click a file → open in code browser.** Today a click only expands the inline diff. A plain click should open the file in the code editor (`view=code-editor`, i.e. the app URL changes), jumping to the first added line when the click lands on a diff row.
2. **Right-click → Open in new tab.** File rows get the app's standard right-click menu opening the code-editor URL in a real browser tab; Ctrl/Cmd+click and middle-click do the same (browser gesture, ChatsList precedent).
3. **Full-height diff.** Today the inline diff is capped at `40vh` inside a file-list-first layout. When a file is selected, the file list collapses to a breadcrumb/back row and the diff takes the full sidebar height (list ↔ diff toggle, selection persists).

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
4. **Full-height diff = list collapses.** When `selectedPath` is set, the file-list groups hide behind a breadcrumb row (`‹ All files (n)` back button clears selection); the diff section grows to fill (`maxHeight: 40vh` → flex-1 full scroll). Clearing selection restores the list. Both modes share the behavior (one `v-if` on the list container). Selection persists across refreshes (already does via `selectedPath`).
5. **Ctrl/Cmd+click + middle-click** on file rows open the same new-tab URL (ChatsList `onChatRowClick`/`onChatRowAuxClick` pattern with `isBackgroundOpenEvent`).

---

## 2. File map

| File | Action | Why |
|---|---|---|
| `components/views/chat_right_sidebar/SidebarDiffPanel.vue` | EDIT | File-row click → `open-file` emit (+ keep inline selection); diff header `⤴ Open` button; right-click menu wiring; list-collapse + full-height diff |
| `components/views/chat_right_sidebar/ChatRightSidebar.vue` | EDIT | Re-emit `open-file` upward (shell stays logic-free, panel precedent) |
| `components/views/ChatView.vue` | EDIT (small) | `onChatSidebarOpenFile({path, line?})` → `openInCodeEditor({filePath, cwd: effectiveCwd, line})` |
| `components/shell/OpenInNewTabMenu.vue` | EDIT | Opt-in file item (`showFileInNewTab` + `openFile` emit) |
| `components/views/__tests__/SidebarDiffPanel.open.spec.ts` | NEW | Behavioural: click emits open-file, no navigation on mini-chat rows, right-click menu opens, back button restores list, diff fills height |
| `components/views/__tests__/ChatView.prOpen.spec.ts` | NEW | Static-contract: `open-file` handler + `openInCodeEditor` call shape |
| `components/shell/__tests__/OpenInNewTabMenu.file.spec.ts` | NEW | Behavioural: file item renders only with prop, emits `openFile` |

---

## 3. Phases

### Phase 0 — Open in code browser (click)
- [ ] Task 0.1: Panel emits `open-file {path, line?}` on file-row click (both modes; inline selection unchanged) + `⤴ Open` button in selected-file header (passes first-add line if known, else no line). Shell re-emits. Vitest: click emits with path; header button emits.
- [ ] Task 0.2: ChatView `onChatSidebarOpenFile` → `openInCodeEditor({filePath: path, cwd: effectiveCwd, line})` (python-patched, ~15 lines). Static-contract spec.

### Phase 1 — Right-click open in new tab
- [ ] Task 1.1: `OpenInNewTabMenu.vue` file item (`showFileInNewTab`, `openFile` emit). Behavioural spec.
- [ ] Task 1.2: Panel `useContextMenu` wiring on file rows (both modes): right-click opens menu with file payload; `openFile` → `openInNewTab(router, {path:'/app', query:{view:'code-editor', file:btoa, cwd}})`; Ctrl/Cmd+click + `auxclick` (middle) same target. Vitest: right-click shows menu, item click calls `window.open` with code-editor href; Escape dismisses.

### Phase 2 — Full-height diff
- [ ] Task 2.1: List collapses to `‹ All files (n)` breadcrumb when `selectedPath` set; diff container `maxHeight 40vh` → `flex-1 min-h-0` full scroll; back button clears selection. Both modes. Vitest: selecting hides list, shows breadcrumb; back restores.
- [ ] Task 2.2: `vue-tsc --build` + views/git vitest sweep (tool-width failure pre-exists on main — verify no NEW failures).

---

## 4. Tests

| Layer | File | What it proves |
|---|---|---|
| Vitest | `SidebarDiffPanel.open.spec.ts` | open-file emit on row click, header button, menu open/emit/dismiss, collapse + back, no stage buttons in PR mode (existing) |
| Vitest | `ChatView.prOpen.spec.ts` | handler exists, calls openInCodeEditor with filePath + effectiveCwd |
| Vitest | `OpenInNewTabMenu.file.spec.ts` | file item gated by prop, emits openFile |
| Typecheck | `vue-tsc --build` | no regressions |
| Manual | Attach PR, click file → editor + URL change; right-click → new tab; select → full diff + back | end-to-end feel |

---

## 5. Risks / open questions (for human review)

1. **Click-navigates vs click-expands?** Plan makes file-row click navigate away (chat stays, editor takes main view). If you preferred click = expand-only with navigation only via `⤴`/menu, say so — Task 0.1 flips in one line.
2. **PR files missing from worktree?** `openInCodeEditor` shows its inline read error; panel does not pre-check. Acceptable?
3. **"Full git diff" interpretation?** Plan implements list-collapse + full-height diff in-sidebar. If you instead meant a wider sidebar or fullscreen overlay, say so.
