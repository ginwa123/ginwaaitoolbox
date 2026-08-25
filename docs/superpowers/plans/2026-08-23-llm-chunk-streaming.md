# Plan: Real-time LLM Chunk Streaming in the Chatview

**Task:** task_1787499599017_8 ("implement a llm chunk")
**Date:** 2026-08-23
**Status:** PLANNED — awaiting human review. No code written yet.

---

## 1. Problem statement

The user wants real-time, token-level text streaming in the chatview: as the
LLM generates tokens over SSE, the assistant bubble should grow live instead
of appearing all at once when the turn finishes.

The surprising finding from research: **the entire streaming pipeline already
exists on both sides — but the frontend consumes it wrong**, so streaming is
effectively broken today.

## 2. Current architecture (verified by direct file reads)

```
LLM provider (SSE: choices[0].delta.content = raw DELTA)
        │
        ▼
Agent.zig parse_stream_chunk (line 1398)
  → extracts delta.content / delta.reasoning_content / delta.tool_calls
  → returns agent.StreamChunk (RAW DELTAS, not cumulative)
        │ callback(ctx, chunk) per SSE line (Agent.zig:1985)
        ▼
workflow.zig stream_callback (line 1521)
  → wraps into ContentChunk{index, content} / ReasoningChunk / ToolCallDeltaChunk
  → StreamingContext.chunk_index increments once per chunk
        │
        ▼
on_event_sent.zig sendStreamChunkContent/Reasoning/ToolCallDelta (lines 574-680)
  → serializeContentChunk → JSON {type:"chunk", index, content}
  → event_bus.emit("llm_chunk") on session_id key + "llm" broadcast key
        │
        ▼  (wire: event: llm_chunk)
api/index.ts (line 3193): llm_chunk|llm_full → opts.channels.llm.onEvent(data)
        │
        ▼
ChatView.vue bus.on('llm') handler (line 2120)
  → event.type === 'chunk' && event.content
      → streamingContent.value = event.content   ← ❌ REPLACE, should APPEND
      → updateStreamingMessage() renders it into a `streaming-*` message
```

Final convergence path (works today): after the stream ends,
`workflow.zig:1121` inserts the assistant row with `is_emit_sse=true` →
`event: llm_full` → ChatView replaces `streaming-*` with the canonical DB row.
So the final state is correct; only the *live* view is broken.

## 3. Root causes / gaps

### BUG #0 (BLOCKING): `llm_chunk` payloads lack `session_id` → all chunks dropped
The wire payload for content/reasoning/tool-call chunks is
`{type:"chunk", index, content}` (`ContentChunkJson`, on_event_sent.zig:469).
ChatView.vue:2121 gates every llm event on `event.session_id !== sid`;
`undefined !== sid` is always true, so **every chunk event is discarded at
the door**. (Full events survive because `SseEventLLMHistory` includes
`session_id`.) This must be fixed together with BUG #1 or streaming still
won't work.

### BUG #1 (core UX): frontend REPLACES instead of APPENDS
`ChatView.vue:2150`: `streamingContent.value = event.content`

The backend sends **deltas** (`choices[0].delta.content`). Replacing means the
user sees only the most recent fragment flickering, then nothing until
`llm_full` lands. This single line is why "realtime text from sse" doesn't work.

### BUG #2: `sendStreamChunkFinal` is dead code
Defined at `on_event_sent.zig:632`, never called anywhere in `src/`. The
frontend's `chunk_final` type exists in `SseEvent.type` union but never fires.
No usage/tokens reach the UI during the stream.

### BUG #3: `chunk_index` semantics are broken
`StreamingContext.chunk_index` resets to 0 for every LLM call and is shared
across content/reasoning/tool-call chunks. It cannot be used for ordering,
dedupe, or gap detection. Harmless today only because nobody uses it.

### GAP #4: no correlation id on chunk payloads
`llm_chunk` payload has `{type, index, content}` — no session-scoped message id.
The frontend can't tell which assistant turn a chunk belongs to if two turns
overlap (queued messages drain back-to-back). Low severity (single worker per
session today), but cheap to fix now.

### GAP #5: reasoning vs content inconsistency
Reasoning chunks already accumulate correctly (`ChatView.vue:2276-2292`
appends onto the streaming message). Content chunks replace. After fixing #1
both paths will be symmetric appends.

## 4. Design decisions

### D1 — Append deltas client-side; keep wire format unchanged ✅ (chosen)
Fix the one-line bug: `streamingContent.value += event.content`.

- Zero backend changes required for the core fix.
- Wire format stays `{type:"chunk", index, content}` — no SSE 3-site contract
  churn (backend emitter + additionalEventTypes + dispatch chain).
- Matches how every mainstream chat UI handles OpenAI-style deltas.

Alternative rejected: make the backend send cumulative text. Would double
payload size over the wire (O(n²) total bytes), require changes in 4 emitter
functions, and diverge from the provider-native delta shape.

### D2 — Reset accumulation on turn boundaries
Append-only state must be reset at the right moments:
- On `full` event arrival (turn finished → canonical row replaces stream).
- On `connectSse()` (already resets `streamingContent.value = ''`).
- On session switch (`disconnectSse()` already clears).
- Guard: if a `chunk` arrives with no active streaming message AND
  `isStreaming === false` (e.g. missed the start), start a fresh buffer rather
  than appending to a stale one.

### D3 — Emit `chunk_final` from the workflow loop (fixes BUG #2)
Call `sendStreamChunkFinal` right before the assistant row insert at
`workflow.zig:1121`, passing real usage + finish_reason. This gives the UI an
in-stream "done" signal so it can stop the typing indicator even in the window
before `llm_full` arrives. Payload already carries `usage`; extend
`FinalChunkJson` with `session_id` so the frontend can filter by session
(currently it can't — the payload has no session key).

### D4 — Make `index` monotonic per session-turn (fixes BUG #3, minimal)
Keep `chunk_index` incrementing across the whole turn (don't reset at
`chunk.done`), and document that content/reasoning/tool-call share one
sequence. Do NOT build out-of-order reassembly — SSE over localhost TCP is
ordered by construction; the index is for debugging/dedupe only.

### D5 — Add `session_id` to chunk payloads (**REQUIRED — part of core fix**, fixes GAP #4)
Add `session_id` field to `ContentChunkJson` / `ReasoningChunkJson` /
`FinalChunkJson` / `ToolCallDeltaChunkJson`.

> ✅ **VERIFIED (2026-08-23)**: this is not a nice-to-have — it is a blocking
> bug. Evidence chain:
> - Wire: `unified_events_sse.zig:41-78 forwardToClients` writes ONLY
>   `event: <event_type>` + `data: <payload JSON>`. The routing key ("llm")
>   and the SseEvent envelope's `session_id` field are NOT serialized —
>   whatever is inside `payload.data` is the entire body.
> - `llm_full` payloads work because `SseEventLLMHistory`
>   (sse_on_event_send_llm_history.zig:19-45) includes
>   `session_id: []const u8` (line 23) — populated from input at line 144.
> - `llm_chunk` payloads serialize as `ContentChunkJson`
>   (on_event_sent.zig:469-473) = `{type:"chunk", index, content}` — NO
>   `session_id`.
> - Frontend gate: ChatView.vue:2121 `if (event.session_id !== sid) return`.
>   For chunks, `event.session_id` is `undefined`; `undefined !== sid` is
>   true → **every llm_chunk event is silently dropped before the handler
>   body ever runs.**
>
> Consequence: BUG #1 (replace-vs-append) is currently MASKED — no chunk
> reaches line 2150 at all. Both fixes together are the minimum viable
> change; neither alone produces working streaming.

## 5. Implementation steps

### Phase 1 — Core fix (frontend, ~30 lines)
1. **ChatView.vue chunk handler** (line 2149):
   ```ts
   if (event.type === 'chunk' && event.content) {
     streamingContent.value += event.content   // was: =
     updateStreamingMessage()
     return
   }
   ```
2. Same treatment for the reasoning branch if needed (verify it appends —
   it does, line 2282).
3. Reset points audit: confirm `streamingContent.value = ''` fires on
   full-event (line 2232 ✓), disconnectSse (2323 ✓), connectSse (2112 ✓).

### Phase 2 — Backend: session_id on chunk payloads (**BLOCKING**, ~40 lines)
4. `on_event_sent.zig`: add `session_id: []const u8` to
   `ContentChunkJson`, `ReasoningChunkJson`, `FinalChunkJson`,
   `ToolCallDeltaChunkJson`; thread through the four `serialize*` fns and
   the four `sendStreamChunk*` emitters (they already receive `session_id`).
   Without this, the ChatView session filter drops every chunk (see D5).
5. Update the existing unit tests in `on_event_sent.zig` (there are tests at
   lines 763+ asserting payload shape).

### Phase 3 — Backend: emit chunk_final (~25 lines)
6. `workflow.zig` stream end (just before `insertLLMHistories` at 1121):
   call `on_event_sent.sendStreamChunkFinal(allocator, copy_session_id, .{
   .index = ..., .usage = mapped ChunkUsage, })`.
7. Map `agent.Usage` → `ChunkUsage` (check field names in on_event_sent.zig
   ~line 430).

### Phase 4 — Frontend: consume chunk_final (~15 lines)
8. In the `bus.on('llm')` handler, add a `chunk_final` branch: set a
   `finalArrived` flag / stop typing indicator; do NOT push a message (the
   canonical row comes via `llm_full` right after).

### Phase 5 — Tests
9. Frontend vitest: ChatView SSE spec — feed synthetic chunk events
   ("Hel", "lo ", "world") through the bus mock; assert the streaming
   message content equals "Hello world" (append), and that a following
   `full` event swaps in the canonical row and clears the buffer.
10. Zig unit test: `serializeContentChunk` includes `session_id`;
    `sendStreamChunkFinal` emits `type:"chunk_final"` with usage.
11. Manual smoke: run dev server on port 8080 (NOT 8081), send a chat
    message, watch tokens appear progressively.

## 6. Files touched

| File | Change |
|---|---|
| `src/apps/desktop/src/components/views/ChatView.vue` | append fix + chunk_final branch |
| `src/apps/desktop/src/__tests__/ChatView.*.spec.ts` | new streaming-append spec |
| `src/ai_workflow/tui/agentic_loop/on_event_sent.zig` | session_id on chunk JSONs |
| `src/ai_workflow/tui/agentic_loop/workflow.zig` | call sendStreamChunkFinal |
| `src/modules/agent/Agent.zig` | NO CHANGE (parser already correct) |

## 7. Risks / gotchas

- **Markdown mid-stream**: partial markdown (unclosed ``` fences, half a
  table) renders janky while streaming. Acceptable v1; the final `llm_full`
  render fixes it. Optional later: fence-aware buffering.
- **Double-render race**: if `llm_full` arrives while chunks are still being
  processed (shouldn't happen — same ordered SSE stream), the full-handler
  already removes `streaming-*` rows first. Safe.
- **Multi-LLM-call turns**: agentic loops call the LLM many times per user
  turn (tool calls between). Each call restarts deltas from empty. The
  current design (one streaming buffer per LLM call, cleared on each
  `full`) matches this — each intermediate assistant message gets its own
  streaming bubble, replaced by its own canonical row. Verify during smoke
  test that tool-call turns don't leave stale buffers.
- **Don't touch port 8081** for smoke testing — use 8080.
- **Vue reactivity**: appending to `existingMsg.content` inside
  `updateStreamingMessage` mutates a reactive object property — fine in
  Vue 3. But `messages.value.push` of a NEW streaming message per chunk
  would thrash VirtualScroller height estimates; keep the find-and-mutate
  pattern.

## 8. Verification

1. `zig build test --summary all` — no regressions (baseline 2402 pass).
2. `cd src/apps/desktop && npx vitest run` — new spec passes, existing 2500+
   specs stay green.
3. `vue-tsc` + `vite build` clean.
4. Functional smoke on port 8080: send message → text appears token-by-token
   → final message replaces streaming bubble → usage chips update.
