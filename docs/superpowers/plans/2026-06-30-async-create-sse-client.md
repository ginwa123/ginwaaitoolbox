# Make `createSseClient` Async

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `src/apps/desktop/src/helpers/sseClient.ts`'s `createSseClient(opts)` return `Promise<SseClient>` instead of `SseClient`. Propagate the async signature through all 4 SSE factory functions in `src/apps/desktop/src/api/index.ts` and all 4 call sites in stores / Vue components. Update tests to `await` construction. This is a breaking API change but it's the cleanest fix for the remaining blocking symptom the user is observing in smoke testing — the caller now has an explicit `await` point that yields to the event loop between Vue rendering and the SSE HTTP request.

**Architecture:** Single-mechanical change across ~11 files. The constructor's body is unchanged (it still does sync setup + `setTimeout(start, 0)`); only the return type changes from `SseClient` to `Promise<SseClient>`. Async wrapping converts sync return into a microtask-resolved Promise — when the caller does `await createSseClient(...)`, control yields to the event loop, allowing Vue rendering and other in-flight promises to proceed before the caller continues. The actual SSE HTTP request remains deferred to the next macrotask via `setTimeout(start, 0)`.

**Tech Stack:** Vue 3 + TypeScript + Vitest (fake timers), `src/apps/desktop/src/helpers/sseClient.ts` + 4 factories in `api/index.ts` + 4 caller sites in stores/Vue components + 2 test files.

**Spec / context:**
- Kanban task: `fix-sse-blocking-api` (workspace `ws_1779002584293_e52cd134532e1f00`, item `item_1782442554104741821`).
- Backend fix shipped in PR #47 (commits 1-9): `SseManager.sendDeferred` + 5 SSE handlers use it → no worker-pool starvation.
- Frontend deferral enhancement shipped in PR #47 (commits 10-16): all `SseClient.start()` sites deferred via `setTimeout(start, 0)` → no EventSource-construction race.
- After both, user smoke-tested again and STILL observes blocking. Their hypothesis: `createSseClient` is synchronous and should be async so callers can `await` it as a microtask boundary.
- This is the user's third smoke test iteration. The async wrapping gives them an explicit coordination point — `await createSseClient(...)` yields control to the event loop, allowing other in-flight promises to interleave.

---

## Context

### Current state

`src/apps/desktop/src/helpers/sseClient.ts:386`:
```typescript
export function createSseClient(opts: SseClientOptions): SseClient {
  // sync setup (state, defaults, function defs, DOM listener registration)
  // ...
  setTimeout(start, 0)  // defers the EventSource creation
  return { close, reconnect, getState, onStateChange }
}
```

`src/apps/desktop/src/api/index.ts` has 4 SSE factory functions that wrap `createSseClient`:
- `createSseConnection` (line 767) — for `/api/llm/stream/:session_id`
- `createSessionsSseConnection` (line 1615) — for `/api/sessions/stream`
- `createWorkersSseConnection` (line 1813) — for `/api/workers/stream`
- `createKanbanSseConnection` (line 1920) — for `/api/kanban/events`

Each currently does `return createSseClient({...})` (sync).

### 4 call sites in stores / Vue components

| File | Line | Pattern |
|---|---|---|
| `src/apps/desktop/src/stores/kanbanSse.ts` | 70 | `connection = { sse: createKanbanSseConnection(...), ... }` |
| `src/apps/desktop/src/App.vue` | 52 | `workersSse = api.createWorkersSseConnection(...)` |
| `src/apps/desktop/src/stores/workspaces.ts` | 1492 | `sessionsSse.value = api.createSessionsSseConnection(...)` |
| `src/apps/desktop/src/components/ChatsList.vue` | 269 | `sessionsSse.value = api.createSessionsSseConnection(...)` |
| `src/apps/desktop/src/components/ChatView.vue` | 1576 | `eventSource.value = api.createSseConnection(...)` |

(That's 5 call sites; the plan above counts the store + Vue components separately. Either way, all need `await`.)

### Test files

- `src/apps/desktop/src/__tests__/sseClient.spec.ts` — uses `createSseClient` directly in ~30 tests. All need `await`.
- `src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts` — mocks `createSessionsSseConnection` via `vi.spyOn(api, 'createSessionsSseConnection').mockImplementation(...)`. The mock needs to return a Promise too.

### Out of scope

- Backend changes — none. The Zig `SseManager` is unchanged.
- `kanbanSseStore.initKanbanSse` — already `async` (returns `Promise<void>`); the new `await` is naturally supported.
- Renaming or restructuring the SseClient internal API — out of scope. Only the return type of `createSseClient` changes.

---

## File Structure

### Modified files

| File | Change |
|---|---|
| `src/apps/desktop/src/helpers/sseClient.ts` | Change `createSseClient` from sync to `async`; return `Promise<SseClient>` |
| `src/apps/desktop/src/api/index.ts` | Change 4 factory functions to `async`; return `Promise<SseClient>` |
| `src/apps/desktop/src/stores/kanbanSse.ts` | `await` the `createKanbanSseConnection` call |
| `src/apps/desktop/src/App.vue` | `await` the `createWorkersSseConnection` call |
| `src/apps/desktop/src/stores/workspaces.ts` | `await` the `createSessionsSseConnection` call |
| `src/apps/desktop/src/components/ChatsList.vue` | `await` the `createSessionsSseConnection` call |
| `src/apps/desktop/src/components/ChatView.vue` | `await` the `createSseConnection` call |
| `src/apps/desktop/src/__tests__/sseClient.spec.ts` | `await` all `createSseClient` calls in tests |
| `src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts` | Make the `createSessionsSseConnection` mock return a Promise |

### No new files

---

## Chunk 1: Make `createSseClient` async + propagate to factories

**Files:**
- Modify: `src/apps/desktop/src/helpers/sseClient.ts:386`
- Modify: `src/apps/desktop/src/api/index.ts` (4 factories: 767, 1615, 1813, 1920)

### Task 1.1: Make `createSseClient` async in `sseClient.ts`

**Files:**
- Modify: `src/apps/desktop/src/helpers/sseClient.ts:386` (signature + body)

- [ ] **Step 1: Read** the current `createSseClient` signature + body (lines 382-393) to confirm context. Also read lines 1-58 (the file header docstring) to update the affected bullet.

- [ ] **Step 2: Change the signature** at line 386 from:
```typescript
export function createSseClient(opts: SseClientOptions): SseClient {
```
to:
```typescript
export async function createSseClient(opts: SseClientOptions): Promise<SseClient> {
```

- [ ] **Step 3: Update the file header docstring** at lines 41-58 — change the bullet that currently reads:
```
 *   - `createSseClient(opts) → SseClient`
```
to:
```
 *   - `createSseClient(opts) → Promise<SseClient>` (async)
```

Also update the bullet text mentioning "The constructor is fully async — the initial `start()` is deferred" to clarify the new contract: the constructor returns a Promise that resolves with the SseClient on the next microtask; the SSE HTTP request itself is still deferred to the next macrotask via `setTimeout(start, 0)`. Callers should `await` the factory call.

- [ ] **Step 4: Verify build** (most callers will fail TS type-check at this point — expected, will be fixed in Chunk 2):

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: TypeScript errors in `api/index.ts`, `kanbanSse.ts`, etc. (they call `createSseClient` without `await`). These will be fixed in Chunk 2. **Do not block on this** — Task 1.1's purpose is to change the signature; cross-file fixes come in Chunk 2.

- [ ] **Step 5: Commit**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
git add src/apps/desktop/src/helpers/sseClient.ts
git commit -m "feat(sse-client): make createSseClient return Promise<SseClient>"
```

### Task 1.2: Make the 4 SSE factories in `api/index.ts` async

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts` — 4 functions: `createSseConnection` (line 767), `createSessionsSseConnection` (line 1615), `createWorkersSseConnection` (line 1813), `createKanbanSseConnection` (line 1920)

For each factory, change the signature from `export function X(...): SseClient` to `export async function X(...): Promise<SseClient>` and change the `return createSseClient({...})` to `return createSseClient({...})` (no change to the return statement — `await` is implicit when returning a Promise from an async function).

- [ ] **Step 1: Read** each of the 4 factory functions to confirm the exact signature line + return statement.

- [ ] **Step 2: For EACH of the 4 factories** (`createSseConnection`, `createSessionsSseConnection`, `createWorkersSseConnection`, `createKanbanSseConnection`):
   - Add `async` to the function declaration
   - Change the return type from `SseClient` to `Promise<SseClient>`
   - Leave the `return createSseClient({...})` line unchanged (it returns a Promise; an async function returning a Promise<T> flattens it automatically)

- [ ] **Step 3: Verify build**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: TypeScript errors in stores / Vue components (they call the factories without `await`). The 4 factories themselves should now type-check.

- [ ] **Step 4: Commit**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(api): make 4 SSE factory functions async (Promise<SseClient>)"
```

---

## Chunk 2: Update all 5 caller sites to `await`

**Files:**
- Modify: `src/apps/desktop/src/stores/kanbanSse.ts:70` — `await createKanbanSseConnection(...)`
- Modify: `src/apps/desktop/src/App.vue:52` — `await api.createWorkersSseConnection(...)`
- Modify: `src/apps/desktop/src/stores/workspaces.ts:1492` — `await api.createSessionsSseConnection(...)`
- Modify: `src/apps/desktop/src/components/ChatsList.vue:269` — `await api.createSessionsSseConnection(...)`
- Modify: `src/apps/desktop/src/components/ChatView.vue:1576` — `await api.createSseConnection(...)`

### Task 2.1: `kanbanSse.ts` — await the `createKanbanSseConnection` call

**Files:**
- Modify: `src/apps/desktop/src/stores/kanbanSse.ts:69-71`

- [ ] **Step 1: Read** lines 65-75 of `kanbanSse.ts` to confirm context.

- [ ] **Step 2: Add `await` before `createKanbanSseConnection(...)`** at line 70. The surrounding context:
```typescript
    connection = {
      sse: createKanbanSseConnection(
```
becomes:
```typescript
    connection = {
      sse: await createKanbanSseConnection(
```

- [ ] **Step 3: Verify build still passes**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 5
```

- [ ] **Step 4: Commit**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
git add src/apps/desktop/src/stores/kanbanSse.ts
git commit -m "refactor(kanbanSse): await createKanbanSseConnection"
```

### Task 2.2: `App.vue`, `workspaces.ts`, `ChatsList.vue`, `ChatView.vue` — await each factory call

- [ ] **Step 1: `App.vue:52`** — the surrounding context (likely inside an async setup / onMounted). Add `await api.createWorkersSseConnection(...)`. Confirm the calling function is already `async` (Vue `setup()` is async).

- [ ] **Step 2: `workspaces.ts:1492`** — the surrounding context. Likely inside an async function (workspacesStore's action). Add `await api.createSessionsSseConnection(...)`.

- [ ] **Step 3: `ChatsList.vue:269`** — the surrounding context. Likely inside `onMounted` or `onBeforeMount`. Add `await api.createSessionsSseConnection(...)`. If `onMounted`'s callback is not async, wrap it as `(async () => { ... })()` or use the `onMounted(async () => {...})` pattern (Vue supports async callbacks in lifecycle hooks).

- [ ] **Step 4: `ChatView.vue:1576`** — the surrounding context. Likely inside a watcher or `onMounted`. Add `await api.createSseConnection(...)`. Same async-callback wrapping as needed.

- [ ] **Step 5: Verify build passes**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
```

Expected: clean build (no TS errors).

- [ ] **Step 6: Run the full vitest suite** (some tests may fail until Chunk 3 fixes them):
```bash
timeout 180 bunx vitest run 2>&1 | tail -n 15
```

- [ ] **Step 7: Commit** (combine all 4 caller updates in one commit):
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
git add src/apps/desktop/src/App.vue \
        src/apps/desktop/src/stores/workspaces.ts \
        src/apps/desktop/src/components/ChatsList.vue \
        src/apps/desktop/src/components/ChatView.vue
git commit -m "refactor(sse): await factory calls in 4 callers (App.vue, workspaces.ts, ChatsList.vue, ChatView.vue)"
```

---

## Chunk 3: Update tests

**Files:**
- Modify: `src/apps/desktop/src/__tests__/sseClient.spec.ts` — all `createSseClient` calls
- Modify: `src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts` — mock returns Promise

### Task 3.1: `sseClient.spec.ts` — `await` all `createSseClient` calls

**Files:**
- Modify: `src/apps/desktop/src/__tests__/sseClient.spec.ts` (≈30 test sites)

The test file currently uses `const client = createSseClient({...})` (sync). After the signature change, this needs to be `const client = await createSseClient({...})`. The `vi.advanceTimersByTime(0)` flush pattern (added in the previous chunks) is unchanged — it still works because `vi.useFakeTimers()` controls the global `setTimeout`.

- [ ] **Step 1: Use a project-wide sed/replace** to convert `const client = createSseClient({...})` to `const client = await createSseClient({...})` across the file:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api/src/apps/desktop
# Dry run first:
sed -i 's/const client = createSseClient(/const client = await createSseClient(/g' src/__tests__/sseClient.spec.ts
# Verify the change took:
grep -n 'await createSseClient' src/__tests__/sseClient.spec.ts | head -n 5
grep -c 'createSseClient' src/__tests__/sseClient.spec.ts
```

- [ ] **Step 2: Verify the vitest suite** passes:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api/src/apps/desktop
timeout 180 bunx vitest run src/__tests__/sseClient.spec.ts 2>&1 | tail -n 15
```

Expected: 32/32 tests pass (same baseline as before; no semantic change beyond the await).

- [ ] **Step 3: Commit**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
git add src/apps/desktop/src/__tests__/sseClient.spec.ts
git commit -m "test(sse-client): await createSseClient() in all tests"
```

### Task 3.2: `workspacesStoreSessionEvents.spec.ts` — mock returns Promise

**Files:**
- Modify: `src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts:43`

The mock currently looks like:
```typescript
vi.spyOn(api, 'createSessionsSseConnection').mockImplementation(
  // ... returns sync SseClient
)
```

After the signature change, the mock must return a `Promise<SseClient>`. Wrap with `Promise.resolve(...)`:

```typescript
vi.spyOn(api, 'createSessionsSseConnection').mockImplementation(
  async (...args) => {
    // ... existing setup ...
    return Promise.resolve({ ...mockClientObject })
  }
)
```

(Exact shape depends on the existing mock — read first, then adapt.)

- [ ] **Step 1: Read** the existing mock at line 43 to confirm its structure.

- [ ] **Step 2: Wrap the mock's return value** in `Promise.resolve(...)` (or make the mock `async` and return the mock object directly — async functions return Promises automatically).

- [ ] **Step 3: Verify the test**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api/src/apps/desktop
timeout 60 bunx vitest run src/__tests__/workspacesStoreSessionEvents.spec.ts 2>&1 | tail -n 10
```

- [ ] **Step 4: Commit**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
git add src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts
git commit -m "test(workspaces): make createSessionsSseConnection mock async"
```

---

## Chunk 4: Final verification + push

### Task 4.1: Full verification

- [ ] **Step 1: `bun run build`** — must be clean:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
```

- [ ] **Step 2: `bunx vitest run`** — full suite must pass (note: there may be pre-existing KanbanView failures from parallel work — document but don't block on them):
```bash
timeout 180 bunx vitest run 2>&1 | tail -n 20
```

- [ ] **Step 3: Confirm the change is minimal**:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature-fix-sse-blocking-api
git diff main..HEAD --stat
```

Expected: only `src/apps/desktop/src/{helpers,api,stores,components,__tests__}/...` files — no backend changes.

### Task 4.2: Push + update PR #47

- [ ] **Step 1: Push**:
```bash
git push -u origin worktree/feature-fix-sse-blocking-api
```

- [ ] **Step 2: Post an addendum comment on PR #47** (using `gh pr comment 47 --body-file /tmp/comment.md`) summarizing the async wrapping.

---

## Verification (executor must run before marking complete)

Per the project memory `verification-before-completion` skill:

1. **`bun run build` must pass cleanly** — no TS errors.
2. **`bunx vitest run src/__tests__/sseClient.spec.ts` must pass** — 32/32 tests.
3. **No regression in other test files** — `bunx vitest run` full suite. Pre-existing KanbanView failures (from parallel work) are out of scope.
4. **No backend changes** — `git diff main..HEAD --stat` shows only frontend files.
5. **Smoke test the frontend** — `initKanbanSse` now `await`s `createKanbanSseConnection`. The `await createSseClient(...)` yields to the event loop, allowing Vue rendering to interleave.

---

## Pitfalls

1. **Don't change the constructor's internal logic** — only the return type changes. The body still does sync setup + `setTimeout(start, 0)`. The Promise resolves on the next microtask, the SSE HTTP request fires on the next macrotask.

2. **`return createSseClient({...})` from an async function flattens automatically** — no need to write `return await createSseClient({...})`. The async wrapper handles Promise flattening.

3. **Mock factories in tests need updating** — `vi.spyOn(api, 'createSessionsSseConnection').mockImplementation(...)` must now return a Promise. Wrap in `Promise.resolve(...)` or make the mock `async`.

4. **Vue lifecycle hooks accept async callbacks** — `onMounted(async () => {...})` works; if the surrounding context is sync (e.g., a non-async watcher), wrap as `(async () => { ... })()` or use `Promise.resolve().then(async () => {...})`.

5. **Don't remove the existing `setTimeout(start, 0)` deferral** — the async wrapping is an ADDITIONAL coordination point; the SSE HTTP request itself is still deferred to the next macrotask via setTimeout. Both layers of deferral are needed.

6. **`Promise<SseClient>` vs `SseClient | Promise<SseClient>`** — the function ALWAYS returns a Promise now. Don't use a union type; that defeats the purpose of "always async".

---

## Related

- PR #47 (open) — previous round of fixes (backend + frontend deferral). This addendum makes `createSseClient` async.
- `non-blocking-sse-init` skill — original pattern (constructor's `setTimeout(start, 0)`). The async wrapping is a STRONGER version of the same principle.
- `desktop-typescript-bun-build-as-typecheck.md` memory — `bun run build` is the authoritative type-check.
- `verification-before-completion` skill — always run `bun run build` + `bunx vitest run` before claiming done.