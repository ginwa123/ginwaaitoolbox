# Defer All SSE `start()` Calls

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance `src/apps/desktop/src/helpers/sseClient.ts` so ALL `start()` calls (constructor initial, retry timer, reconnect, visibility change, online event) are deferred via `setTimeout(start, 0)`. Today only the constructor's initial `start()` is deferred — the 3 other sites call `start()` synchronously, which fires `new EventSource(url)` in the same tick as the trigger (e.g., a user-driven `.reconnect()`, a tab becoming visible, an `online` event firing). On a busy page, this can saturate the browser's HTTP/1.1 per-origin 6-connection pool and re-introduce the "blocking" symptom the constructor's deferral was designed to fix.

**Architecture:** Three surgical one-line changes that wrap each synchronous `start()` call in `setTimeout(start, 0)`. Update the 3 existing `client.reconnect()` tests to flush the deferred start (mirroring the constructor's `vi.advanceTimersByTime(0)` pattern). Add 2 new tests that explicitly verify the deferral contract (the new EventSource is NOT created until the macrotask fires).

**Tech Stack:** Vue 3 + TypeScript + Vitest, fake timers (`vi.useFakeTimers`), the existing `sseClient.ts` (31 KB / 793 lines) and `sseClient.spec.ts` (1414 lines / 31 tests).

**Spec / context:**
- Kanban task: `fix-sse-blocking-api` (workspace `ws_1779002584293_e52cd134532e1f00`, item `item_1782442554104741821`).
- Backend fix shipped in PR #47 — handlers no longer block the Io worker pool on `socket.write`.
- After backend fix, user smoke-tested and reports the frontend still has blocking symptoms. Investigation: `sseClient.ts` has 3 sites that call `start()` SYNCHRONOUSLY:
  - `reconnect()` at line 779 (user-driven retry)
  - `onVisibilityChange()` at line 659 (tab becomes visible while reconnecting)
  - `onOnline()` at line 670 (browser fires `online` while reconnecting)
- The constructor's initial `start()` IS already deferred (`setTimeout(start, 0)` at line 724, landed in commit `318d2d0d`).
- The retry timer's `start()` call at line 639 IS already deferred (inside `setTimeout(() => { start(); }, delay)`).

---

## Context

### Current state (3 sites that need deferral)

`sseClient.ts:647-661` — `onVisibilityChange()`:
```typescript
function onVisibilityChange(): void {
  if (closed) return
  if (!visibilityTarget) return
  if (visibilityTarget.hidden) return
  if (state === 'reconnecting') {
    clearRetry()
    emitState('reconnecting', { attempt, reason: 'visible' })
    start()  // ← synchronous; fires new EventSource immediately
  }
}
```

`sseClient.ts:663-672` — `onOnline()`:
```typescript
function onOnline(): void {
  if (closed) return
  if (state === 'reconnecting') {
    clearRetry()
    emitState('reconnecting', { attempt, reason: 'online' })
    start()  // ← synchronous
  }
}
```

`sseClient.ts:766-780` — `reconnect()`:
```typescript
reconnect(): void {
  if (closed) return
  if (es) {
    try { es.close() } catch { /* ignore */ }
    es = null
  }
  clearRetry()
  attempt = 0
  hasBeenOpen = false
  start()  // ← synchronous; user-driven reconnect
},
```

### What's already in place

- `sseClient.ts:706-724` — constructor's initial `start()` IS already deferred via `setTimeout(start, 0)`. The comment block above the call explains the WHY (HTTP/1.1 connection pool saturation, 6 max per origin).
- `sseClient.ts:637-640` — retry timer's `start()` IS already deferred inside `setTimeout(() => { start(); }, delay)`.
- `sseClient.spec.ts` — 31 existing tests already use the `vi.advanceTimersByTime(0)` flush pattern after `createSseClient(...)` to drain the constructor's deferred start. The new test updates mirror this pattern.

### Out of scope

- Backend handler changes — already shipped in PR #47 (Kanban SSE handler now uses `sendDeferred` for the connected-event handshake; the worker pool is freed immediately).
- Frontend `kanbanSseStore` — no changes needed; `initKanbanSse` is already async + non-blocking (the `setTimeout(start, 0)` in the constructor handles the SSE HTTP request deferral; the `onConnected` callback's `fetchInitialKanban` is an async fetch that doesn't block).
- Renaming `start()` to `startAsync()` or similar — not requested, would be a needless rename.
- The 4-site `sendToClient(...)` synchronous call in `kanban_events_sse.zig`'s event-forwarding callback (`forwardToClients`) — that runs in response to backend kanban events, not on the SSE setup path. Out of scope.

---

## File Structure

### Modified files

| File | Change |
|---|---|
| `src/apps/desktop/src/helpers/sseClient.ts` | Wrap the 3 synchronous `start()` calls (lines 659, 670, 779) in `setTimeout(start, 0)`. Update the file header docstring (lines 41-50) to reflect that ALL `start()` calls are now deferred, not just the initial one. |
| `src/apps/desktop/src/__tests__/sseClient.spec.ts` | Add `vi.advanceTimersByTime(0)` after the 3 `client.reconnect()` calls (lines 433, 1306, 1373) to flush the new deferred start. Add 2 new tests asserting the deferral contract for `reconnect()` and for the constructor's initial `start()`. |

### No new files

The fix is in the existing `sseClient.ts` + tests. No new modules needed.

---

## Chunk 1: Defer the 3 `start()` calls

**Files:**
- Modify: `src/apps/desktop/src/helpers/sseClient.ts` (3 surgical edits + 1 docstring update)

### Task 1.1: Defer `start()` in `onVisibilityChange`

**Files:**
- Modify: `src/apps/desktop/src/helpers/sseClient.ts:659`

- [ ] **Step 1: Read the current `onVisibilityChange` body** (lines 647-661) to confirm exact text before editing.

- [ ] **Step 2: Replace the synchronous `start()` call at line 659** with the deferred version:

OLD:
```typescript
      emitState('reconnecting', { attempt, reason: 'visible' })
      start()
```

NEW:
```typescript
      emitState('reconnecting', { attempt, reason: 'visible' })
      // Deferred to the next macrotask so the tab-becoming-visible
      // path doesn't fire `new EventSource(url)` synchronously —
      // see the constructor's deferral comment for the full
      // rationale (HTTP/1.1 6-connection pool saturation).
      setTimeout(start, 0)
```

- [ ] **Step 3: Verify build** (no test changes yet — the test suite doesn't cover `onVisibilityChange` triggering a `start()`):

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
timeout 60 bunx tsc --noEmit -p tsconfig.json 2>&1 | tail -n 5 || \
  timeout 60 bun run build 2>&1 | tail -n 15
```

Expected: clean (no TS errors). Note: this project's build uses `bun run build` (per memory `desktop-typescript-bun-build-as-typecheck.md`); fall back to `bunx tsc --noEmit` if `bun run build` doesn't exist.

- [ ] **Step 4: Commit** with:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
git add src/apps/desktop/src/helpers/sseClient.ts
git commit -m "feat(sse-client): defer start() in onVisibilityChange"
```

### Task 1.2: Defer `start()` in `onOnline`

**Files:**
- Modify: `src/apps/desktop/src/helpers/sseClient.ts:670`

- [ ] **Step 1: Apply the same deferral pattern** as Task 1.1. Replace:

```typescript
      emitState('reconnecting', { attempt, reason: 'online' })
      start()
```

with:

```typescript
      emitState('reconnecting', { attempt, reason: 'online' })
      // Deferred so the online-event fast-path doesn't fire
      // `new EventSource(url)` synchronously — see constructor
      // comment for the HTTP/1.1 connection-pool rationale.
      setTimeout(start, 0)
```

- [ ] **Step 2: Verify build** (same as Task 1.1).

- [ ] **Step 3: Commit**:
```bash
git add src/apps/desktop/src/helpers/sseClient.ts
git commit -m "feat(sse-client): defer start() in onOnline"
```

### Task 1.3: Defer `start()` in `reconnect()`

**Files:**
- Modify: `src/apps/desktop/src/helpers/sseClient.ts:779`

- [ ] **Step 1: Apply the same deferral pattern.** Replace:

```typescript
      clearRetry()
      attempt = 0
      hasBeenOpen = false
      start()
```

with:

```typescript
      clearRetry()
      attempt = 0
      hasBeenOpen = false
      // Deferred so user-driven reconnects (e.g., a "Retry" button
      // click) don't fire `new EventSource(url)` synchronously —
      // see constructor comment for the HTTP/1.1 connection-pool
      // rationale.
      setTimeout(start, 0)
```

- [ ] **Step 2: Verify** (build + existing test count still passes — existing `client.reconnect()` tests at lines 433, 1306, 1373 will need `vi.advanceTimersByTime(0)` flush, but we don't update those until Task 2.1; for now, confirm the build compiles cleanly):

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
timeout 60 bun run build 2>&1 | tail -n 5
timeout 120 bunx vitest run src/apps/desktop/src/__tests__/sseClient.spec.ts 2>&1 | tail -n 15
```

Expected: `bun run build` clean. The vitest run will likely show 3 test failures (the reconnect tests now need `vi.advanceTimersByTime(0)`). That's expected — Task 2.1 will fix them.

- [ ] **Step 3: Commit**:
```bash
git add src/apps/desktop/src/helpers/sseClient.ts
git commit -m "feat(sse-client): defer start() in reconnect()"
```

### Task 1.4: Update the file header docstring

**Files:**
- Modify: `src/apps/desktop/src/helpers/sseClient.ts:41-50` (the `createSseClient` docstring's bullet about deferred start)

- [ ] **Step 1: Read lines 41-50** to confirm the current text.

- [ ] **Step 2: Update the bullet** that currently says "the initial `start()` is deferred to the next macrotask" to clarify that ALL `start()` calls (initial, retry, reconnect, visibilitychange, online) are deferred. The current bullet is:

```typescript
 *   - `createSseClient(opts) → SseClient`
 *       Owns one `EventSource`, one retry timer, and the
 *       `visibilitychange` / `online` listeners. All cleaned up in
 *       `.close()`. **The constructor is fully async** — the
 *       initial `start()` is deferred to the next macrotask
 *       (`setTimeout(start, 0)`) so the HTTP request does not
 *       fire synchronously inside the caller. Tests that interact
 *       with `instances[0]` immediately after construction must
 *       call `vi.advanceTimersByTime(0)` to flush the deferred
 *       start.
```

Replace with:

```typescript
 *   - `createSseClient(opts) → SseClient`
 *       Owns one `EventSource`, one retry timer, and the
 *       `visibilitychange` / `online` listeners. All cleaned up in
 *       `.close()`. **All `start()` calls are deferred** to the
 *       next macrotask (`setTimeout(start, 0)`) — the initial
 *       start in the constructor, plus the 3 fast-path starts
 *       inside `.reconnect()`, `onVisibilityChange()`, and
 *       `onOnline()`. This makes the SSE setup "fully async" —
 *       the HTTP request never fires synchronously inside the
 *       caller, freeing the JS event loop for other fetch API
 *       calls. Tests that interact with `instances[0]`
 *       immediately after construction OR after `.reconnect()`
 *       must call `vi.advanceTimersByTime(0)` to flush the
 *       deferred start.
```

- [ ] **Step 3: Verify + commit**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
timeout 60 bun run build 2>&1 | tail -n 5
git add src/apps/desktop/src/helpers/sseClient.ts
git commit -m "docs(sse-client): clarify all start() calls are deferred"
```

---

## Chunk 2: Update existing tests + add new deferral tests

**Files:**
- Modify: `src/apps/desktop/src/__tests__/sseClient.spec.ts`

### Task 2.1: Add `vi.advanceTimersByTime(0)` after the 3 `client.reconnect()` calls

**Files:**
- Modify: `src/apps/desktop/src/__tests__/sseClient.spec.ts` (lines 433, 1306, 1373)

- [ ] **Step 1: Read the 3 reconnect test sites** (around lines 433, 1306, 1373) to confirm context.

- [ ] **Step 2: Update line 433 test** ("open cancels retry" case). Add `vi.advanceTimersByTime(0)` right after `client.reconnect()`:

OLD:
```typescript
    client.reconnect()
    // reconnect() closes the dead ES, so emit 'open' on the
    // freshly-created third instance.
    expect(instances.length).toBe(3)
```

NEW:
```typescript
    client.reconnect()
    // Flush the deferred start() — .reconnect() schedules
    // `new EventSource(url)` on the next macrotask so the
    // HTTP request doesn't compete with same-tick fetches
    // (see helpers/sseClient.ts constructor comment).
    vi.advanceTimersByTime(0)
    // reconnect() closes the dead ES, so emit 'open' on the
    // freshly-created third instance.
    expect(instances.length).toBe(3)
```

- [ ] **Step 3: Update line 1306 test** (manual reconnect case). Add the same flush:

OLD:
```typescript
    client.reconnect()
    expect(instances.length).toBe(4)
```

NEW:
```typescript
    client.reconnect()
    // Flush the deferred start() — see helpers/sseClient.ts
    // constructor comment for the rationale.
    vi.advanceTimersByTime(0)
    expect(instances.length).toBe(4)
```

- [ ] **Step 4: Update line 1373 test** (subscriber unsubscribed before reconnect case). Add the same flush BEFORE the `expect(cb).not.toHaveBeenCalled()`:

OLD:
```typescript
    unsub()
    client.reconnect()
    // After unsub, the new attempt's 'connecting' should not be
    // observed.
    expect(cb).not.toHaveBeenCalled()
```

NEW:
```typescript
    unsub()
    client.reconnect()
    // Flush the deferred start() — see helpers/sseClient.ts
    // constructor comment for the rationale.
    vi.advanceTimersByTime(0)
    // After unsub, the new attempt's 'connecting' should not be
    // observed.
    expect(cb).not.toHaveBeenCalled()
```

- [ ] **Step 5: Verify all 3 tests pass**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
timeout 120 bunx vitest run src/apps/desktop/src/__tests__/sseClient.spec.ts 2>&1 | tail -n 10
```

Expected: 31/31 tests pass (same baseline; the 3 reconnect tests now flush the deferred start).

- [ ] **Step 6: Commit**:
```bash
git add src/apps/desktop/src/__tests__/sseClient.spec.ts
git commit -m "test(sse-client): flush deferred start() after client.reconnect()"
```

### Task 2.2: Add new tests asserting the deferral contract

**Files:**
- Modify: `src/apps/desktop/src/__tests__/sseClient.spec.ts` (append 2 new tests at the end)

- [ ] **Step 1: Read the existing test patterns** (especially the `it('flushed the deferred start...')` comment pattern at lines 270-273, 342-345, etc.) to match style.

- [ ] **Step 2: Append the 2 new tests at the end of the `describe` block**:

```typescript
  // All start() calls are deferred to the next macrotask so the
  // SSE HTTP request never fires synchronously inside the caller.
  // These two tests guard against anyone reverting the deferral
  // on the constructor OR on .reconnect() — both would let the
  // EventSource construction race with same-tick fetch API calls
  // and saturate the browser's HTTP/1.1 6-connection pool.
  it('defers the initial start() — new EventSource is NOT created synchronously', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Before vi.advanceTimersByTime(0): no EventSource constructed yet.
    // The mock factory is called by `new EventSourceCtor(opts.url)`
    // inside start(). If start() runs synchronously in the constructor,
    // this would be 1; with the deferral, it's 0.
    expect(instances.length).toBe(0)

    // Flush the deferred start.
    vi.advanceTimersByTime(0)
    expect(instances.length).toBe(1)

    client.close()
  })

  it('defers start() inside .reconnect() — new EventSource is NOT created synchronously', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })
    vi.advanceTimersByTime(0)  // flush the initial start()
    expect(instances.length).toBe(1)

    // Trigger a reconnect. Without the deferral, .reconnect() would
    // synchronously create the new EventSource (instances.length
    // would jump from 1 to 2 immediately). With the deferral, it
    // stays at 1 until the next macrotask fires.
    client.reconnect()
    expect(instances.length).toBe(1)

    // Flush the deferred start.
    vi.advanceTimersByTime(0)
    expect(instances.length).toBe(2)

    client.close()
  })
```

- [ ] **Step 3: Verify the new tests pass**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
timeout 120 bunx vitest run src/apps/desktop/src/__tests__/sseClient.spec.ts 2>&1 | tail -n 10
```

Expected: 33/33 tests pass (31 baseline + 2 new). The 2 new tests are red-green documented: if someone reverts the deferral in the constructor, the first new test fails with `expected 0 to be 1`; if they revert the deferral in `.reconnect()`, the second new test fails with `expected 1 to be 2`.

- [ ] **Step 4: Commit**:
```bash
git add src/apps/desktop/src/__tests__/sseClient.spec.ts
git commit -m "test(sse-client): guard against reverting the start() deferral"
```

---

## Chunk 3: Final verification

**Files:** none modified (verification only)

### Task 3.1: Run full verification

- [ ] **Step 1: Run the full TypeScript build** (the project's authoritative type-check per memory `desktop-typescript-bun-build-as-typecheck.md`):
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
timeout 120 bun run build 2>&1 | tail -n 10
```

Expected: clean build, no TypeScript errors.

- [ ] **Step 2: Run the full Vitest suite** for the desktop app:
```bash
timeout 180 bunx vitest run 2>&1 | tail -n 10
```

Expected: 33/33 (or higher) tests pass for `sseClient.spec.ts`; the rest of the desktop test suite unchanged.

- [ ] **Step 3: Confirm git history** is clean:
```bash
git log --oneline main..HEAD
```

Expected: 6 new commits stacked on `main`:
1. `docs: ...` (the existing plan commit)
2. `feat(sse-client): defer start() in onVisibilityChange`
3. `feat(sse-client): defer start() in onOnline`
4. `feat(sse-client): defer start() in reconnect()`
5. `docs(sse-client): clarify all start() calls are deferred`
6. `test(sse-client): flush deferred start() after client.reconnect()`
7. `test(sse-client): guard against reverting the start() deferral`

(7 total counting the pre-existing plan commit; the previous PR #47 already merged into `main` is a separate chain.)

---

## Verification (executor must run before marking complete)

Per the project memory `verification-before-completion` skill:

1. **`bun run build` must pass cleanly** (TypeScript type-check).
2. **`bunx vitest run` must pass** — `33/33` tests in `sseClient.spec.ts` (31 baseline + 2 new deferral guards).
3. **Red-green verification on the 2 new tests** — confirm each fails with the expected error when the deferral is reverted:
   ```bash
   # For the constructor-defer test:
   git stash push -- src/apps/desktop/src/helpers/sseClient.ts
   # Edit sseClient.ts to remove the setTimeout(start, 0) at line 724
   # (or comment it out). Then:
   timeout 120 bunx vitest run src/apps/desktop/src/__tests__/sseClient.spec.ts 2>&1 | rg -i 'defers the initial'
   # Expect: 1 failure on the deferral test
   git stash pop
   # Restore the deferral.
   ```
4. **No incidental changes** — `git diff main..HEAD --stat` should show only `src/apps/desktop/src/helpers/sseClient.ts` and `src/apps/desktop/src/__tests__/sseClient.spec.ts`.

---

## Pitfalls

1. **Don't use `queueMicrotask` instead of `setTimeout`** — microtasks are NOT controlled by `vi.useFakeTimers()`. Tests using `vi.advanceTimersByTime(0)` to flush `setTimeout(0)` would silently leave microtasks unflushed. Stick with `setTimeout(0)` for testability. (This is already documented in the existing skill `non-blocking-sse-init`; preserving the choice keeps the test pattern consistent.)

2. **The retry timer at line 637-640 ALREADY defers via `setTimeout`** — DO NOT add a second `setTimeout(start, 0)` inside it. The retry timer's `start()` is already on the next macrotask.

3. **`pagehide` / `beforeunload` listeners at line 683 call `teardown()` synchronously** — these MUST stay synchronous. The browser will not await a Promise during unload, and a half-closed EventSource leaks the connection in the network panel. Don't defer teardown.

4. **The constructor's `setTimeout(start, 0)` at line 724 stays as-is** — DO NOT remove or change this line. The new tests in Task 2.2 verify it.

5. **`vi.advanceTimersByTime(0)` after `client.reconnect()` must happen BEFORE the `expect(instances.length)` assertion** — otherwise the test sees the pre-deferral count (1) instead of the post-deferral count (2). The pattern is: trigger → flush → assert.

6. **`sseChunked_test.zig` (backend) is unrelated** — this plan is frontend-only. Don't touch the backend `sse_manager.zig` or any of the 5 SSE handlers; those shipped in PR #47.

7. **Don't rename `start()` to `startAsync()`** — out of scope. The internal name is fine; what matters is the timing, not the name.

---

## Related

- `non-blocking-sse-init` skill — the original frontend deferral pattern (constructor's `setTimeout(start, 0)`). This plan extends the pattern to ALL `start()` call sites.
- `desktop-typescript-bun-build-as-typecheck.md` memory — `bun run build` is the authoritative type-check; `bunx vitest run` is the test runner.
- `verification-before-completion` skill — always run BOTH `bun run build` AND `bunx vitest run` before claiming done.
- PR #47 (shipped) — the backend fix (`SseManager.sendDeferred`). Combined with this plan, the SSE pipeline is non-blocking on BOTH sides (no worker-pool starvation backend; no EventSource-construction race frontend).