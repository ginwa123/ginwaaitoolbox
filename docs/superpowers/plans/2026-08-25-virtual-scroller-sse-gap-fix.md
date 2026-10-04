# VirtualScroller SSE Gap Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the large blank gap between the last message and the bottom of the chat when new data arrives via SSE — including the "new items on demand" (loadMore prepend) case the user reports.

**Architecture:** Two shipped fixes (PR #336, merged) addressed the *estimator* side of the gap (tail under-estimation + prepend height remap). But the *stick-to-bottom* side is still broken on `main`: `handleVirtualScroll` permanently disengages `isAtBottom` when content grows under a stationary viewport, and the re-stick uses the browser's implicit clamp which can land at a stale bottom. Both fixes already exist on the **OPEN** PR #333 branch (`worktree/chatview-scroll-past-sse`) — this plan lands them on main, plus adds a regression test for the loadMore-during-stream gap.

**Tech Stack:** Vue 3 `<script setup>`, Vitest (fake timers), Python functional UI harness (`tests/functional_ui/`), git worktree + PR workflow.

## Global Constraints

- **NEVER kill or bind port 8081** — the dev server lives there. Functional tests use the harness (free port 8080–8199).
- Do NOT refactor working scroll code. Surgical patches only — this file has been through 6 rounds of fixes (PRs #299, #308, #310, #321, #324, #336); every guard in it is load-bearing.
- The scroll pipeline is **synchronous** — do not add rAF-deferral layers on top of `scrollTop.value` writes or `findStartIndex` (proven to break PR #310's pre-paint contract; see memory `mem_0a28e93fa5038d64`).
- `overflow-anchor: none` is intentional (ratcheting fix) — do not re-enable browser scroll anchoring.
- Tail estimates must stay **conservative (under-estimate)** — never re-introduce median-based tail estimation.
- Any index-keyed cache (heights, positions) must be remapped on prepend — invariant from PR #336.
- Verification: `cd src/apps/desktop && bun run test:unit` (vitest) + `bun run build` (vue-tsc + vite) must pass; functional UI test via `python3 -m pytest tests/functional_ui/ -v`.
- Branch: new worktree off `origin/main` (post-#336). PR #333's branch is 7 commits behind main — **rebase/cherry-pick its 3 commits onto fresh main rather than merging the stale branch**.

## Root Cause Analysis (verified on origin/main @ 29b4a87b)

The user's screenshot shows a huge empty region between the last rendered message and the input box during/after SSE streaming. Two interacting bugs remain on main:

**Bug A — `isAtBottom` permanently disengages on content growth (the big one).**
`ChatView.vue` `handleVirtualScroll` (~L2140 on main):
```ts
const newIsAtBottom = distanceFromBottom < BOTTOM_THRESHOLD   // 10px
...
isAtBottom.value = newIsAtBottom
```
When an SSE chunk (or a loadMore measurement settle) grows `scrollHeight` while the viewport is stationary, `distanceFromBottom` jumps from ~0 to +N px in a single event with `deltaTop === 0`. The user never scrolled, but `newIsAtBottom` computes `false` → `isAtBottom` flips → every subsequent `onContentShift` re-stick hits the `if (!isAtBottom.value) return` guard (`spacer-resize-skip`) → the gap never closes and **grows with every subsequent chunk**. Log signature: `top=<same> bottom=<growing>` with `left-bottom` + `deltaTop=0`.

**Bug B — clamp-delegate timing in the re-stick.**
`onContentShift` (~L763 on main) does `container.scrollTop = container.scrollHeight`, relying on the browser's implicit clamp. If the sizer's `:style.height` binding hasn't flushed to the DOM yet when the rAF fires, the clamp lands at the OLD bottom — gap = (new max − old max) until the next event. Fix: explicit `Math.max(0, scrollHeight - clientHeight)` (the pattern `VirtualScroller.scrollToBottom` already uses).

**Bug C — loadMore-during-stream gap (user's "new items on demand" case).**
`beginPreserve`/`endPreserve` remap heights (PR #336) but `endPreserve` sets `scrollTop = anchorEl.offsetTop` — the anchor's position in the NEW layout. If the newly prepended items' heights are still estimates at that moment (measureItems runs inside endPreserve, but images/code blocks settle later), the restored scrollTop is wrong by the estimate error, and the sizer can extend past real content until the next measure pass. Additionally `suppressContentShiftStick` is only re-armed after `endPreserve` resolves — a contentShift emitted between `messages.value = [...]` and the re-arm is dropped entirely, so the bottom is never re-validated after a prepend that happened while `isAtBottom` was true.

**Why PR #336 didn't fully fix it:** #336 fixed the *estimator* (tail items now under-estimate → sizer tight). But Bug A means the re-stick that would absorb the remaining estimate error gets disabled after the first content growth event. The two fixes are complementary — both sides must be on main.

## File Structure

| File | Change |
|---|---|
| `src/apps/desktop/src/components/views/ChatView.vue` | Bug A: deltaTop-aware isAtBottom. Bug B: explicit bottom compute in onContentShift. Bug C: re-validate bottom after endPreserve when was-at-bottom. |
| `src/apps/desktop/src/components/views/Chats.vue` | Bug B pattern (clamp-delegate) — same 1-line fix. |
| `src/apps/desktop/src/components/pabrik/SubAgentPeekPanel.vue` | Bug B pattern — same 1-line fix. |
| `src/apps/desktop/src/__tests__/chatViewContentShiftRestick.spec.ts` | NEW — 5 unit tests for A+B. |
| `tests/functional_ui/chatview_sse_stick_ui_test.py` | NEW — functional UI reproduction incl. loadMore-during-stream. |

## Implementation Tasks

### Task 1 — Fresh branch + cherry-pick PR #333 commits

1. `git fetch origin main`
2. `git worktree add .worktrees/virtual-scroller-sse-gap-fix -b worktree/virtual-scroller-sse-gap-fix origin/main`
3. Cherry-pick the 3 commits from PR #333 (`0bb2fb94`, `bad8b60c`, `fc89f75c`), resolving conflicts against post-#336 main (expect small conflicts in ChatView.vue around the contentShift handler — #336 touched nearby lines).
4. Verify the cherry-picked diff still applies semantically: `git diff origin/main...HEAD --stat` should show ChatView.vue, Chats.vue, SubAgentPeekPanel.vue + 2 test files.
5. Commit (cherry-picks carry their own messages).

### Task 2 — Bug A: keep auto-stick engaged under content growth (TDD)

1. **Write failing test** in `chatViewContentShiftRestick.spec.ts`: simulate scroll event with `deltaTop === 0` and `scrollHeight` grown past `BOTTOM_THRESHOLD` → assert `isAtBottom` stays `true` (expose via scroll logger context or component state). Run → must FAIL on current code.
2. **Implement** in `handleVirtualScroll`: only a real upward scroll disengages the stick —
   ```ts
   const scrolledUp = deltaTop < 0
   isAtBottom.value = newIsAtBottom || (previousIsAtBottom && !scrolledUp && contentGrew)
   ```
   (exact shape per the cherry-picked commit `bad8b60c`; keep the `left-bottom`/`reached-bottom` logging intact, add a `reason: 'content-grew-under-stationary-viewport'` info log when the stick is retained).
3. Run the new spec → PASS. Run full vitest suite → no regressions (especially `virtualScrollerScrollEmit.spec`, `chatViewContentShiftRestick.spec`).
4. Commit: `fix(chatview): keep auto-stick engaged when content grows under a stationary viewport`.

### Task 3 — Bug B: explicit bottom computation in re-stick

1. **Write failing test**: mock container where `scrollHeight` binding lags one frame; assert the re-stick assigns `scrollTop = max(0, scrollHeight - clientHeight)` explicitly, not via clamp-delegate. Run → FAIL.
2. **Implement** in `onContentShift` (and the same pattern in `Chats.vue` + `SubAgentPeekPanel.vue` per commit `0bb2fb94`):
   ```ts
   container.scrollTop = Math.max(0, container.scrollHeight - container.clientHeight)
   ```
3. Run specs → PASS; full suite green.
4. Commit: `fix(chatview): explicit bottom computation in re-stick — no browser-clamp delegate`.

### Task 4 — Bug C: re-validate bottom after loadMore prepend

1. **Write failing test** (unit): with `isAtBottom === true`, run the loadChatHistory loadMore path (mock api.getChatHistory) → assert a bottom re-validation happens after `endPreserve` resolves (scrollLogger shows a `post-preserve-stick` line / scrollTop lands at new bottom).
2. **Implement** in `loadChatHistory` loadMore branch, after `suppressContentShiftStick = false`:
   ```ts
   if (wasAtBottom) {
     scrollLogger.markProgrammatic()
     lastAutoStickAt.value = Date.now()
     const c = virtualScrollerRef.value?.containerRef
     if (c) c.scrollTop = Math.max(0, c.scrollHeight - c.clientHeight)
   }
   ```
   Capture `wasAtBottom = isAtBottom.value` BEFORE `beginPreserve` (the preserve dance fires scroll events that would corrupt the flag). This closes the dropped-contentShift window.
3. Run specs → PASS; full suite green.
4. Commit: `fix(chatview): re-validate bottom after loadMore prepend when user was at bottom`.

### Task 5 — Functional UI test (wire-level reproduction)

1. Extend `tests/functional_ui/chatview_sse_stick_ui_test.py` (from cherry-pick `fc89f75c`) with a loadMore-during-stream scenario: seed >PAGE_SIZE messages, scroll to top to trigger loadMore mid-stream, then stream SSE chunks → assert no gap (distanceFromBottom < threshold at stream end) and no blank viewport.
2. Run: `PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional_ui/chatview_sse_stick_ui_test.py -v` (harness picks a free port ≠ 8081).
3. Commit: `test: functional UI test for SSE + loadMore gap reproduction`.

### Task 6 — Full verification + PR

1. `cd src/apps/desktop && bun run test:unit` — full suite green (baseline ~2621 pass).
2. `bun run build` — vue-tsc + vite clean. Delete any emitted `.js` siblings of `.ts` sources before committing (vue-tsc build emits them; see local skill).
3. `zig build test --summary all` — backend untouched but confirm no accidental breakage.
4. Push branch, `gh pr create` with root-cause analysis (Bugs A/B/C) + before/after log signatures.
5. Move kanban task to `in_review_task`.

## Pitfalls

- **Do not "simplify" the guard chain in `handleVirtualScroll`** — the logging branches are diagnostic infrastructure the user relies on (scrollLogger).
- **jsdom has no real layout** — offsetHeight must be mocked; use the `mockChildHeights` helper pattern from `virtualScrollerScrollAnchor.spec.ts`. Mock only the items whose height matters (see memory: mocking ALL children tall inflates compensation math).
- **Fake timers**: `endPreserve` awaits rAF internally — tests need `advanceTimersByTimeAsync` to drain it.
- **Vue keyed v-for reuses DOM nodes** across prepends — height mocks travel with nodes; a post-prepend measure pass legitimately stores old heights at new indices.
- **PR #333's branch is stale** (7 behind main, mergeStateStatus UNKNOWN) — cherry-pick onto fresh main; do not merge the old branch.
- **Two `.virtual-scroller` elements exist on the chatview page** (main chat + peek panel) — scope test queries.

## Verification

- [ ] New specs fail before fix, pass after (TDD evidence in task notes)
- [ ] Full vitest suite green; vue-tsc + vite build clean
- [ ] Functional UI test reproduces the gap on main (red) and passes with fix (green)
- [ ] Manual check: stream a long SSE response, confirm no gap below last message; scroll-to-top mid-stream triggers loadMore without gap on return
- [ ] PR open with analysis; kanban task in `in_review_task`
