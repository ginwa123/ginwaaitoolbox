# Plan: Only `full` SSE events render persisted message bubbles

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development
> (if subagents available) or superpowers:executing-plans to implement this
> plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In `ChatView.vue`, the SSE event with `type === "full"` is the ONLY
event that mutates the persisted `messages` array. Streaming events
(`chunk`, `reasoning_chunk`, `chunk_final`, `tool_call_delta`) update a
separate `streamingMessage` ref that is rendered as a transient "live"
bubble, never mixed into chat history.

**Architecture:** Split transient streaming state from the persisted
message list. The `messages` ref becomes a clean array of fully-formed
message records (one per `full` event). A new `streamingMessage` ref
holds the in-progress assistant turn and is rendered as a special
"streaming" bubble alongside the regular list. The current
`streaming-${Date.now()}` prefix hack and the `!m.id.startsWith('streaming-')`
filter on every `full` event go away.

**Tech Stack:** Vue 3 (`<script setup lang="ts">`, `ref`, `computed`),
TypeScript, Vite + `vue-tsc`. No backend changes — the
`src/ai_workflow/tui/on_event_sent.zig` event type field is already
correct (defaults to `"full"` for persisted messages; sends `"chunk"`,
`"reasoning_chunk"`, `"chunk_final"`, `"tool_call_delta"` for streaming).

---

## 1. Symptom / problem statement

### 1.1 What the user sees (current behavior)

- During LLM streaming, the chat shows an assistant bubble that grows
  in place as chunks arrive.
- When the stream completes, the streaming bubble is replaced by a
  final bubble with the complete content.
- This is the **intended** UX — but the implementation that produces
  it is fragile.

### 1.2 What is wrong (root cause)

`src/apps/desktop/src/components/ChatView.vue:1058-1090` (SSE handler):

```ts
if (event.type === 'chunk' && event.content) {
  streamingContent.value = event.content
  updateStreamingMessage()                        // <-- mutates `messages`
  return
}

if (event.type === 'full' && event.finish_reason && event.content) {
  messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))
  // ...
  messages.value.push({ id: event.id || `assistant-${Date.now()}`, ... })
}
```

`updateStreamingMessage` (lines 1196-1224) **pushes a `Message` object
into the `messages` array** with `id = `streaming-${Date.now()}`` and
content = the latest `streamingContent.value`:

```ts
messages.value.push({
  id: `streaming-${Date.now()}`,
  role: 'assistant',
  content: streamingContent.value,
  timestamp: new Date(),
})
```

So the `messages` array — which is also populated by `loadChatHistory`
from the persisted SQLite `llm_history` table — contains BOTH:

1. **Persisted messages** (loaded from DB and pushed on `full` events)
2. **Transient streaming placeholders** (pushed on every `chunk` event
   while a stream is in flight)

The "transition" from streaming to persisted is faked by:

- A `streaming-` id prefix that gets stripped on the next `full` event.
- A filter `messages.value.filter((m) => !m.id.startsWith('streaming-'))`.

### 1.3 Why this is fragile

- **Filter can be skipped.** The `full` branch is gated on
  `event.finish_reason && event.content` (line 1085). If the backend
  sends a `full` event without one of those, the streaming placeholder
  stays in `messages` forever (until next `loadChatHistory`).
- **Cross-contamination during pagination.** `loadChatHistory` maps DB
  rows into `Message` objects; if it runs while a stream is in flight
  (e.g. user scrolls to top and triggers `loadMore`), the streaming
  placeholder lives in `messages.value` while the user is also looking
  at historical data — and any code that mutates `messages` while
  assuming all entries are persisted (saveMessage mirrors, search
  indexers, etc.) sees the placeholder.
- **Grouping logic is wrong during streaming.** `messageGroups` is a
  `computed` that groups consecutive messages by role (line 523). A
  `streaming-` placeholder grouped next to a real assistant message
  is fine, but two consecutive `full` events for the same turn (e.g.
  if a tool_call round produces a placeholder that isn't cleaned up)
  produce duplicated bubbles.
- **Test surface is opaque.** There's no explicit assertion that
  "only `full` types create messages". A future maintainer who adds a
  new SSE type can accidentally regress this.
- **The "id prefix" convention is a stringly-typed contract** that has
  to be repeated in three places (push, filter, find-existing in
  `updateStreamingMessage`).

### 1.4 What the user wants

A refactor where the `messages` array contains ONLY `full`-type
records (the persisted chat history). Streaming content is held in a
separate, dedicated piece of state. The rendered output is the same —
the user still sees a live-updating bubble during streaming — but the
data model is clean and the "is this a streaming placeholder or a real
message?" question can be answered by `===` on a single ref, not by
`startsWith('streaming-')`.

---

## 2. Design

### 2.1 State shape

**Before** (one mixed array):

```ts
const messages = ref<Message[]>([])            // persisted + streaming
const streamingContent = ref('')               // latest chunk text
```

**After** (one persisted array + one optional streaming record):

```ts
const messages = ref<Message[]>([])            // PERSISTED only — `full` events
const streamingMessage = ref<Message | null>(null)  // live assistant turn
const streamingContent = ref('')               // kept for backwards compat / typing indicator
```

`streamingMessage` is a `Message`-shaped object (same interface) but
its lifetime is bound to the SSE stream, not to the DB. It's
**never** included in `messages.value` and is rendered as a separate
"streaming" group in the template.

### 2.2 SSE handler rules (post-refactor)

| SSE `event.type`     | Action                                                 |
| -------------------- | ------------------------------------------------------ |
| `connected`          | No-op (already handled at line 1049)                   |
| `chunk`              | Update `streamingContent` + replace `streamingMessage` |
| `reasoning_chunk`    | Same as `chunk` (set a `reasoning` field if we add one) |
| `chunk_final`        | No-op (protocol marker, no UI effect)                  |
| `tool_call_delta`    | No-op (UI shows tool call from the eventual `full`)    |
| `full`               | **Push to `messages.value`, clear `streamingMessage`** |

Critical invariant: **only the `full` branch may call `messages.value.push(...)`**.

### 2.3 Template rendering

The `messageGroups` computed (lines 523-543) groups consecutive
messages of the same role. The simplest way to slot the streaming
message in is to compose a separate `displayGroups` computed that
appends the streaming message (wrapped in a `MessageGroup` with a
synthetic `id`) to the persisted `messageGroups`.

```ts
const displayGroups = computed((): MessageGroup[] => {
  const groups = messageGroups.value
  if (!streamingMessage.value) return groups
  // The streaming message is always assistant, always the LAST group.
  // If the last persisted group is also assistant, merge it.
  const last = groups[groups.length - 1]
  if (last && last.role === 'assistant') {
    // Streaming content is fresh, so the merged group is a single
    // synthetic message — the persisted one is the previous turn.
    return [...groups.slice(0, -1), {
      ...last,
      messages: [...last.messages, streamingMessage.value],
    }]
  }
  return [...groups, {
    role: 'assistant',
    messages: [streamingMessage.value],
    timestamp: streamingMessage.value.timestamp,
  }]
})
```

**Caveat:** the template iterates `messageGroups` (not
`displayGroups`) in 3 places — the empty-state `v-if`,
`hasBubbleContent` (which uses `groupToolNames` based on
`messageGroups` indexes), and the main `<VirtualScroller>`. We must
switch ALL of them to `displayGroups`. A simple grep-and-replace.

`hasBubbleContent` uses `groupToolNames.value[groupIndex]` — that
array is built from `messageGroups` (line 550). The streaming group
should never carry a tool-call header (we don't get `tool_calls_json`
on `chunk` events), so we add a one-line guard:

```ts
const groupToolNames = computed((): (string | null)[] => {
  return displayGroups.value.map(...)  // (changed from messageGroups.value)
})
```

(Or, equivalently, leave `groupToolNames` reading `messageGroups` and
pass a streaming-aware `groupIndex` offset — but switching it to
`displayGroups` is simpler and the per-group `id` is not used
elsewhere in the index.)

### 2.4 Streaming bubble visual

For minimal UX impact, the streaming bubble should look identical to
the current "in-place" rendering. Two ways to achieve that:

**Option A (chosen):** Render the streaming message using the same
template paths as a regular `assistant` group (lines 1615-1674 in the
current code). The only visual difference: skip the
`renderResponse` markdown parse on the streaming message and show
plain text + a blinking cursor `<span class="cursor">▍</span>`. This
avoids the cost of `marked.parse()` on every chunk.

**Option B:** Keep the existing inline streaming bubble (no refactor
to the template's `group.role === 'assistant'` branch). Simpler but
duplicates the rendering path.

→ **Go with Option A.** Lower code-duplication, the cursor
distinguishes "still typing" from "finished", and we already have a
`hasVisibleContent` helper to gate the empty-streaming case (e.g.
during the first 50ms before any chunk arrives).

### 2.5 State transitions

```
stream start (first chunk arrives)
  └─ streamingMessage = { id: `streaming-${chunkIndex}`, role: 'assistant', content, timestamp }
  └─ (do NOT push to messages)

stream continues
  └─ streamingMessage.content = latest content
  └─ scroll-to-bottom per chunk (unchanged)

stream ends (full event arrives)
  └─ messages.push({ id: event.id, role, content, finish_reason, ... })  // persisted
  └─ streamingMessage = null
  └─ scroll-to-bottom once more (existing behavior)

stream interrupted (SSE error / disconnectSse)
  └─ streamingMessage = null   // clear, do NOT promote to messages
  └─ existing isStreaming = false (unchanged)
```

Note the asymmetry: **on SSE error, the in-flight streaming message
is dropped, not promoted**. A "promote on error" path would
preserve the user's partial output but would also persist data the
LLM didn't actually finalize — leading to a chat history that
disagrees with the model's actual final state. The current behavior
(discards the streaming placeholder) is the safer default and is
what we keep.

---

## 3. File map

| File                                                                                          | Action |
| --------------------------------------------------------------------------------------------- | ------ |
| `src/apps/desktop/src/components/ChatView.vue`                                                | Modify — refactor SSE handler + state + template (see tasks) |
| `src/apps/desktop/src/__tests__/ChatView.sse.spec.ts`                                         | Create — new unit tests for the SSE → state mapping         |
| (no backend changes — `on_event_sent.zig` types are already correct)                          | n/a    |

The backend already emits the right shape:

- `SseEventLLMHistory.type` defaults to `"full"` (line 56)
- `ContentChunkJson.type` = `"chunk"` (line 355)
- `ReasoningChunkJson.type` = `"chunk"` (line 362)
- `FinalChunkJson.type` = `"chunk_final"` (line 368)
- `ToolCallDeltaChunkJson.type` = `"tool_call_delta"` (line 376)

No `on_event_sent.zig` changes are required.

---

## 4. Tasks

### Task 1: Add `streamingMessage` ref and explicit event-type dispatch

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue:222-235` (state declarations)
- Modify: `src/apps/desktop/src/components/ChatView.vue:1054-1105` (SSE handler)

- [ ] **Step 1.1:** Add `streamingMessage: Ref<Message | null>` next to
  the existing `streamingContent` ref (around line 226).

  ```ts
  const streamingMessage = ref<Message | null>(null)
  ```

- [ ] **Step 1.2:** Refactor the SSE handler to dispatch on
  `event.type` with an explicit `switch`. The new handler:

  - `case 'chunk'`: update `streamingMessage` (find or create), update
    `streamingContent`, return.
  - `case 'reasoning_chunk'`: no-op for now (existing
    `event.reasoning_content` log at line 1124 is preserved).
  - `case 'chunk_final'`: no-op.
  - `case 'tool_call_delta'`: no-op.
  - `case 'full'`: push to `messages.value`, clear `streamingMessage`,
    set `isStreaming = false`, scroll-to-bottom, update
    `maxTotalTokens` (all the existing behavior at lines 1085-1119).
  - `default` (including `connected`): preserved behavior at line 1049.

- [ ] **Step 1.3:** Remove the `streaming-` filter
  (`messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))`)
  — it must not run anywhere after this refactor.

- [ ] **Step 1.4:** In `disconnectSse` (line 1158), set
  `streamingMessage.value = null` (in addition to the existing
  `messages.value.filter((m) => !m.id.startsWith('streaming-'))` —
  that filter goes away in step 1.3).

- [ ] **Step 1.5:** Update `updateStreamingMessage` (lines 1185-1224)
  to mutate `streamingMessage.value` instead of `messages.value`:

  ```ts
  if (streamingMessage.value) {
    streamingMessage.value.content = streamingContent.value
  } else {
    streamingMessage.value = {
      id: `streaming-${Date.now()}`,
      role: 'assistant',
      content: streamingContent.value,
      timestamp: new Date(),
    }
  }
  ```

  Keep the rest of `updateStreamingMessage` (the
  `lastAutoStickAt.value = Date.now()`, the `stripThinkingTags`
  scroll-gate, the `sseScrollPending` rAF coalesce, the
  `setupCodeBlockCopyButtons` call) untouched.

- [ ] **Step 1.6:** Verify with `bun run build` (NOT
  `bun run build-only` — the desktop app uses `vue-tsc --build` for
  type checking; see the [Bug Fixes / Desktop app] entry in the
  system memory).

  Expected: PASS with no type errors. The new `streamingMessage` ref
  is used; `messages.value.push` is no longer called from the chunk
  branch.

- [ ] **Step 1.7:** Commit

  ```bash
  git add src/apps/desktop/src/components/ChatView.vue
  git commit -m "refactor(chatview): split streaming message from persisted messages array"
  ```

---

### Task 2: Render `streamingMessage` in the template as a transient group

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue:507-580` (computeds)
- Modify: `src/apps/desktop/src/components/ChatView.vue:1373-1692` (template)
- Modify: `src/apps/desktop/src/components/ChatView.vue:2030-2050` (styles, optional cursor)

- [ ] **Step 2.1:** Add a `displayGroups` computed (per §2.3 above)
  that appends `streamingMessage` to `messageGroups` if it exists.

- [ ] **Step 2.2:** Find all three template references to
  `messageGroups`:

  - `v-if="!isLoading && messageGroups.length === 0"` (line 1408)
  - `:items="messageGroups"` on `<VirtualScroller>` (line 1429)
  - `groupToolNames` (line 550) — change input from
    `messageGroups.value` to `displayGroups.value`.

  Switch ALL of them to `displayGroups`.

- [ ] **Step 2.3:** Inside the `<template #default>` of
  `<VirtualScroller>`, add a synthetic `id` to the streaming group
  (e.g. `streaming-group`) so the `expandedToolIds` and
  `hasBubbleContent` lookups don't collide with persisted ids.

  Simplest: a `:key` on the inner `<div class="flex gap-3 pb-4">`
  (line 1442) that incorporates `group.id` or, for the streaming
  group, the literal `'streaming'`. This is what makes the
  VirtualScroller re-render correctly when the streaming group is
  created/destroyed.

- [ ] **Step 2.4:** Add a blinking cursor next to the streaming
  bubble's text. In the `assistant` branch of the template
  (line 1615+), wrap the streaming message's text in
  `<span>{{ msg.content }}<span class="cursor">▍</span></span>` only
  when `streamingMessage` is non-null (use a `v-if` on a new
  `isStreamingGroup` computed).

- [ ] **Step 2.5:** Add the `.cursor` CSS:

  ```css
  :deep(.cursor) {
    display: inline-block;
    margin-left: 2px;
    animation: blink 1s steps(2) infinite;
  }
  @keyframes blink {
    50% { opacity: 0; }
  }
  ```

- [ ] **Step 2.6:** Verify with `bun run build` + manual smoke
  test in the running app:

  1. Open a chat, send a message, watch the streaming bubble grow
     with a blinking cursor.
  2. When the stream ends, the cursor disappears and the bubble
     becomes a normal persisted assistant message.
  3. Reload the page — the persisted message is still there
     (proves it was saved correctly).
  4. Disconnect the network mid-stream — the streaming bubble
     disappears, no orphaned message is left in the chat.

- [ ] **Step 2.7:** Commit

  ```bash
  git add src/apps/desktop/src/components/ChatView.vue
  git commit -m "feat(chatview): render streaming message as transient group with cursor"
  ```

---

### Task 3: Unit tests for the SSE → state mapping

**Files:**
- Create: `src/apps/desktop/src/__tests__/ChatView.sse.spec.ts`

> Note: the test should import the **logic** of the SSE handler, not
> mount the full component (mounting requires `inject`s, a
> `VirtualScroller` stub, and the `api.createSseConnection` factory —
> too much surface for the property under test). Extract the handler
> into a pure function in `src/apps/desktop/src/helpers/sseState.ts`
> and unit-test that. (See Task 3.1.)

- [ ] **Step 3.1:** Extract the SSE-to-state logic into a pure
  function:

  ```ts
  // src/apps/desktop/src/helpers/sseState.ts
  export interface SseState {
    messages: Message[]
    streamingMessage: Message | null
    isStreaming: boolean
  }

  export function applySseEvent(
    state: SseState,
    event: SseEvent,
  ): SseState {
    switch (event.type) {
      case 'chunk':
        if (!event.content) return state
        return {
          ...state,
          streamingMessage: state.streamingMessage
            ? { ...state.streamingMessage, content: event.content }
            : {
                id: `streaming-${Date.now()}`,
                role: 'assistant',
                content: event.content,
                timestamp: new Date(),
              },
          isStreaming: true,
        }
      case 'full':
        if (!event.finish_reason || !event.content) return state
        return {
          messages: [...state.messages, {
            id: event.id ?? `assistant-${Date.now()}`,
            role: (event.role as any) ?? 'assistant',
            content: event.content,
            timestamp: new Date(),
            tool_name: event.tool_name,
            diffview_before: event.diffview_before,
            diffview_after: event.diffview_after,
            finish_reason: event.finish_reason,
            tool_call_id: event.tool_call_id,
          }],
          streamingMessage: null,
          isStreaming: false,
        }
      default:
        return state
    }
  }
  ```

  (This is a sketch — refine field names to match the existing
  `Message` interface in `ChatView.vue:49-61`.)

- [ ] **Step 3.2:** In `ChatView.vue`, replace the inline SSE
  handler body with `applySseEvent(currentState, event)` calls
  inside a `setState` block. The side-effects
  (`scrollLogger.markProgrammatic`, `lastAutoStickAt.value = …`,
  `scrollToBottom(…)`, `setupCodeBlockCopyButtons`, `maxTotalTokens`)
  stay in the wrapper — only the **data** transition is delegated
  to `applySseEvent`.

- [ ] **Step 3.3:** Write tests in
  `src/apps/desktop/src/__tests__/ChatView.sse.spec.ts`. At
  minimum:

  ```ts
  test('chunk event does NOT push to messages', () => {
    const before: SseState = { messages: [], streamingMessage: null, isStreaming: false }
    const after = applySseEvent(before, { type: 'chunk', content: 'hi', session_id: 's' })
    expect(after.messages).toEqual([])
    expect(after.streamingMessage).not.toBeNull()
    expect(after.streamingMessage!.content).toBe('hi')
  })

  test('full event pushes to messages and clears streaming', () => {
    const before: SseState = {
      messages: [],
      streamingMessage: { id: 'streaming-1', role: 'assistant', content: 'partial', timestamp: new Date(0) },
      isStreaming: true,
    }
    const after = applySseEvent(before, {
      type: 'full', session_id: 's', content: 'final',
      finish_reason: 'stop', role: 'assistant',
    })
    expect(after.messages).toHaveLength(1)
    expect(after.messages[0].content).toBe('final')
    expect(after.streamingMessage).toBeNull()
    expect(after.isStreaming).toBe(false)
  })

  test('full event without finish_reason is a no-op (no partial persist)', () => {
    const before: SseState = { messages: [], streamingMessage: null, isStreaming: true }
    const after = applySseEvent(before, { type: 'full', session_id: 's', content: 'x' })
    expect(after.messages).toEqual([])
    expect(after.isStreaming).toBe(true)
  })

  test('full event is the ONLY path that grows messages', () => {
    const before: SseState = { messages: [], streamingMessage: null, isStreaming: false }
    // A flurry of streaming events must not grow `messages`.
    let s = before
    for (const chunk of ['a', 'ab', 'abc', 'abcd']) {
      s = applySseEvent(s, { type: 'chunk', session_id: 's', content: chunk })
    }
    expect(s.messages).toEqual([])
    expect(s.streamingMessage!.content).toBe('abcd')
    // One `full` event grows it by exactly one.
    s = applySseEvent(s, { type: 'full', session_id: 's', content: 'abcd', finish_reason: 'stop' })
    expect(s.messages).toHaveLength(1)
    expect(s.messages[0].content).toBe('abcd')
  })

  test('reasoning_chunk / chunk_final / tool_call_delta are no-ops on state', () => {
    const before: SseState = { messages: [], streamingMessage: null, isStreaming: false }
    for (const type of ['reasoning_chunk', 'chunk_final', 'tool_call_delta'] as const) {
      const after = applySseEvent(before, { type, session_id: 's', content: 'x' } as any)
      expect(after.messages).toEqual([])
      expect(after.streamingMessage).toBeNull()
    }
  })
  ```

- [ ] **Step 3.4:** Register the test in the test runner. Look for
  the existing test entry-point pattern in the desktop app (search
  for `vitest.config` or the existing `__tests__` folder to find how
  the existing tests are wired).

  Expected: `bun test` (or whichever command the project uses —
  confirm by reading `package.json` and the existing
  `__tests__/sseClient.spec.ts` if it exists) discovers and runs
  the new file.

- [ ] **Step 3.5:** Run the test suite. Expected: PASS for the 5
  new tests above; all pre-existing tests still pass (no behavior
  change for persisted messages, only internal refactor).

- [ ] **Step 3.6:** Commit

  ```bash
  git add src/apps/desktop/src/helpers/sseState.ts \
          src/apps/desktop/src/__tests__/ChatView.sse.spec.ts \
          src/apps/desktop/src/components/ChatView.vue
  git commit -m "test(chatview): assert only 'full' events mutate the messages array"
  ```

---

### Task 4: Drop the `streaming-` prefix machinery

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue` (anywhere
  the prefix appears)

- [ ] **Step 4.1:** Grep for `streaming-` and `startsWith('streaming-')`
  in `ChatView.vue`. After Tasks 1-3, the only remaining references
  should be:
  - `streamingMessage.value?.id.startsWith('streaming-')` (now used
    only for the synthetic id, harmless but the prefix is no longer
    semantically meaningful — rename the prefix to `live-` to
    reflect its new role, or just keep it; the only criterion is
    that no other code branches on it).

  Pick one: **rename to `live-`** to make the intent explicit
  (the prefix now means "this is a live, in-flight message — never
  persisted" rather than "filter this out on the next full event").

- [ ] **Step 4.2:** Run `rg "streaming-" src/apps/desktop` and
  confirm no branch logic depends on the prefix. The grep should
  return only:
  - The id assignment in the SSE chunk branch.
  - Comments.

- [ ] **Step 4.3:** Run `bun run build` and the full test suite.
  Expected: green.

- [ ] **Step 4.4:** Commit

  ```bash
  git add src/apps/desktop/src/components/ChatView.vue
  git commit -m "refactor(chatview): rename streaming- prefix to live- (no longer a filter target)"
  ```

---

## 5. Verification

After all tasks are complete:

1. **Static checks**
   - `bun run build` — clean (no `vue-tsc` errors).
   - `bun test` — all tests pass (existing + 5 new).

2. **End-to-end smoke (manual)**
   - Open `http://localhost:8080` in the desktop app.
   - Send a message. Observe:
     - A streaming bubble appears with a blinking cursor.
     - As chunks arrive, the bubble grows in place.
     - When the stream ends, the cursor disappears. The bubble is
       visually identical to a normal assistant message.
   - Reload the page. The persisted assistant message is still
     there. The streaming bubble does NOT re-appear.
   - In DevTools, inspect the Vue devtools: `messages.length` is
     the count of persisted messages, `streamingMessage` is `null`
     when not actively streaming. The two values are independent.

3. **Edge cases (manual)**
   - **Network drop mid-stream:** Turn off Wi-Fi during a stream.
     After the SSE client transitions to `failed`, `streamingMessage`
     should be `null` (verified via Vue devtools) and no orphaned
     bubble remains in the chat.
   - **Rapid tool-call round:** Send a message that triggers a tool
     call. The streaming bubble should appear, be cleared when the
     tool result returns (or when the next `full` event arrives),
     then a new streaming bubble should appear for the post-tool
     assistant turn. No duplicated bubbles.
   - **Paginated history during stream:** Scroll to the top of a
     long chat while a stream is in flight in another window (or
     trigger pagination programmatically via the `load-more`
     button). The history pagination should not affect the
     streaming bubble in the active view.

---

## 6. Risks

| Risk                                                                                              | Mitigation                                                                                                              |
| ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Streaming bubble flickers between renders when the `displayGroups` recomputes                      | The `<VirtualScroller>` keyed on `displayGroups` (not `messages`) is enough; we add a stable `id` per group in Task 2.3. |
| The "drop on error" behavior (don't promote streaming to persisted) loses user data               | Acceptable. Mirrors the current behavior. Document in a code comment. A future "promote on error" feature is a separate plan. |
| The `Message` interface gains new fields (e.g. `is_streaming: boolean`) for the template         | Don't do it. The `streamingMessage` ref's existence is the signal; no need to overload the persisted type.               |
| The frontend tests can't mount `ChatView.vue` directly because of `inject`s and router             | Use the pure-function approach in Task 3 (extract `applySseEvent`). Don't add a heavyweight component test.              |
| Existing tests on `__tests__/sseClient.spec.ts` break if we change event payloads                 | We are not changing the SSE wire format. The `type` field is already in the JSON. No `sseClient` changes.              |

---

## 7. Out of scope (deliberate)

- **Backend changes.** The `on_event_sent.zig` types are already
  correct. Don't touch.
- **Promoting streaming to persisted on error.** Discussed in §2.5.
  Separate plan.
- **Reasoning content streaming.** The `reasoning_chunk` events are
  currently logged to the console (line 1124) but not rendered.
  Showing them in the UI is a separate UX decision.
- **Reorganizing ChatView.vue into smaller files.** ChatView.vue is
  2154 lines and would benefit from a split (SSE handler, message
  grouping, scroll handling, file attachments, etc.). That's a
  separate refactor — this plan should not balloon into it. The
  `applySseEvent` extraction in Task 3.1 is a step in that direction
  but only for the SSE logic.
