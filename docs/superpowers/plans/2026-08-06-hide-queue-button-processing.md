# Hide Send/Queue button while LLM is processing (2026-08-06)

## Symptom (user report, task_1785772775411)

User: *"remove button queue when in processing"*.

The chatview input area was showing BOTH a Stop button AND a Queue/Send button when the agent ran. The Queue button (orange, label "Queue", spinner) was visual noise — users cannot actually queue more work while the agent runs, so the button was misleading.

User screenshot: chatview bottom bar shows `[Stop] [Queue]` side-by-side. User wants only the Stop button visible during processing.

## Mental model

When `isLLMProcessing === true`, the user sees ONLY the Stop button. When `isLLMProcessing === false`, the user sees the normal Send button (label "Send", violet gradient). The brief network-in-flight moment (local `isLoading=true` BEFORE the SSE `worker created` event lands in `processingState`) **still** shows the button with its "Queue" label + spinner — so users can see the in-flight submit state. As soon as the agent is actually running, the button disappears.

## What landed

Surgical frontend-only fix in `src/apps/desktop/src/components/file/FileInput.vue`:

1. Add `v-if="!isLLMProcessing"` to the submit button.
2. Simplify the inner ternaries from `isLoading || isLLMProcessing` to just `isLoading` (the `|| isLLMProcessing` branches are now unreachable since the button is hidden when processing).
3. Add `data-testid="send-message-button"` for testability.
4. Update the comment block above the Stop/Send buttons to explain the new behaviour.

## Tests (6 behavioural)

New file `src/apps/desktop/src/__tests__/FileInput.hideQueueButton.spec.ts`:

| Test | Assertion |
|---|---|
| A | Send shown when `isLLMProcessing=false` (default); label is "Send" |
| B | Send hidden when `isLLMProcessing=true` |
| C | Flips false→true → button disappears |
| D | Flips true→false → button reappears as "Send" |
| E | `isLoading=true` with `isLLMProcessing=false` → button still shows with "Queue" label |
| F | Both `isLoading=true` AND `isLLMProcessing=true` → button is hidden (`isLLMProcessing` wins) |

Tests E and F lock in the subtle distinction: only the actual agent-processing state hides the button, not the brief network-in-flight moment.

## Why NOT remove the Queue label entirely

Test E shows the case: between "user pressed Send" and the SSE event landing, the user wants feedback that the submit is in flight. Removing the Queue label would erase that feedback. The fix is purely about hiding the button during the actual agent run.

## Verification

- `bun run build` clean (vue-tsc passes, 3.65 s).
- `bunx vitest run src/__tests__/FileInput.hideQueueButton.spec.ts` — 6/6 pass.
- `bunx vitest run src/__tests__/FileInput.stopButton.spec.ts` — 8/8 pass.
- `bunx vitest run src/__tests__/FileInput.spec.ts` — 12/12 pass.
- `bunx vitest run src/__tests__/ChatView.stopSession.spec.ts` — 5/5 pass.
- `bunx vitest run` (full suite) — 2039 pass / 19 fail. The 19 are PRE-EXISTING baseline (`AppLayout.urlPersist` ×7 + `DesignView.undoHidden` ×5 + `DesignElement` static contract ×1 + `DesignView.nudge` ×1 + `AppLayout.translateResize` ×1 + `AppLayout.memoriesGate` ×4). None touched by this change.

## Files

- `src/apps/desktop/src/components/file/FileInput.vue` — 5-line code change + 10-line comment update.
- `src/apps/desktop/src/__tests__/FileInput.hideQueueButton.spec.ts` (new) — 6 behavioural tests.
- `AGENTS.md` — changelog entry.

## Out of scope

- Refactor to extract a `<SubmitButton>` and `<StopButton>` component pair. Future work.
- Showing a different action affordance during processing (e.g. "Skip" or "Pause"). Future work.
- Animating the Send button fading out when processing starts. Future work.

## Branch / commit

`worktree/hide-queue-button-processing` @ `d8b91ca5`.