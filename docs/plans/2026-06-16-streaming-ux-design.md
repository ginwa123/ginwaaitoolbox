# Plan: Better UI/UX for Backend → Frontend LLM Streaming

> **Goal:** Make the chat feel alive. As the LLM generates tokens, the
> user sees them appear in real time — with a blinking caret, a visible
> "thinking" placeholder while the first token travels, a collapsible
> `<think>…</think>` panel for chain-of-thought, a live "Calling X…"
> card while tool arguments stream in, and a Cancel button that
> actually stops the run.

---

## 1. Symptom (what the user sees today)

1. User types a message and hits Enter.
2. The chat shows a blank `streaming-…` bubble for several seconds
   (time-to-first-token, ~1–10 s depending on model).
3. When the LLM starts producing tokens, the bubble **does not grow**.
   The user sees a brief flash of the LAST token, then the message
   appears fully formed in a new bubble when the `full` event arrives.

So the streaming UX is broken in three ways:

- **No progressive reveal.** The user can't read the answer as it
  streams because the bubble only ever shows the last delta (1–3 chars).
- **No thinking / reasoning panel.** Reasoning content (`<think>…`)
  arrives as SSE chunks but is `console.log`'d and discarded.
- **No tool-call preview.** The user can't see "Calling `read_file`…"
  until the tool call is fully assembled and the `full` event lands.

The root cause is **a one-character bug in the frontend's chunk
handler**: it uses `=` (replace) where it should use `+=` (append).

There are also three smaller wire-format and feature gaps that
matter once the core bug is fixed (see §2).

---

## 2. Current state (what is broken)

### 2.1 The chunk handler REPLACES instead of APPENDS

`src/apps/desktop/src/components/ChatView.vue:1396-1400`

```ts
if (event.type === 'chunk' && event.content) {
  streamingContent.value = event.content     // ← bug: REPLACES
  updateStreamingMessage()
  return
}
```

The backend sends **deltas** (1–3 chars each, per the OpenAI streaming
protocol parsed in `src/modules/agent/Agent.zig:1100-1106`):

```zig
const msg_field = first_choice.object.get("delta") orelse first_choice.object.get("message");
if (delta.object.get("content")) |content| {
    if (content == .string and content.string.len > 0) {
        chunk.content = content.string;     // ← delta, not cumulative
    }
}
```

So `event.content` is the new token(s), and `streamingContent.value =
event.content` overwrites the buffer on every chunk. The bubble only
ever shows the most recent delta. The progressive reveal is destroyed.

### 2.2 Reasoning chunks are mislabeled as `"chunk"`

`src/ai_workflow/tui/on_event_sent.zig:367`

```zig
const ReasoningChunkJson = struct {
    index: usize,
    reasoning_content: []const u8,
    type: []const u8 = "chunk",      // ← wrong; should be "reasoning_chunk"
};
```

The frontend's `SseEvent.type` declares `'reasoning_chunk'` as a valid
value (`src/apps/desktop/src/api/index.ts:613`), but no chunk ever
arrives with that type, so the reasoning handler is dead code. Worse,
since both `ContentChunk` and `ReasoningChunk` are labeled `type:
"chunk"`, the frontend can't tell them apart — it just `console.log`s
the reasoning and never renders it.

### 2.3 No cancellation path

`src/ai_workflow/tui/ActiveLoops.zig` is a `StringHashMap(void)` set
keyed by `session_id`. There is a `tryInsert` / `remove` / `contains`
API but **no way to signal a running loop to abort**. The HTTP
router has no `POST /api/llm/cancel/:session_id` handler. The
frontend has no Cancel button.

### 2.4 Tool-call deltas are emitted but never displayed live

`stream_callback` in `src/ai_workflow/tui/workflow.zig:1030-1038`
emits `ToolCallDeltaChunk` events as the LLM streams tool names and
arguments. The frontend has no handler for `type: 'tool_call_delta'`
(the `SseEvent.type` union includes it but no branch matches). The
user only sees a tool call once the `full` event arrives with the
assembled `tool_calls_json` array.

---

## 3. Goals & non-goals

### Goals

- **G1.** The streaming bubble grows token-by-token as the LLM emits
  them, with a smooth visual effect (no flicker, no full re-render).
- **G2.** A blinking caret marks the "end" of the in-progress
  response; it disappears on `full`.
- **G3.** While the LLM is preparing its first token, a "Thinking…"
  placeholder is visible (dismisses on first chunk).
- **G4.** Reasoning content (`<think>…</think>`) renders in a
  collapsible panel above the answer, default-collapsed, animated.
- **G5.** When a tool call begins (first `tool_call_delta` with a
  `function_name`), a "Calling X…" card appears live and updates as
  arguments stream in. Transitions to the final tool-card view on `full`.
- **G6.** A Cancel button is visible during streaming. Clicking it
  sends `POST /api/llm/cancel/:session_id`; the backend signals the
  active loop to abort, emits a `cancelled` event, and tears down.
- **G7.** Token count + approximate speed (`tokens/sec`) shown next
  to the streaming bubble.
- **G8.** The implementation is **fully resilient to dropped chunks**:
  the existing SseClient auto-reconnect (see `docs/sse-reconnect-plan.md`)
  is sufficient because (a) the backend emits a periodic cumulative
  snapshot event (every N chunks OR every 2 s, whichever first) so the
  frontend can resync after a long disconnect, and (b) the `full` event
  at the end is the authoritative final content.

### Non-goals

- **NG1.** No new transport. SSE stays the wire protocol. No
  WebSocket, no long-poll, no chunked HTTP.
- **NG2.** No new persistence. The DB still stores the final
  message; we don't persist every intermediate chunk.
- **NG3.** No multi-stream / multi-LLM UI. This plan assumes one
  active stream per chat, as today.
- **NG4.** No mobile-app redesign. This plan improves the desktop
  Vue UI; mobile-app parity is a follow-up.

---

## 4. Wire format (the protocol delta)

The protocol change is **additive** — old clients keep working because
the `full` event is unchanged and the `type: "chunk"` (content) event
is also unchanged in shape. Only the `type` string for reasoning
changes, and two new event types are added.

| Event `type`     | When emitted                          | Frontend action                    |
|------------------|----------------------------------------|-------------------------------------|
| `connected`      | SSE handshake (already exists)         | (no-op)                             |
| `chunk`          | Each content token delta (already)     | **APPEND** to streaming bubble      |
| `reasoning_chunk`| Each reasoning token delta (FIX label) | Append to reasoning buffer          |
| `tool_call_delta`| Tool name/args deltas (already)        | Update "Calling X…" card            |
| `snapshot`       | **NEW** — periodic cumulative content  | Replace streaming bubble content    |
| `cancelled`      | **NEW** — user cancelled              | Tear down streaming UI              |
| `full`           | LLM call complete (already)            | Commit final message                |

**Snapshot event shape** (new):

```json
{
  "type": "snapshot",
  "index": 42,
  "content": "Full cumulative assistant content so far…",
  "reasoning_content": "Full cumulative reasoning so far…",
  "is_thinking": false
}
```

**Cancelled event shape** (new):

```json
{
  "type": "cancelled",
  "session_id": "session-123",
  "partial_content": "Content emitted before cancel…"
}
```

The `snapshot` event is emitted on a 2-second timer from
`stream_callback` (or every 20 chunks, whichever fires first), with
`index` set to the current chunk counter. The frontend uses it to
resync when the SseClient reconnects after a long drop.

---

## 5. Architecture (data flow)

```
LLM upstream (OpenAI / Anthropic)
  └─ StreamChunk.content = delta
     └─ src/modules/agent/Agent.zig:1100-1106 (parse_stream_chunk)
        └─ src/ai_workflow/tui/workflow.zig:994-1041 (stream_callback)
           ├─ on_event_sent.sendStreamChunkContent       (chunk)
           ├─ on_event_sent.sendStreamChunkReasoning     (reasoning_chunk)  [FIX label]
           ├─ on_event_sent.sendStreamToolCallDelta      (tool_call_delta)
           └─ NEW: on_event_sent.sendStreamSnapshot      (snapshot, every 2 s)
              └─ event_bus.emit(SseEvent, session_id, …)
                 └─ src/ai_workflow/tui/http_handlers/llm_history_sse.zig:11
                    └─ server.sse_manager.sendToClient(client_id, …)
                       └─ Browser EventSource → helpers/sseClient.ts
                          └─ createSseConnection onMessage
                             └─ ChatView.vue:1373 (connectSse)
                                ├─ chunk           → streamingContent.value += event.content
                                ├─ reasoning_chunk → reasoningContent.value += event.reasoning_content
                                ├─ tool_call_delta → liveToolCall.value = assemble(deltas)
                                ├─ snapshot        → streamingContent.value  = event.content
                                │                    (overwrite is OK; snapshot is cumulative)
                                ├─ cancelled       → teardown streaming UI
                                └─ full            → commit final Message
```

---

## 6. Cancellation flow (new)

```
User clicks Cancel button
  └─ Frontend: api.cancelChat(sessionId)
     └─ POST /api/llm/cancel/:session_id
        └─ NEW handler: src/ai_workflow/tui/http_handlers/llm_cancel.zig
           ├─ Mark session_id in di.cancel_signals (new map)
           └─ Return 200
              └─ Workflow's `runAgenticMultiStepnew` checks `cancel_signals.contains(session_id)`
                 in three places:
                   1. Before each LLM call (callDynamicAgentNew)
                   2. Inside the streaming callback (stream_callback)
                   3. At the top of the outer while loop
                 └─ On cancel signal: emit `cancelled` event, return error.Cancelled
                    └─ workflow.zig catch block: markSessionIdle, return
```

The `cancel_signals` map lives on the `nalarcore` singleton (parallel
to `active_loops`), uses the same `std.Io.Mutex` pattern, and is
cleared at the end of every run (success, error, or cancel).

---

## 7. File layout (where the code lives)

### Frontend (TypeScript / Vue)

- `src/apps/desktop/src/api/index.ts` — extend `SseEvent` interface
  with `cancelled` and `snapshot` types; add `cancelChat` API
- `src/apps/desktop/src/components/ChatView.vue` — fix the
  `=` → `+=` bug; add reasoning/tool/cancel handlers; add caret
  animation; add Cancel button; add token counter
- `src/apps/desktop/src/components/StreamingIndicator.vue` —
  **NEW** — the "Thinking…" placeholder + blinking caret
- `src/apps/desktop/src/components/ReasoningPanel.vue` — **NEW** —
  collapsible reasoning content with smooth open/close animation
- `src/apps/desktop/src/components/LiveToolCallCard.vue` — **NEW** —
  "Calling X…" card that updates as deltas arrive
- `src/apps/desktop/src/components/CancelButton.vue` — **NEW** —
  Cancel button with confirmation popover
- `src/apps/desktop/src/helpers/streamingBuffer.ts` — **NEW** —
  small utility for append/overwrite/snapshot logic per session
- `src/apps/desktop/src/helpers/snapshotSync.ts` — **NEW** — handles
  the `snapshot` event resync logic

### Backend (Zig)

- `src/ai_workflow/tui/on_event_sent.zig` — fix `ReasoningChunk`
  label; add `sendStreamSnapshot` and `sendStreamCancelled` helpers
- `src/ai_workflow/tui/workflow.zig` — add cancel-signal check in
  `stream_callback` and `runAgenticMultiStepnew`; add snapshot
  timer; emit `cancelled` on abort
- `src/ai_workflow/tui/ActiveLoops.zig` — add `cancelSignals` map
  (or split into a new `CancelSignals.zig` module)
- `src/ai_workflow/tui/http_handlers/llm_cancel.zig` — **NEW** —
  `POST /api/llm/cancel/:session_id` handler
- `src/ai_workflow/tui/http_handlers/mod.zig` — register the new
  handler
- `src/main.zig` — register the new HTTP route
- `src/ai_workflow/tui/on_event_sent.zig` — extend
  `OnEventInputLLMHistory` with an `event_type` discriminator field
  so the same emitter can send `chunk` / `reasoning_chunk` /
  `snapshot` / `cancelled` (or keep the separate `sendStream*` API)

---

## 8. UX details

### 8.1 Caret / typing indicator

- A 2-px-wide vertical bar at the END of the streaming text, color =
  `var(--color-violet)`, blinking at 1 Hz via CSS `animation`.
- Position: `position: absolute; right: -8px; top: 0; bottom: 0;`
  inside the bubble's `relative` container.
- Implementation: a single `<span class="streaming-caret">` appended
  to the bubble when `isStreaming` is true, removed on `full`.

### 8.2 "Thinking…" placeholder

- Rendered as a 3-dot animated indicator (CSS keyframe `bounce` with
  staggered delays).
- Visible only between `connectSse()` and the first `chunk` /
  `reasoning_chunk` / `tool_call_delta` event.
- Dismissed by the same code path that creates the streaming message
  (the `existingMsg = find(...)` lookup will return `undefined`, so
  `updateStreamingMessage` falls through to the "create new" branch).

### 8.3 Reasoning panel

- Above the answer bubble, only when `reasoningContent.value` is
  non-empty.
- Default state: collapsed (height = 32 px, shows "💭 Reasoning
  (1234 chars) ▾").
- Click to expand: smooth 200 ms `max-height` transition; content is
  rendered as `<pre>` with monospace font and a slightly dimmed color.
- Reasoning content is NOT stripped of `<think>` tags here — that
  happens in `stripThinkingTags` only when the assistant role is
  decided to be the user-facing role. (Current logic: if the model
  emits `<markdown>…<plain>…`, the markdown is the answer and the
  plain is the reasoning. We re-use this convention.)

### 8.4 Live tool call card

- Appears as soon as a `tool_call_delta` arrives with a non-null
  `function_name`. The card shows:
  - Tool name (e.g. `read_file`)
  - A truncated, live-updating preview of the arguments JSON
    (parsed on the fly; if parse fails, show as a dimmed `<pre>`)
  - A small spinner indicating "in progress"
- On `full` event arrival, the card transitions to the existing
  `Bash` / `ReadFile` / `WriteFile` / `Glob` etc. component used by
  the final message render path.

### 8.5 Cancel button

- Position: floating in the bottom-right of the chat area, ABOVE the
  existing "scroll-to-bottom" button (z-index higher).
- Visible only when `isStreaming` is true.
- On click: opens a small confirmation popover ("Cancel this
  response? You can keep typing.") with two buttons: "Cancel" (sends
  the API call) and "Keep waiting" (dismisses the popover).
- On confirmation: sends `cancelChat`, marks `isStreaming` to false
  immediately (optimistic), shows a "Cancelling…" status, and the
  final state is reached when the `cancelled` event arrives.

### 8.6 Token counter + speed

- Position: small text next to the streaming bubble, `12px`, dimmed
  color.
- Format: "X tokens · Y tok/s" (rounded Y to 1 decimal).
- Y is computed from the last 5 chunks' timestamps:
  `tokensSinceStart / timeSinceStart`. Updated on every chunk.
- Shown only when `total_tokens` is known (i.e. after the first
  usage-bearing event). Hidden when 0 or null.

---

## 9. Testing strategy

Each chunk is independently testable. The test taxonomy is:

### Backend (Zig) — `zig build test`

- **Unit tests** in `*_test.zig` files colocated with the source
- **Static contract tests** for protocol shape (regex over the
  serialized JSON)
- **Pattern**: every new `OnEventInputLLMHistory` field gets a
  static test in `on_event_sent_test.zig` asserting the JSON shape
  is correct.

### Frontend (Vue / TS) — `bun run build` + `bunx vitest run`

- **Unit tests** for `streamingBuffer.ts` (pure logic, fast, easy)
- **Component tests** for the new components (`StreamingIndicator`,
  `ReasoningPanel`, `LiveToolCallCard`, `CancelButton`) using
  `@vue/test-utils` + jsdom
- **Integration tests** in `__tests__/streamingFlow.spec.ts` that
  feed a sequence of mock SSE events into the ChatView's handler
  and assert the final `messages` array

### Manual end-to-end test (port 8080)

1. `zig build install:linux:system` → `./zig-out/bin/nalar --port 8080 &`
2. Open `http://127.0.0.1:8080`, send a message that triggers a
   multi-tool-call agent run (e.g. "list the files in this repo
   and read the first one")
3. Observe: streaming text grows token-by-token; reasoning panel
   appears (if model emits `<think>`); tool call cards show as
   deltas arrive; cancel button works; refresh mid-stream keeps
   state via the `snapshot` event.

---

## 10. Rollout plan (chunks)

The work is split into 6 chunks. Each is independently shippable.

| # | Name                                  | Priority | Files touched (primary)                                  |
|---|---------------------------------------|----------|---------------------------------------------------------|
| 1 | Core streaming fix + caret            | **MUST** | `ChatView.vue`, `on_event_sent.zig`                     |
| 2 | Reasoning panel                       | SHOULD   | `ChatView.vue`, `on_event_sent.zig`, `ReasoningPanel.vue`|
| 3 | Live tool call card                   | SHOULD   | `ChatView.vue`, `LiveToolCallCard.vue`                  |
| 4 | Cancellation                          | SHOULD   | `llm_cancel.zig` (new), `workflow.zig`, `ChatView.vue` |
| 5 | Resilience (snapshot resync)          | COULD    | `on_event_sent.zig`, `workflow.zig`, `snapshotSync.ts`  |
| 6 | Polish (token counter, animations)    | NICE     | `ChatView.vue`, new components                          |

Chunks 1 + 4 are the highest-priority user-visible wins. Chunks 2
and 3 are visible to power users. Chunk 5 is invisible-but-critical
for users on flaky networks. Chunk 6 is nice-to-have.

The full implementation plan with bite-sized tasks per chunk lives
in `docs/superpowers/plans/2026-06-16-streaming-ux.md`.
