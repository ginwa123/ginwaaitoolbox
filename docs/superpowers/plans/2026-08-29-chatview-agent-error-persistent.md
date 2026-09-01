# ChatView Agent Error — Persist Across Session Switches

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The `AgentErrorCard` (the red-tinted card that surfaces agentic-loop error/retry diagnostics like `[Retry 1/10] StreamInterrupted … Server said: …`) currently disappears the moment the user clicks another session in the sidebar and then comes back. Make it persist across that round-trip — the user should still see the most recent error diagnostic for any session they've visited.

**Architecture (one-line):** Move `agentError` out of `ChatView.vue`'s local component state and into a new Pinia store keyed by `session_id`. ChatView writes to the store on every SSE `is_error` `full` event and reads from the store for the currently mounted session. The store outlives ChatView remounts, so the error survives session switches exactly the way `processingState` (App.vue:10-11, injected) already does for "this session has a running worker". The same store also surfaces a small red ⚠ indicator on the kanban board (and sidebar task row) so the user sees which sessions have an active agent error at a glance — without having to open each chat to find out.

**Visual preview** (kanban mode overview) is rendered in the chat side panel via `show_preview` (preview id `pv_1787987172775_7e0646`). Self-contained HTML mockup also checked in at `preview-kanban-error.html`.

**Tech Stack:** Vue 3 / TypeScript + Pinia (`useAgentErrorStore`). Frontend-only — no backend changes, no migration, no new HTTP route, no new SSE event type. The wire format is unchanged; only the state container moves.

## User-visible changes

1. **Error card survives session switches.** The user clicks session A → error fires → user clicks session B → user clicks session A again → the card is still there with the same retry chip / headline / server detail. Previously: the card vanished because `ChatView` was unmounted between visits.

2. **Error card still auto-clears on recovery.** When the agent recovers from the retry chain (any non-error renderable `full` event for that session), the store entry for that session is cleared. The "latest-wins, single card" semantics from PR `task_1787668954023_2` are preserved — a 1/10 card becomes 2/10 in place, becomes the final 10/10 bail in place; the user sees ONE indicator with progress, not a pile.

3. **Same card visible across the 4 ChatView mounts.** The same store backs the inline `<ChatView v-else-if="activeChatId.startsWith('chat-')">` branch (AppLayout:2670), the `<StandardTaskChatView>` wrapper (AppLayout:2658, `:key="chat-${task.id}"` on inner ChatView), `<KanbanChatDialog>` (KanbanChatDialog.vue:245, `:key="'task-' + task.id"`), `<DesignChatDialog>` (DesignChatDialog.vue:244, same key), and `<AgentChatDialog>`. The user's session id is the canonical lookup key in every case — `task.id === session.id` (migration 052 invariant) — so the store works uniformly.

4. **Kanban mode overview surfaces the error.** A small red ⚠ indicator appears on the kanban card (and the sidebar task row) for any session that has an active agent error. Three layered affordances, additive to the existing card UI:

   - **Red-tinted card border** — `--color-red` 55% alpha border + 25% alpha box-shadow ring, so the affected card stands out at a glance across a multi-column board. Catches the eye on the periphery, no reading required.
   - **Red ⚠ icon in the top row, next to the existing status indicators.** Fires on top of (additive to) the spinner / pulse dot / checkmark — because a retry chain runs WHILE the worker is active, the spinner and the error indicator must coexist. 3-pulse ping animation on first appearance, then settles to a steady ring. Tooltip on hover shows the parsed headline (`StreamInterrupted (callDynamicAgentNew)`) + retry chip (`retry 3/10`).
   - **Inline meta-row pill.** Belt-and-suspenders affordance — same data, different location. Users who scan the meta row at the bottom see `⚠ 3/10 retries` next to the last-updated time. Swaps to `⚠ workflow halted` on the TooManyRetries bail.

   The same indicator also surfaces on the **sidebar task row** (`WorkspaceItemTaskRow.vue`) — the red ⚠ icon in the same spot, red-bordered bullet, same store read. Users see "this chat has an error" regardless of which surface they're on (kanban board / chat list / sidebar).

## Background — why the card disappears today (verified 2026-08-29)

```
ChatView.vue:908
  const agentError = ref<AgentErrorEntry | null>(null)   // local to the component

AppLayout.vue:2670
  <ChatView
    v-else-if="activeChatId.startsWith('chat-')"
    :key="activeChatId"             ← forces a fresh mount on every sidebar switch
    :chat-id="activeChatId"
    ...
  />

StandardTaskChatView.vue:67
  <ChatView :key="`chat-${task.id}`" :chat-id="`chat-${task.id}`" ... />
                                          ↑ same pattern for standard task chats

KanbanChatDialog.vue:247 / DesignChatDialog.vue:246
  <ChatView v-if="task" :key="'task-' + task.id" :chat-id="task.id" ... />
                                  ↑ same pattern, dialog v-if remounts on open/close
```

Three clear sites in `ChatView.vue`:

1. **Line 2049** — `connectSse()` on mount: `agentError.value = null` ("fresh session starts with no error card"). After the move: this line is dropped (the store is the source of truth; the store for an unseen session is `null` naturally).
2. **Line 2156** — non-error renderable `full` event arrives: `agentError.value = null` ("the agent is alive again"). After the move: `agentErrorStore.clearForSession(sid)`.
3. **The implicit remount.** When `:key="activeChatId"` changes, Vue unmounts the old ChatView (the local `agentError` ref is GC'd) and mounts a fresh one (`onMounted` → `connectSse` → already at step 1 above). After the move: this implicit wipe vanishes because the ref no longer lives on the component.

The backend diagnostics are still `is_skip_db=true` (PR `task_1787663566535_2` made them live-only). Page refresh clears the store naturally — no contract change.

## File Structure

| File | Change |
|---|---|
| `src/apps/desktop/src/stores/agentError.ts` | NEW — Pinia store, `bySession: Record<session_id, AgentErrorEntry \| null>`, `setError(sid, content, id?)`, `clearForSession(sid)`, `errorFor(sid)` getter (or `getter`). |
| `src/apps/desktop/src/__tests__/agentError.spec.ts` | NEW — store unit tests (set/clear/getter, key isolation, multi-session independence, idempotent clear). |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT — replace `agentError` ref with `agentErrorStore`; update the 3 mutation sites (line ~2103 set, line ~2156 clear, drop line ~2049); template reads from `computed(() => agentErrorStore.bySession[sid])`. |
| `src/apps/desktop/src/__tests__/ChatView.agentErrorPersistence.spec.ts` | NEW — tests for the persistence contract (set in instance A → mount fresh instance with same sid → card still visible). |
| `src/apps/desktop/src/components/workspace/WorkspaceItemTaskCard.vue` | EDIT — read from `agentErrorStore` in the standard branch; render red ⚠ icon in the top row + red-tinted card border + inline meta-row pill. |
| `src/apps/desktop/src/components/workspace/WorkspaceItemTaskRow.vue` | EDIT — sidebar row: same store read; smaller red ⚠ icon in the row (sidebar already has tight horizontal real estate — no border / no meta pill, just the icon with tooltip). |
| `src/apps/desktop/src/__tests__/WorkspaceItemTaskCard.agentError.spec.ts` | NEW — indicator renders when `agentErrorStore.bySession[task.id]` is set; absent otherwise; pulses on first appearance; respects `prefers-reduced-motion` (no animation when reduced-motion is requested). |
| `src/apps/desktop/src/__tests__/WorkspaceItemTaskRow.agentError.spec.ts` | NEW — sidebar row variant: red ⚠ icon present when error, absent otherwise, tooltip on hover shows headline. |
| `preview-kanban-error.html` | NEW — design-time HTML mockup showing the proposed kanban card layout (committed at repo root for review). Self-contained; not bundled in production. |
| `src/apps/desktop/src/components/views/__tests__/ChatView.subagent-progress.spec.ts` + 6 other ChatView SSE-handler specs | NO CHANGE — they use the same SSE bus injection, the store is auto-discovered via Pinia. |

No backend changes. No migration. No SSE event_type additions. No `additionalEventTypes` changes — `is_error` is a *field* on `llm_full`, not a new event name. The "SSE wire-format contract — add event names in pairs" rule does NOT trigger.

---

## Task 1 — Pinia store + tests (TDD)

**File:** NEW `src/apps/desktop/src/stores/agentError.ts`, NEW `src/apps/desktop/src/__tests__/agentError.spec.ts`

- [ ] Write failing store tests FIRST (`agentError.spec.ts`). Use `setActivePinia(createPinia())` in `beforeEach`. Cases:
  - `setError('s1', 'c1', 'i1')` then `store.bySession.s1` deep-equals `{id:'i1', content:'c1'}`.
  - `setError('s1', 'c2')` (no id) auto-generates an id (`agent-error-${Date.now()}`-style, mocked via `vi.useFakeTimers().setSystemTime(...)`).
  - `setError('s1', 'c3')` AFTER a previous entry on `s1` overwrites (latest-wins, single slot).
  - `setError('s2', ...)` does NOT mutate `bySession.s1` (key isolation).
  - `clearForSession('s1')` sets `bySession.s1` to `null`. Idempotent: calling twice is safe.
  - `clearForSession('s1')` does NOT clear `bySession.s2`.
  - The getter `errorFor('s1')` returns `null` for an unknown sid (no spurious key insert).
  - After `setActivePinia(createPinia())` in a fresh test, the store starts empty (per-test isolation).
- [ ] Run `cd src/apps/desktop && pnpm test:unit -- agentError` — FAIL (file missing).
- [ ] Implement `agentError.ts`:

  ```ts
  import { defineStore } from 'pinia'
  import { ref } from 'vue'

  export interface AgentErrorEntry {
    id: string
    content: string
  }

  export const useAgentErrorStore = defineStore('agentError', () => {
    // session_id → current latest error (null = cleared/no error yet)
    const bySession = ref<Record<string, AgentErrorEntry | null>>({})

    function setError(sessionId: string, content: string, id?: string) {
      bySession.value = {
        ...bySession.value,
        [sessionId]: {
          id: id ?? `agent-error-${Date.now()}`,
          content,
        },
      }
    }

    function clearForSession(sessionId: string) {
      // Idempotent — deleting a missing key is fine. Use a fresh
      // object reference so Pinia reactivity picks up the change.
      if (!(sessionId in bySession.value)) return
      const next = { ...bySession.value }
      delete next[sessionId]
      bySession.value = next
    }

    function errorFor(sessionId: string): AgentErrorEntry | null {
      return bySession.value[sessionId] ?? null
    }

    return { bySession, setError, clearForSession, errorFor }
  })
  ```

  Notes — spread-then-assign preserves Vue 3 reactivity for objects (no need for `ref` deep tracking since the inner values are shallow). The `delete` branch in `clearForSession` is a no-op for sessions the user has never visited, which is the common case (avoids polluting `bySession` with empty entries).

- [ ] Run tests — PASS.
- [ ] Commit: `feat(chatview): agentError Pinia store keyed by session_id`

## Task 2 — Wire ChatView to the store + drop the remount-clear

**File:** `src/apps/desktop/src/components/views/ChatView.vue`

Three surgical edits:

- [ ] Import the store next to the existing Pinia store imports (`navigation`, `workspaces`). Single line: `import { useAgentErrorStore } from '../../stores/agentError'`.
- [ ] Instantiate the store at the same level as `processingState` (~line 285):

  ```ts
  const agentErrorStore = useAgentErrorStore()
  // Per-session derived read. Reads from the store (keyed by sessionId)
  // so the card survives ChatView remounts caused by AppLayout's
  // :key="activeChatId" or StandardTaskChatView's :key="chat-${task.id}"
  // on session/task switches. A user visiting session A, switching to
  // session B, then returning to session A still sees the most recent
  // error diagnostic for A.
  const agentError = computed<AgentErrorEntry | null>(() => agentErrorStore.errorFor(sessionId.value))
  ```

  Remove the old `const agentError = ref<AgentErrorEntry | null>(null)` (line 908). The `AgentErrorEntry` interface (lines 904-907) moves to `agentError.ts` and is imported here.

- [ ] SSE listener — line ~2103, the `if (event.type === 'full' && event.is_error)` branch. Replace the assignment:

  ```ts
  // Before
  agentError.value = { id: event.id || `agent-error-${Date.now()}`, content: event.content || '' }

  // After
  agentErrorStore.setError(sid, event.content || '', event.id || undefined)
  ```

  Keep the `nextTick(() => scrollToBottom(false, 'agent-error-card'))` (the auto-stick-to-bottom on a new error is part of the existing UX — see line 2107).

- [ ] Non-error renderable `full` event — line ~2154-2157, the "agent recovered" clear branch. Replace the assignment:

  ```ts
  // Before
  if (agentError.value) {
    console.log('[SSE ChatView] clearing agent error card on non-error full event')
    agentError.value = null
  }

  // After
  if (agentErrorStore.bySession[sid]) {
    console.log('[SSE ChatView] clearing agent error card on non-error full event')
    agentErrorStore.clearForSession(sid)
  }
  ```

  Note: read `bySession[sid]` (not `agentError.value`) to gate the log — the local computed would always reflect the same thing, but reading the store directly avoids an unnecessary `computed` re-eval on this code path.

- [ ] `connectSse()` session-switch reset — line ~2049. **DELETE** the line:

  ```ts
  // Before
  streamingContent.value = ''
  // 2026-08-25 agent-error-card: diagnostics are live-only per-session —
  // a fresh session starts with no error card.
  agentError.value = null   ← DELETE THIS LINE

  // After
  streamingContent.value = ''
  ```

  The fresh-session semantics are now implicit: `errorFor(unseenSid)` returns `null` from the store.

- [ ] Template — line ~3265-3271. **NO CHANGE NEEDED.** The template already binds `v-if="agentError"` and `:key="agentError.id" :content="agentError.content"`. The `computed` ref replaces the old `ref` of the same name, so the template binding resolves identically.

- [ ] Update the long-form comment block at lines 890-908 to point at the store (one or two sentences). Keep the "single-latest semantics — only the most recent error is rendered" paragraph verbatim — it's still accurate.

- [ ] Run `pnpm test:unit` and `pnpm type-check` — existing ChatView SSE-handler specs must still pass (they wire the bus, fire events, and assert the resulting `messages.value`; we did not touch that path).

- [ ] Commit: `feat(chatview): persist agent error across session remounts`

## Task 3 — Persistence regression test (the contract)

**File:** NEW `src/apps/desktop/src/__tests__/ChatView.agentErrorPersistence.spec.ts`

The bug we're fixing is "remount wipes the error". The regression test exercises the EXACT user-visible scenario: set an error on session A → unmount the ChatView → mount a fresh ChatView for session A → assert the card is still rendered.

- [ ] Write the test using the existing test harness pattern (mountChatView helper if one exists, otherwise mirror the SSE-bus pattern from `ChatView.stopSession.spec.ts` / `ChatView.subagent-progress.spec.ts`). Two cases:

  - **A — persistence across remount.** Mount ChatView with `:chat-id="'chat-s1'"`. Fire a `full` SSE event with `session_id: 's1'`, `type: 'full'`, `is_error: true`, `content: '[Retry 1/10] StreamInterrupted. Server said: …'`. Assert `<AgentErrorCard>` renders (`data-testid="agent-error-card"`). Unmount. Mount a fresh ChatView with the same `:chat-id="'chat-s1'"`. Fire NO new SSE events. Assert `<AgentErrorCard>` is STILL rendered with the same content. Pass condition: `wrapper.find('[data-testid="agent-error-card"]').exists() === true` AND the parsed headline / detail match the original payload.

  - **B — auto-clear on recovery.** Same setup as A. After the error fires, fire a non-error renderable `full` event (e.g. `type: 'full'`, `is_error: false`, `role: 'assistant'`, `content: 'hi'`, `finish_reason: 'stop'`, `hasRenderableFullPayload === true`). Assert the card disappears (`wrapper.find('[data-testid="agent-error-card"]').exists() === false`). Now mount a fresh ChatView for the same session. Assert it stays gone (the recovery clear persists too).

  - **C — key isolation.** Two ChatView instances simultaneously: one for `s1`, one for `s2`. Fire an error event for `s1`. Assert `s1`'s instance shows the card and `s2`'s instance does not. Swap: fire an error for `s2`. Assert both instances show their respective errors independently (no cross-talk).

- [ ] Run `pnpm test:unit -- ChatView.agentErrorPersistence` — FAIL pre-fix (test was just written; current ChatView wipes on remount so case A fails). After Task 2 lands — PASS.

- [ ] Commit: `test(chatview): agent-error persistence across remounts`

## Task 4 — Pinia store + ChatView wire-up verification

- [ ] `cd src/apps/desktop && pnpm test:unit` — green. No regression in existing ChatView SSE-handler specs (chunk-stream, stream-resume, subagent-progress, stopSession, hiddenMessages, profileCascade, updatePlan, expandStateStability, toolsPillStability, toolCallsJsonWireShape, scrollRestore).
- [ ] `cd src/apps/desktop && pnpm type-check` — green (vue-tsc on `tsconfig.app.json`).
- [ ] `cd src/apps/desktop && pnpm test:unit -- agentError` — green (Task 1 store tests).
- [ ] `cd src/apps/desktop && pnpm test:unit -- ChatView.agentErrorPersistence` — green (Task 3 regression).
- [ ] Manual smoke (optional): open session A, force a retry chain (point a profile at a bad base_url), confirm the error card renders with retry chip. Click session B (any other session) → click session A again → confirm the card is still there. Send a fresh prompt to session A → confirm the card clears on the first successful assistant turn.

## Task 5 — Kanban card error indicator (the new "show that" requirement)

**File:** `src/apps/desktop/src/components/workspace/WorkspaceItemTaskCard.vue`

Three layered affordances, all driven by the same store read:

- [ ] Inject the store next to the existing `processingState` injection (line ~64):

  ```ts
  import { useAgentErrorStore } from '../../stores/agentError'
  ...
  const agentErrorStore = useAgentErrorStore()

  // Reactive read of this task's latest agent error (or null). Keyed
  // by task.id == session_id (migration 052 invariant). Survives
  // ChatView remounts because the store outlives the component.
  const agentError = computed(() => agentErrorStore.bySession[props.task.id] ?? null)

  // Headline parser — extracted from AgentErrorCard.vue's identical
  // regex so the tooltip + the ChatView card show the same string.
  // Hoisted into a shared util in Task 5's companion change so we
  // don't duplicate the regex across two files.
  const errorHeadline = computed((): string | null => {
    const entry = agentError.value
    if (!entry) return null
    const reason = entry.content.match(/Reason for last retry:\s*(.+?)\.?\s*$/m)
    if (reason) return reason[1]!.trim()
    const stripped = entry.content.replace(/\[Retry \d+\/\d+\]\s*/, '')
    const firstLine = stripped.split('\n')[0] ?? stripped
    const m = firstLine.match(/^(.*?)\.\s*(Retrying|$)/)
    return (m ? m[1]! : firstLine).trim()
  })

  // Retry chip — `retry 3/10`. Null on the TooManyRetries bail.
  const errorRetryLabel = computed((): string | null => {
    const entry = agentError.value
    if (!entry) return null
    const m = entry.content.match(/\[Retry (\d+\/\d+)\]/)
    return m ? `retry ${m[1]}` : null
  })
  ```

- [ ] Extract the headline regex to a shared util so `AgentErrorCard.vue` and `WorkspaceItemTaskCard.vue` don't drift. Add `helpers/parseAgentErrorHeadline.ts` exporting `parseAgentErrorHeadline(content: string): { retryLabel: string | null; headline: string | null }`. Refactor `AgentErrorCard.vue` to use it (drops 3 inline regexes for one import; net −10 lines).

- [ ] Top-row icon — add a sibling element AFTER the existing spinner/pulse-dot/checkmark chain in the **standard branch** (line ~440-492). NOT inside the routine branch (routines don't run the agent loop):

  ```html
  <!-- 2026-08-29 agent-error-indicator — additive to spinner / pulse /
       checkmark because retry chains fire while the worker is still
       processing. Tooltip shows the same headline + retry chip the
       ChatView's AgentErrorCard parses, so users see the same
       information regardless of which surface they're on. Respects
       prefers-reduced-motion (no animation when requested). -->
  <span
    v-if="agentError"
    class="relative shrink-0 error-icon-wrap"
    data-testid="task-agent-error"
  >
    <span
      class="w-3.5 h-3.5 rounded-full flex items-center justify-center error-pulse"
      style="background: rgba(196, 116, 110, 0.18); border: 1px solid var(--color-red);"
      aria-label="Agent error — click card to view detail"
    >
      <span style="color: var(--color-red); font-size: 10px; line-height: 1;" aria-hidden="true">⚠</span>
    </span>
    <!-- Hover tooltip — same parsing as AgentErrorCard but trimmed
         (no server-detail block; the kanban-tooltip is too small for
         the raw body — the full detail lives in ChatView). -->
    <div
      class="error-tooltip absolute left-0 top-full mt-1.5 w-[280px] z-50 rounded-lg p-2 pointer-events-none opacity-0 invisible transition-opacity duration-150 group-hover/error:opacity-100 group-hover/error:visible"
      style="background: #0e0e0c; border: 1px solid rgba(196, 116, 110, 0.45); box-shadow: 0 4px 16px rgba(0,0,0,0.4);"
      role="tooltip"
    >
      <div class="flex items-center gap-2 mb-1.5">
        <span style="color: var(--color-red); font-size: 11px;" aria-hidden="true">⚠</span>
        <span class="text-[11px] font-medium" style="color: var(--color-red);">Agent error</span>
        <span
          v-if="errorRetryLabel"
          class="text-[10px] px-1.5 py-0.5 rounded-full"
          style="background: rgba(196, 116, 110, 0.18); color: #e8928c;"
          data-testid="task-agent-error-retry"
        >{{ errorRetryLabel }}</span>
      </div>
      <div class="text-[11px] leading-snug" style="color: var(--semantic-text-muted);" data-testid="task-agent-error-headline">
        {{ errorHeadline }}
      </div>
    </div>
  </span>
  ```

- [ ] Card-level red border — bind a class on the root `<button>`:

  ```html
  <button
    ...
    :class="agentError ? 'kanban-card has-error' : 'kanban-card'"
    :style="{ borderColor: agentError ? 'rgba(196, 116, 110, 0.55)' : undefined, ... }"
    ...
  >
  ```

  Or equivalently, use a CSS `data-attribute` selector in the scoped `<style>` block: `:deep([data-has-agent-error="true"]) { border-color: rgba(196, 116, 110, 0.55); box-shadow: 0 0 0 1px rgba(196, 116, 110, 0.25); }` — whichever is shorter. Add `data-has-agent-error="true"` to the root when `agentError.value !== null`.

- [ ] Inline meta-row pill — extend the existing meta row (line ~639). Add a sibling `<span>` next to `lastUpdatedLabel`:

  ```html
  <!-- 2026-08-29 agent-error-meta-pill — same data as the icon, in
       the meta row where users naturally scan for status. Shows
       `3/10 retries` while retrying, swaps to `workflow halted` on
       the TooManyRetries bail (when the content has no [Retry N/M]
       prefix and starts with `[Agent Nalar System error]`). -->
  <span
    v-if="agentError"
    class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded"
    style="background: rgba(196,116,110,0.12); color: var(--color-red);"
    data-testid="task-meta-agent-error"
  >
    <span aria-hidden="true">⚠</span>
    <span>{{ errorRetryLabel ? errorRetryLabel.replace('retry ', '') + ' retries' : 'workflow halted' }}</span>
  </span>
  ```

- [ ] Add the `agent-error-pulse` keyframes to the scoped `<style>` block alongside the existing `needs-review-pulse` (lines 707-734). Respect `prefers-reduced-motion`:

  ```css
  @media (prefers-reduced-motion: no-preference) {
    @keyframes agent-error-pulse {
      0%   { box-shadow: 0 0 0 0 rgba(196, 116, 110, 0.7); }
      70%  { box-shadow: 0 0 0 8px rgba(196, 116, 110, 0); }
      100% { box-shadow: 0 0 0 0 rgba(196, 116, 110, 0); }
    }
    .error-pulse {
      animation: agent-error-pulse 1.8s ease-out 3 forwards;
      border-radius: 50%;
    }
  }
  ```

  No rule inside the `@media (prefers-reduced-motion: reduce)` block — the `.error-pulse` class becomes a no-op, the icon stays as a steady ring without animation. Test this in the Task 6 spec with `matchMedia` mocked to `reduce`.

- [ ] Tests (TDD) in `src/apps/desktop/src/__tests__/WorkspaceItemTaskCard.agentError.spec.ts`:
  - Mount with `setActivePinia(createPinia())` + a fresh `agentErrorStore`. Render `<WorkspaceItemTaskCard :task="..." />`. Assert no indicator (`[data-testid="task-agent-error"]` not present).
  - Call `agentErrorStore.setError(task.id, '[Retry 3/10] StreamInterrupted (callDynamicAgentNew). Retrying in 5000ms. Server said: …')`. Assert indicator renders; tooltip shows `retry 3/10` chip + `StreamInterrupted (callDynamicAgentNew)` headline.
  - Assert card root has `data-has-agent-error="true"` (or class has `has-error`).
  - Assert meta-row pill renders `3/10 retries`.
  - Call `agentErrorStore.setError(task.id, '[Agent Nalar System error] workflow halted after 10 consecutive retries. Reason for last retry: StreamInterrupted. Server said: …')`. Assert pill swaps to `workflow halted`; no retry chip in tooltip.
  - Call `agentErrorStore.clearForSession(task.id)`. Assert all indicators (icon, border, pill) disappear.
  - Multi-task isolation: render two cards with different task ids; set error on task A; assert only A's card shows the indicator.
  - `prefers-reduced-motion: reduce`: mock `window.matchMedia('(prefers-reduced-motion: reduce)').matches === true`; assert `.error-pulse` does NOT apply the animation (computed style `animation-name === 'none'`). Uses `vi.stubGlobal('matchMedia', vi.fn(() => ({ matches: true, ... })))`.

- [ ] Run `pnpm test:unit -- WorkspaceItemTaskCard` — green.

- [ ] Commit: `feat(kanban-card): agent-error indicator + red border + meta pill`

## Task 6 — Sidebar task row indicator (companion to Task 5)

**File:** `src/apps/desktop/src/components/workspace/WorkspaceItemTaskRow.vue`

The sidebar row has tighter horizontal real estate — no border ring, no meta pill. Just a small red ⚠ icon in the same v-if chain where `processingState[task.id]` lives.

- [ ] Inject the store (mirror Task 5's injection in `WorkspaceItemTaskRow.vue` — same imports, same `computed` for `agentError` / `errorHeadline` / `errorRetryLabel`).
- [ ] Add the icon in the **standard branch** (the routine branch's "bullet / clock + status dot + pin + name" row at line ~110-150 doesn't get one — routines don't run the agent loop). Insert AFTER the `processingState[task.id]` bullet (line ~216-220, currently the only non-spinner v-if in the row), as a sibling v-if (not v-else-if — additive):

  ```html
  <!-- 2026-08-29 agent-error-row — sidebar variant of the kanban
       indicator. No border ring (no row-level border exists); no meta
       pill (the row has no meta row). Just the icon with the same
       hover-tooltip so users see "this chat has an error" in the
       chat list regardless of which surface they're on. -->
  <span
    v-if="agentError"
    class="relative shrink-0 error-icon-wrap"
    data-testid="task-agent-error-row"
  >
    <span
      class="w-3 h-3 rounded-full flex items-center justify-center"
      style="background: rgba(196, 116, 110, 0.18); border: 1px solid var(--color-red);"
      aria-label="Agent error"
    >
      <span style="color: var(--color-red); font-size: 8px; line-height: 1;" aria-hidden="true">⚠</span>
    </span>
    <!-- Same tooltip markup as the kanban card, but 240px wide -->
    <div class="error-tooltip absolute left-0 top-full mt-1.5 w-[240px] z-50 rounded-lg p-2 pointer-events-none opacity-0 invisible transition-opacity duration-150 group-hover/error:opacity-100 group-hover/error:visible" ...>
      ... same body ...
    </div>
  </span>
  ```

  Note: smaller (12px vs 14px) icon than the kanban card, because the row's vertical real estate is ~28px vs the card's ~80px. Tooltip text identical.

- [ ] Tests in `src/apps/desktop/src/__tests__/WorkspaceItemTaskRow.agentError.spec.ts`:
  - Row shows the red ⚠ icon when `agentErrorStore.bySession[task.id]` is set.
  - Tooltip on hover shows the same `retry N/M` + headline as the kanban card (asserted via `find('[role="tooltip"]')` after triggering `pointerenter` on the icon).
  - No icon when the store has no entry for this task.id.
  - Multi-task isolation (same shape as Task 5).

- [ ] Run `pnpm test:unit -- WorkspaceItemTaskRow` — green.

- [ ] Commit: `feat(sidebar-row): agent-error indicator with hover-tooltip`

## Task 7 — Final verification & wrap-up

- [ ] `cd src/apps/desktop && pnpm test:unit` — green. Full suite passes; no regressions in the 18+ ChatView / KanbanView / WorkspaceItemTask* specs already in the repo.
- [ ] `cd src/apps/desktop && pnpm type-check` — green.
- [ ] `cd src/apps/desktop && pnpm test:unit -- agentError` — green.
- [ ] `cd src/apps/desktop && pnpm test:unit -- ChatView.agentErrorPersistence` — green.
- [ ] `cd src/apps/desktop && pnpm test:unit -- WorkspaceItemTaskCard.agentError` — green.
- [ ] `cd src/apps/desktop && pnpm test:unit -- WorkspaceItemTaskRow.agentError` — green.
- [ ] Visual check (manual, optional): force a retry chain (point a profile at a bad base_url, send a message). Open the kanban board → confirm the card has the red border + ⚠ icon + meta pill. Hover the icon → confirm tooltip. Open the sidebar → confirm the chat list row has the red ⚠ icon. Click into the chat → confirm the AgentErrorCard renders in the chatview. Click back to the kanban board → confirm the indicators are STILL there (proves Tasks 5 + 6 read from the same store as Task 2). Send a fresh prompt → confirm all indicators clear together (single store mutation point).
- [ ] Update kanban: move task to `in_review_task` (human reviews; `merged` is human-only).
- [ ] Append an entry to the "Recent changes" block in `AGENTS.md` following the format of the previous entries (date, one-line summary, files-touched count, plan file path, branch, task id).

## Pitfalls

- **Don't reach for KeepAlive.** A previous mental draft used `<KeepAlive>` on `<ChatView>` to preserve all state. Rejected: KeepAlive preserves messages + scroll position + every `ref` + every Vuex/Pinia subscription per visited session. Memory grows linearly with sessions visited. Eviction is non-trivial. The scroll-restore contract (e.g. `useChatScrollRestore`) was designed assuming fresh mounts on session switch and would silently change behavior under KeepAlive. A focused store preserves only the one piece of state we need.
- **Don't add a new SSE event_type name.** The `is_error` flag is a FIELD on `llm_full`, not a new event type. Adding `event_type: 'llm_error'` would trigger the 3-site event-name pairing dance (backend emitter + `additionalEventTypes` + dispatch chain) and is explicitly rejected by the original PR (`2026-08-25-agent-error-card.md` §"Pitfalls").
- **Spread-then-assign for `bySession`.** Vue 3 reactivity tracks the outer `bySession` ref via shallow mode; mutating the inner object in place (`bySession.value[sid] = …`) would NOT trigger subscribers. Always replace the top-level ref via `bySession.value = { ...bySession.value, [sid]: … }`. The code in Task 1 already follows this — do not "optimize" it away.
- **Read the store, not the computed, in the SSE listener.** The non-error-clear gate at line ~2154 needs to fire the `console.log` exactly once per real clear, not on every event that happens to coincide with an already-null card. Reading `agentErrorStore.bySession[sid]` directly is the cheapest check (single hash lookup vs. computed re-evaluation).
- **Don't move `AgentErrorEntry` into ChatView's local types** — keep it as a store export so future consumers (a sidebar badge showing "this session has an active error") can reuse the shape.
- **No backend changes.** The wire format (`is_error: bool` on `llm_full`) is unchanged. The `is_skip_db=true` semantics from PR `task_1787663566535_2` are unchanged — a hard page refresh still clears the card (no localStorage hydration). Don't be tempted to add a REST endpoint to "persist" errors; that would change the backend's contract and require user-visible behavior changes we haven't asked for.
- **`pnpm`, not `npm` / `bun`.** Per the 2026-08-28 pnpm migration, all frontend commands use `pnpm`. Don't reintroduce `bun run` in scripts or docs (the `AGENTS.md` memory item + the build.zig chain enforce this).
- **Test isolation in the new store spec.** `setActivePinia(createPinia())` in `beforeEach` is mandatory — without it, tests leak `bySession` entries into each other and the "starts empty" assertion fails spuriously. Existing Pinia tests in the repo (e.g. `stores/navigation.spec.ts`, `recentFolders.spec.ts`) all use this pattern.
- **Indicator is ADDITIVE, not mutually exclusive.** The spinner / orange pulse / green checkmark are mutually exclusive in the same v-if/v-else-if chain in `WorkspaceItemTaskCard.vue` — but the agent-error indicator sits OUTSIDE that chain because retry attempts fire WHILE the worker is still active. Use `v-if="agentError"` after the chain, NOT as a `v-else-if` inside it. Tests in Task 5 must explicitly assert "error fires WHILE spinner also fires" — they will fail otherwise.
- **`prefers-reduced-motion` is mandatory for the pulse animation.** The existing `needs-review-pulse` keyframes already follow this pattern (lines 707-734 of `WorkspaceItemTaskCard.vue`); mirror it (no rule outside the `@media (prefers-reduced-motion: no-preference)` block). Test with `matchMedia` mocked to `reduce` in Task 5's spec — assert `getComputedStyle(el).animationName === 'none'`.
- **Don't duplicate the headline-regex across `AgentErrorCard.vue` and the new `WorkspaceItemTaskCard.vue`.** Extract to `helpers/parseAgentErrorHeadline.ts` in Task 5; refactor `AgentErrorCard.vue` to import from it. Two implementations of the same regex WILL drift, and the user-visible "headline on the card vs headline on the tooltip" mismatch will be subtle and confusing (user looks at tooltip, opens chat, sees slightly different wording).
- **Color tokens, not hex codes.** Use `var(--color-red)` / `var(--semantic-card-bg)` / `var(--semantic-text-muted)` (defined in `src/apps/desktop/src/style.css` lines 26-67) — NOT hex literals like `#c4746e`. The existing `WorkspaceItemTaskCard.vue` uses `var(--color-yellow)` for the spinner (line 334) and `var(--color-aqua)` for active styling (line 310). Mirror that pattern so the indicator automatically inherits any future theme changes (light mode, accessibility palettes). For the rgba alpha variants (border 55% alpha, background 12% alpha) use the hex-with-alpha form (`rgba(196,116,110,0.55)`) — the CSS variables don't expose alpha variants and Tailwind's `bg-red-500/15` shorthand hasn't been adopted everywhere in this file.
- **`KanbanCard.vue` wraps `WorkspaceItemTaskCard.vue` — don't double-inject the store in the wrapper.** `KanbanCard.vue` is a thin draggable wrapper (lines 88-111); it does NOT re-render the card content, just adds the draggable shell. Putting indicators in BOTH `KanbanCard` AND `WorkspaceItemTaskCard` would render them twice. Indicators belong in the inner card; the wrapper stays unchanged (no edit needed).
- **`task.id === session.id` is the key.** Migration 052 invariant — the kanban task's `id` IS the chat session's `id`. The store key (`session_id`) and the card key (`task.id`) are the same string. Don't introduce a separate mapping table — it's just a direct read: `agentErrorStore.bySession[task.id]`. If a future migration breaks this invariant, the symptom will be "kanban cards show no error but the chat still has one" — easy to spot, easy to fix by reading the right key.
- **Visual side-effect: card border changes height/width by 1px.** Switching from a 1px grey border to a 1px red border is the SAME pixel count — no layout shift. But the box-shadow ring (`box-shadow: 0 0 0 1px rgba(...)`) DOES extend beyond the border by 1px on all sides, which can cause adjacent cards to shift by 1px in dense columns. Acceptable trade-off (the affordance is more important than 1px alignment); but if a future density tweak makes the shift noticeable, the fix is to swap to `outline` instead of `box-shadow` (outline doesn't reserve layout space).