# chatview-stop-button (2026-08-06)

## What landed (squash-merged candidate)

A red Stop button in the chat input area, visible only while the
LLM is processing. Clicking it calls `api.stopSession(sessionId)`
which POSTs to the existing backend endpoint
`/api/llm/session/:sid/stop`. Backend flips
`worker.cancelled=1`, the workflow loop breaks at the next iteration
boundary, deletes the worker, and the SSE `worker deleted` event
removes the session from `processingState`. The button auto-hides.

## Architecture (frontend-only change — backend already wired)

1. `api.stopSession(sessionId)` — POST wrapper around
   `apiFetch('/llm/session/<sid>/stop', { method: 'POST' })`. Returns
   `{ success, session_id? }`. Swallows non-2xx with a typed response
   so callers never need try/catch.

2. `FileInput.vue` Stop button — visible only when
   `isLLMProcessing=true`. Red filled-square icon, "Stop" label.
   Emits `stop-session` to ChatView. New `isStopping` prop drives
   the spinner + "Stopping…" label + debounces clicks.

3. `ChatView.vue::handleStopSession` — translates the emit into the
   API call. **Never optimistically flips `isLLMProcessing`
   locally** — would race with the SSE event and cause button
   flicker (hide → re-show → hide).

4. Two new spec files: `FileInput.stopButton.spec.ts` (8 tests) +
   `ChatView.stopSession.spec.ts` (5 tests) = 13 behavioural tests.

## Pitfall (record for future agents)

**`processingState` MUST be a Vue `ref()`, not a plain
`{ value: ... }` object.** Vue's reactivity tracks reassignments to
the ref's `.value` via a Proxy. A plain object that LOOKS like a
ref (has `.value`) is invisible to the reactivity system — mutations
to `.value` don't trigger re-renders even though the object identity
is preserved.

The first test C draft declared `processingState` as
`{ value: {} }` (a plain object) and the computed `isLLMProcessing`
never re-evaluated despite the mutation propagating. The fix was to
import `ref` from Vue and call `ref({})` — the proxy wraps the inner
object and `ps.value = { ...ps.value }` notifies subscribers.

The lesson: when a test injects a ref via `provide()`, ALWAYS
create it with Vue's `ref()` factory. The TS type
`{ value: T }` is structurally identical to `Ref<T>` but only the
real `ref()` produces a reactive proxy.

## Test setup pattern (ChatView, with sseBus + processingState)

```ts
import { ref, type Ref } from 'vue'

// 1. Stub the SSE bus with a global stub SseClient (never use
//    jsdom's EventSource — it idles silently).
__resetSseBus()
const app = createApp({})
installSseBus(app)
__setSseBusGlobalClient(makeStubClient('connecting'))

// 2. Provide a real Vue ref() so mutations trigger reactivity.
const processingState = ref<Record<string, boolean>>({})
processingState.value['session_under_test'] = true

// 3. Mount ChatView with the ref injected.
const wrapper = mount(ChatView, {
  props: { chatId: 'session_under_test', chatName: 'T' },
  attachTo: document.body,
  global: { provide: { processingState } },
})

// 4. To simulate the SSE worker deleted event arriving (the path
//    that drives processingState in production):
delete processingState.value['session_under_test']
processingState.value = { ...processingState.value }
```

The `processingState.value = { ... }` reassignment is the documented
contract for `ref` re-notifying subscribers, even when the inner
object is also a reactive proxy.

## Button visibility on mount

ChatView's `isLLMProcessing` is `inject<Ref<...>>('processingState',
ref({}))` — if the provide lookup fails, it returns the DEFAULT
`ref({})`, and `processingState.value[sessionId.value]` is always
undefined. So a test that forgets to inject `processingState` will
see the button never appear (silent failure). Always inject it,
even in tests that don't drive button visibility.

## Related

- Plan: `docs/superpowers/plans/2026-08-06-chatview-stop-button.md`
- Spec: `docs/superpowers/specs/2026-08-06-chatview-stop-button-design.md`
- Backend endpoint: `src/ai_workflow/tui/http_handlers/session_stop.zig`
- Backend cancel helper: `src/ai_workflow/tui/llm_history.zig:2201` (`cancelSession`)
- Workflow loop check: `workflow.zig:500` (`isWorkerCancelled`)
- Retry delay check: `retry_delay_ms.zig:42` (`isWorkerCancelled`)
- `processingState` ref: `src/apps/desktop/src/App.vue:36`
- `processingState` SSE handler: `src/apps/desktop/src/App.vue:48`

## Out of scope (deferred to follow-ups)

- Mid-stream cancellation in `Agent.zig::callStreaming` (currently
  cancel only fires at iteration boundaries; `error.Cancelled` is
  declared but never returned from the chunk loop).
- Keyboard shortcut (`Esc` / `Cmd+.`).
- Confirmation modal.
- Cancelling queued messages.