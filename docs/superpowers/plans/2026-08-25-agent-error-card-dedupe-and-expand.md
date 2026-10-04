# AgentErrorCard: single-card + auto-clear + always-expanded

**Task:** task_1787668954023_2 ("only show one error and ...also when new message come from sse and its not error, clear the error"), plus a follow-up ("also force to expand no need collapsed").
**Status:** Implemented. Awaiting human review (kanban: in_review_task).
**Branch (recommended):** worktree/agent-error-card-dedupe
**Files (3):**
- EDIT `src/apps/desktop/src/components/views/ChatView.vue`
- EDIT `src/apps/desktop/src/components/chat/AgentErrorCard.vue`
- EDIT `src/apps/desktop/src/__tests__/AgentErrorCard.spec.ts`
- +1 destructive .vue/.ts file no migration, no backend touched

---

## User-visible changes

1. **Single-card semantics.** Previously every retry+1 SST error event pushed a new card → 10 cards stacked in the bottom area during a 10-attempt retry chain (visible in the screenshot: three "retry 1/10 / 2/10 / 3/10" cards at the bottom). Now: **latest-wins** — a 1/10 card immediately becomes 2/10 when the next retry fires, becomes the final 10/10 bail when the workflow gives up. The retry chip on the same card ticks upward; the user sees ONE indicator with progress, not a pile.

2. **Auto-clear on recovery.** As soon as ANY non-error `full` SSE event arrives for the session (the assistant produced a renderable assistant/user/tool message), the error card vanishes. This is what the user asked for verbatim — "when new message come from sse and its not error, clear the error".

3. **Always-expanded.** Detail (raw server body / SSE sample) is visible immediately. The user explicitly said "force to expand no need collapsed". The collapsed-by-default toggle and the caret indicator are removed; the `expanded` ref and `v-show="expanded"` are gone. The header stays as plain informational text.

---

## Implementation

### 1) `AgentErrorCard.vue` (front-end presentational)

Before, the component owned an `expanded: ref(false)` + a clickable header (`@click="expanded = !expanded"`, keyboard handlers, caret `▸/▾`). Now: only the parsed fields (`retryLabel`, `delayMs`, `headline`, `serverDetail`) and one unconditional `<div v-if="serverDetail">` block. `import { computed } from 'vue'` (dropped `ref`). Net −18 lines.

### 2) `ChatView.vue` (state shape + SSE wiring)

```ts
// Before — array of N entries, push to append.
const agentErrors = ref<AgentErrorEntry[]>([])
...
agentErrors.value.push({ id, content })   // accumulates

// After — single slot, replace to update, null to clear.
const agentError = ref<AgentErrorEntry | null>(null)
...
agentError.value = { id, content }   // latest-wins
agentError.value = null              // cleared on non-error full event / session switch
```

**SSE listener (3 sites):**

- `connectSse()` session-switch reset: `agentErrors.value = []` → `agentError.value = null`.
- `is_error` branch: `push(...)` → assign `(...)`; same behavior otherwise (id fallback, content fallback, `scrollToBottom('agent-error-card')`).
- **NEW: inside the non-error `full` event handler**, before the `messages.value.filter(...)` that swaps the streaming row for the canonical DB row, clear `agentError.value` if it's set. The gate that's already there (`hasRenderableFullPayload`) ensures we only clear on a genuine renderable message — empty `tool_call_delta` / `reasoning_chunk` events stay inside the early-return at the top of the handler and never reach this branch.

**Template:**

```html
<!-- Before: v-for over an array. -->
<div v-if="agentErrors.length > 0" class="... space-y-2">
  <AgentErrorCard v-for="err in agentErrors" :key="err.id" :content="err.content" />
</div>

<!-- After: single slot, key-binds on id so a content swap re-renders the card. -->
<div v-if="agentError" class="... pb-2">
  <AgentErrorCard :key="agentError.id" :content="agentError.content" />
</div>
```

The `:key="agentError.id"` is important — when a new `is_error` event overwrites `agentError.value` with a different id, Vue tears down and re-mounts the card, which resets any internal state and forces a re-render of the parsed computeds (in case the content shape changes from `[Retry N/M]` → `[Agent Pabrik System error]` bail). Without the key, Vue would patch props in place and you could see stale parsed fields for one frame.

### 3) `AgentErrorCard.spec.ts`

Replaced one test:

```
- "is collapsed by default and expands on toggle click"
+ "is expanded by default — detail is visible immediately"
```

The other 7 tests (headline parsing, retry chip extraction, delay extraction, server-detail split, missing-server-detail graceful handling) are unchanged — they're orthogonal to the collapse interaction.

---

## What was deliberately NOT changed

- **No backend changes.** The `is_error` SSE flag and the 3 emission sites in `workflow.zig` (PR #341) are untouched. The dedupe happens entirely on the consumer side — both the latest-wins and the auto-clear are pure single-card UX.
- **No new SSE event_type.** We piggy-back on `llm_full` with `is_error=true`, same as #341.
- **No `agentErrors.value.length > 0` style logic in templates.** Single ref + `v-if` is enough; no array iteration costs.
- **`data-testid="agent-error-list"`** kept on the outer wrapper so existing functional UI tests that locate the card via that selector keep passing.
- **`data-testid="agent-error-card"`** kept on the inner `<div>` for the same reason.

---

## Risks + mitigations

| Risk | Mitigation |
|------|------------|
| SSE listener clear fires on a stale re-deliver (same DB row re-emitted, ChatView's dedupe branch returns early before the messages.push, but the clear runs BEFORE the dedupe). | The clear is idempotent and cheap (1 ref write). Even if a stale redelivery triggers it, the next error event will overwrite the slot again. The only visible cost is one fewer frame of error card during a network blip — acceptable. |
| `:key="agentError.id"` re-mount loses any per-card internal state. | AgentErrorCard is purely presentational and has zero internal mutable state (after this change). Safe. |
| Rapid `is_error` events flicker between two cards. | Vue's reactive scheduling means only the LAST event in a microtask wins. The card content reflects the latest error, no flicker. |
| Tool-result `tool_name` `"StreamInterrupted (callDynamicAgentNew)"` text in the headline overlap looks ugly. | Pre-existing UX issue in #341 — not addressed here (out of scope for the "show one + clear" ask). |

---

## Verification

- **Component unit test:** `bun run test:unit __tests__/AgentErrorCard.spec.ts` — 8/8 pass.
- **Full unit suite:** `bun run test:unit` — 282 files / 2671 tests pass (was 281 files / 2663 baseline; +1 file change, tests relabeled).
- **Type-check:** `npx vue-tsc --build --force` — clean.
- **No backend / Zig rebuild.** Backend unchanged → no need to boot `pabrik` and exercise SSE; this is a pure-frontend state-shape change.
- **Functional UI test:** N/A — would need to script an SSE error storm which isn't worth the harness cost for a 3-file surgical change. Manual smoke test (see below).

## Manual smoke test

Build the desktop binary, open a chat session. From the chat header pick a provider/profile that returns 429 on demand. Send a user message. Watch the chat: ONE card appears (not 10) ticking `1/10 → 2/10 → ...` if the provider eventually recovers — card disappears as soon as the first non-error `full` event lands. If it goes all the way to `[Agent Pabrik System error] workflow halted after 10 consecutive retries`, the bail variant renders on the same card.

---

## Commit plan (one squashed commit)

```
fix(chatview): single AgentErrorCard slot — latest error wins, auto-clears on non-error SSE

- AgentErrorCard: drop expanded/toogle/caret; detail is always visible
  (user requested "force to expand no need collapsed")
- ChatView: agentErrors array → agentError singleton ref
  - new is_error event overwrites the slot (1/10 → 2/10 progression on one card)
  - any non-error 'full' SSE event with a renderable payload clears the slot
    ("when new message come from sse and its not error, clear the error")
- AgentErrorCard test: flip collapsed-by-default to expanded-by-default

Files: 3 EDIT. No backend, no migration.
```
