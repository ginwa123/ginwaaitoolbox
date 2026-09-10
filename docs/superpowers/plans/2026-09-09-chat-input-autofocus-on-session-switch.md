# Chat Input Autofocus on Session Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking any chat session in the sidebar auto-focuses the bottom message input so the user can type immediately with no second mouse click.

**Architecture:** Add a guarded `focusInput()` to `FileInput.vue` (owns the `<textarea ref="chatTextareaRef">`) and call it from `ChatView.vue` after each fresh mount (session switch = full remount via `:key="activeChatId"`). Guard against focus-steal cases (hidden input, modal open, background window). No backend, no migration, no route change.

**Tech Stack:** Vue 3 (`ref`, `onMounted`, `nextTick`, `defineExpose`), `FileInput.vue` + `ChatView.vue`, vitest (`@vue/test-utils`, `attachTo: document.body` for real `.focus()` assertions).

## Global Constraints

- Frontend-only. No Zig, no SQLite migration, no SSE/event change, no API change.
- Do NOT touch `KanbanChatDialog.vue` / `DesignChatDialog.vue` — those have an explicit prior decision: `// Do NOT auto-focus the chat input — would steal typing position` (wrapper-only `dialogRootRef.focus()`). This plan covers main `ChatView.vue` + shared `FileInput.vue` only.
- No `autofocus` HTML attribute (zero matches in codebase today — keep it that way; attribute fires before layout and fights `nextTick` timing). Use programmatic `.focus({ preventScroll: true })`.
- Must not break `hideInput=true` consumers (`SubAgentPeekPanel` read-only mode — no textarea rendered).
- Must not steal focus when a modal/dialog is open on top of ChatView or when `document.hidden` / window blurred.
- Follow existing `nextTick(() => nameInput.value?.focus())` dialog pattern for timing.

## File Map (from exploration)

| File | Role in this fix |
|---|---|
| `src/apps/desktop/src/components/file/FileInput.vue:673-682` | Owns `<textarea ref="chatTextareaRef">`. Add `focusInput()` + auto-call on mount. No focus logic exists today (`:68` ref def, `:292` onMounted only adds paste listener). |
| `src/apps/desktop/src/components/views/ChatView.vue:3542-3558` | Renders `<FileInput v-if="!hideInput">`. Add `ref="fileInputRef"` + call `focusInput()` after mount/load. Remounts per session via `:key` so `onMounted` refires every switch. |
| `src/apps/desktop/src/components/AppLayout.vue:2670-2677` | `<ChatView :key="activeChatId">` — proves session switch = fresh instance (no `watch(props.chatId)` reload needed; that watcher at `ChatView.vue:642-653` only clears preview). No change needed, read-only context. |
| `src/apps/desktop/src/components/views/ChatsList.vue:275-287,488-489` | Click `@click="setActive(item.id)"` → `navigationStore.setActiveChat` + `router.replace`. No change needed, read-only context. |
| `src/apps/desktop/src/components/views/StandardTaskChatView.vue`, `AgentChatView.vue` | Sibling `FileInput` consumers — inherit fix for free, verify no regression. No direct edit unless guards need sharing. |

## Key Facts Driving the Design

1. `ChatView` does NOT own the textarea — `FileInput.vue` does (`chatTextareaRef`, defined `:68`, element `:673`). Any plan that says "focus in ChatView" without touching FileInput is wrong.
2. Session switch = full destroy + recreate (`AppLayout.vue:2670 :key="activeChatId"`). So `onMounted` in both ChatView and FileInput fires on every click — the natural hook point. No router watcher needed.
3. `ChatView.onMounted` (`:2593-2645`) awaits `loadChatHistory()` + `getStreamSnapshot()` + `connectSse()` — focus must run AFTER these (or at least after `nextTick`) or the first render's textarea isn't in DOM yet / gets replaced.
4. Prior "DO NOT autofocus" rule is dialog-scoped (`KanbanChatDialog.vue:89-91`, `DesignChatDialog.vue:88-90`, spec `2026-08-06-kanban-chat-as-dialog-design.md:84`). Main ChatView has no such rule — safe to add.
5. `autofocus` attribute count = 0, `.focus()` in ChatView/ChatsList = 0. Greenfield — no conflict.

## Tasks

### Task 1 — Failing test: FileInput exposes and auto-calls focusInput on mount

- [ ] Read `FileInput.vue:52-99` (refs/watches), `:292-300` (onMounted), `:673-682` (textarea) to confirm current shape.
- [ ] Write failing vitest: `src/apps/desktop/src/components/file/__tests__/FileInput.autofocus.spec.ts` — mount with `attachTo: document.body`, assert `document.activeElement === textarea` after `nextTick`. Use `attachTo` (real DOM focus needs it — same reason `vue-teleport-vitest-document-queryselector` skill requires `attachTo: document.body` + `document.querySelector`).
- [ ] Run it, confirm it fails (no focus today).
- [ ] Commit test-only change (expect red).

### Task 2 — Implement `focusInput()` in FileInput.vue with guards

- [ ] In `FileInput.vue`: add
  ```ts
  const focusInput = () => {
    if (props.hideInput) return;                       // SubAgentPeekPanel read-only — no textarea
    const el = chatTextareaRef.value;
    if (!el || el.disabled) return;
    if (document.hidden) return;                       // background tab — don't steal
    if (document.querySelector('[role="dialog"], .modal-open')) return; // modal on top — don't steal
    el.focus({ preventScroll: true });
  };
  defineExpose({ focusInput });
  ```
- [ ] Call it in existing `onMounted (:292)` AFTER paste-listener setup via `nextTick(() => focusInput())` (matches `CreateWorktreeDialog.vue:124` timing pattern). Keep `autoResize` untouched.
- [ ] Re-run Task 1 spec, confirm green.
- [ ] Commit.

### Task 3 — Failing test: ChatView focuses input after session mount (history loaded)

- [ ] Read `ChatView.vue:3542-3558` (FileInput mount point), `:2593-2645` (onMounted load chain).
- [ ] Write failing vitest: `ChatView.autofocusOnMount.spec.ts` — mock `api.getChatHistory` + `getStreamSnapshot` + `getQueuedMessages` (copy mock shape from `ChatView.scrollRestore.spec.ts`), mount ChatView with `attachTo: document.body`, assert bottom textarea becomes `document.activeElement` once load resolves.
- [ ] Run, confirm red (ChatView never calls focus today).
- [ ] Commit test-only (red).

### Task 4 — Wire ChatView → FileInput focus after load

- [ ] In `ChatView.vue`: add `ref="fileInputRef"` to the `<FileInput>` at `:3550-3558`; in `onMounted` after `loadChatHistory()` / snapshot / queued-messages resolve (after `:2641`), add `await nextTick(); fileInputRef.value?.focusInput?.();` wrapped in try/catch (focus must never reject mount if FileInput absent via `hideInput`).
- [ ] Do NOT add focus to `watch(() => props.chatId)` (`:642-653`) — remount covers session switch; watcher path would double-focus.
- [ ] Re-run Task 3 spec, confirm green. Also re-run Task 1 spec.
- [ ] Commit.

### Task 5 — Guard specs (no-steal cases) + full regression

- [ ] Add cases to `FileInput.autofocus.spec.ts`: (a) `hideInput=true` → no focus, no throw; (b) open dialog in DOM (`[role="dialog"]` present) → no focus steal; (c) `document.hidden=true` (stub `Object.defineProperty(document, 'hidden', ...)`) → no focus. Mirror existing focus-test style from `KanbanTagsInput.autocomplete.spec.ts` (`trigger('focus')`) and `FilePickerDialog.spec.ts:1026-1030`.
- [ ] Run: `pnpm test:unit` for `FileInput`, `ChatView`, `ChatsList`, `StandardTaskChatView`, `AgentChatView` suites — all green. `npx vue-tsc --noEmit -p tsconfig.app.json` clean.
- [ ] Manual check: click 3 sidebar sessions rapidly → each lands with cursor blinking in "Type a message..." box, no scroll jump (`preventScroll`), empty-state ("How can I help you?") session also focuses.
- [ ] Commit.

## Out of Scope (do NOT do)

- Kanban / Design chat dialogs (explicit no-autofocus decision stands).
- Mobile virtual-keyboard avoidance (no prior rule found; desktop-first — file follow-up if iOS keyboard pops unwanted).
- Backend / SSE / router / store changes — click chain (`ChatsList.setActive → navigationStore → router → AppLayout :key remount`) already works, verified read-only.
- `autofocus` attribute or global focus directive — programmatic call only.

## Verification

- [ ] Plan saved here (`docs/superpowers/plans/2026-09-09-chat-input-autofocus-on-session-switch.md`)
- [ ] Header has Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task is test → implement → verify → commit, one action per step
- [ ] User has reviewed the plan before execution begins
