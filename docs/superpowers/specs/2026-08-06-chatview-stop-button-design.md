# Spec: ChatView Stop Button (cancel a running agent)

**Date:** 2026-08-06
**Task:** `task_1785730430551`
**Branch:** `worktree/chatview-stop`

## Context

User opens the chat view and the agent is actively running (LLM
streaming chunks, a tool call in flight, or a retry delay ticking).
There is no UI affordance to stop the agent — they must wait for
the agent to finish or restart the process. The backend cancel
mechanism already exists end-to-end:

- `POST /api/llm/session/:session/stop` (`src/main.zig:307`)
- `llm_history.cancelSession` (`llm_history.zig:2201`) → `UPDATE worker SET cancelled=1`
- `isWorkerCancelled` polled at the top of every workflow iteration (`workflow.zig:500`) and during retry delay (`retry_delay_ms.zig:42`)
- `deleteWorker` on break → SSE `worker deleted` event → `App.vue` removes session from `processingState`

Missing: the frontend API wrapper, the button, and the test
proving the button actually cancels the agent.

## Mental model

The frontend already has a global `processingState[sessionId]`
ref, kept up-to-date by SSE `worker` events (App.vue:48-69).
Anything in the app can `inject('processingState')` to know if
an agent is running. We add the Stop button to the chat input
area; it reads `isLLMProcessing` (the existing computed) and
toggles visibility.

The button calls `api.stopSession(sessionId)` → backend flips
`cancelled=1` → workflow breaks → SSE `worker deleted` →
`processingState[sessionId]` becomes false → button hides.

No new state. No new subscriptions. The existing SSE event bus
already does the heavy lifting; we just need to send the
cancel signal and let the bus report back.

## Visual

Input area (the row containing text input + 📎 file picker + Queue
button), with the new Stop button on the LEFT of the Queue button:

```
┌─────────────────────────────────────────────────────────┐
│ [text input.................................] [📎] [⬛ Stop] [Queue] │
└─────────────────────────────────────────────────────────┘
```

- Hidden when `isLLMProcessing === false`.
- Red filled square icon + "Stop" label.
- Click → spinner + label "Stopping…", button disabled.
- Hides within ~1s (when SSE `worker deleted` arrives).

## Behaviour matrix

| isLLMProcessing | isStopping | Visible? | Label | Action |
|---|---|---|---|---|
| false | (any) | no | — | — |
| true  | false  | yes | "Stop"      | POST `/api/llm/session/<sid>/stop` |
| true  | true   | yes | "Stopping…" | disabled (no re-click) |
| false | true   | no (but watch resets isStopping to false on next tick) | — | — |

## Architecture decisions

1. **Emit, don't call API directly, from FileInput.** The input
   component is shared across multiple chat views (standalone
   chat, KanbanChatDialog, kanban 3-column). The API call is
   tied to the chat's sessionId, not the input box. ChatView
   owns the API wrapper.

2. **No optimistic local flip of `isLLMProcessing`.** The SSE
   `worker deleted` event fires within milliseconds of the API
   response. A local optimistic flip would race with the SSE
   event and could cause button flicker (hide → re-show →
   hide). The `isStopping` flag is the only optimistic UI
   surface; `processingState` is the source of truth.

3. **Don't cancel queued messages.** The stop button only flips
   the worker `cancelled` flag. Queued messages remain queued
   and will be drained by the next session. This is intentional
   — cancelling queued messages is a separate UX decision (the
   user might want to queue 3 follow-ups, stop the current run,
   and let the queue drain).

4. **No confirmation modal.** Per the project's
   "I just want it to stop now" UX pattern. The button is small,
   red, and prominently placed; mis-clicks are recoverable (the
   user can re-send the message).

5. **Mid-stream cancellation is out of scope for v1.** The
   cancel check fires at iteration boundaries, not inside the
   LLM SSE chunk read loop. The user might see one more chunk
   land after clicking Stop. True mid-stream interrupt requires
   plumbing a cancellation signal into `Agent.zig::callStreaming`'s
   recv loop, which currently declares `error.Cancelled` but
   never returns it. Follow-up.

## Test plan

### `FileInput.stopButton.spec.ts` (NEW, 8 tests)

- A: button hidden when `isLLMProcessing=false`.
- B: button shown when `isLLMProcessing=true`.
- C: label is "Stop" by default, "Stopping…" when `isStopping=true`.
- D: button click emits `stop-session` exactly once.
- E: button is disabled + shows spinner while `isStopping=true`.
- F: clicking while `isStopping=true` does NOT emit (debounce).
- G: when `isLLMProcessing` flips to false, button re-hides.
- H: `isStopping` resets to false when `isLLMProcessing` flips to false.

### `ChatView.stopSession.spec.ts` (NEW, 5 tests)

- A: clicking Stop calls `api.stopSession(sessionId)` with the
  active session id (un-prefixed, no `chat-`).
- B: rapid double-clicks result in exactly one `api.stopSession`
  call (debounce via FileInput's `isStopping`).
- C: SSE `worker deleted` event hides the button.
- D: `api.stopSession` rejection is caught (no unhandled promise).
- E: error state preserves the button (until SSE clears).

## Out of scope (deferred)

- Mid-stream cancellation inside `Agent.zig::callStreaming`.
- Keyboard shortcut (Esc / Cmd+.).
- Cancellation confirmation modal.
- Cancelling queued messages.

## Affected files

| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | + `stopSession()` |
| `src/apps/desktop/src/components/file/FileInput.vue` | + `isStopping` prop, + `stop-session` emit, + button template |
| `src/apps/desktop/src/components/views/ChatView.vue` | + `handleStopSession`, + `@stop-session` binding |
| `src/apps/desktop/src/__tests__/FileInput.stopButton.spec.ts` | NEW |
| `src/apps/desktop/src/__tests__/ChatView.stopSession.spec.ts` | NEW |
| `AGENTS.md` | + changelog block |
| `docs/SPEC.md` | + changelog row |

## Verification

- `bun run build` — vue-tsc passes.
- `bunx vitest run` — all new tests pass, no regressions.
- `zig build test --summary all` — no backend changes; smoke
  test confirms the existing handler responds (POST returns
  `{"success":true,"session_id":"..."}`).
- Manual smoke on port 8080 (live chat with running agent).