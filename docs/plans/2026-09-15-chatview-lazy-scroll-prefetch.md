# Plan: prefetch older chat history *before* the scroll reaches the top

## Goal
Make scrolling back through a long chat feel instant: when the user flings toward the top of the loaded history, the **next older page is already in memory**, so crossing the top edge prepends rows with no spinner, no stall, and no scroll jump.

One-sentence problem statement (user's words): *"the auto fetch is loaded after the user hit the max — what if the auto fetch is done before the scroll reaches the top?"*

**Definition of done (user requirement):** the feature is not complete until the real-browser functional UI test in §D passes on the implementation branch **and** demonstrably fails on `main` (pre-fix control run), with both sets of numbers pasted into the PR. A plan step that cannot be observed over the wire is not done.

**Non-goals (v1):** no page-size change, no backend/API change, no change to `VirtualScroller.vue`'s shared load-more timing (KanbanColumn/ChatsList depend on it), no velocity-based trigger (Phase 2, §"Phase 2"), no virtualized-height re-architecture, no streaming/SSE behavior change, no search/jump-to-message work.

## Decision log
- 2026-09-15 (user, answering this plan's three open questions): **"use your recommendation"** — implemented as (1) keep the manual button for non-scrollable containers, (2) **no** prefetch-on-open, (3) arm radius `max(800 px, 1.5 × viewport)`. See "Implementation outcome" for what the browser measurement changed in (2).
- 2026-09-15 (this plan): the early-fire radius already exists (`loadMoreThresholdRatio` = half a screen) and is **not** the problem — the trigger's *timing* is. Fix the timing with an **arm → commit → refill** prefetch **owned by `ChatView`**, not by raising the threshold and not by editing the shared `VirtualScroller`.
- 2026-09-15: v1 is **distance(margin)-based only**; the velocity term is scaffolded in the pure decision function and switched on in Phase 2 only if the UI test / logs show the margin misses fast flings. Rationale: `max(800, 1.5 × viewport)` already gives 300-900 px of head start (≈100-300 ms at fling speed) with zero extra state, and a predictive-velocity term only pays off in a regime where the velocity EMA has not yet converged (i.e. it is least reliable exactly when it claims to help). Smaller diff, fewer flake sources.
- 2026-09-15: keep the machinery **inside `ChatView.vue`**, not a new composable. Extraction touches exactly the code that PRs #308/#310/#324/#336/#337/#349/#355 each broke once; the file's existing source-grep contract spec (`ChatView.userPillRail.spec.ts`) is what makes staying in place safe.
- Inherited, do not re-litigate: `PAGE_SIZE = 100` (`ChatView.vue:457`, cut from 1000 in #434 for TTFB/memory/height-estimate reasons); the 200 ms `VirtualScroller` load-more debounce (`VirtualScroller.vue:888-938`, present since the original lazy-scroll import `ebaa529f`, 2026-05-25 — **no tuning rationale was ever recorded**); the 4-guard order in `handleLoadMore`; `AUTO_STICK_GATE_MS = 500` (`helpers/autoStickGate.ts`); the post-preserve re-stick contract (`ChatView.vue:1986-2026`).

## Symptom
Repro (user): open a long chat, scroll/fling up toward the oldest loaded message. Nothing happens while you travel; only after you are **pinned at the top** does the fetch start, a spinner/affordance appears, and a beat later the older page lands and the view shifts.

Expected: the page is already fetched (or well in flight) while you are still travelling, and the prepend on arrival is invisible.

## Root cause (evidence)

**RC1 — the trigger's timer is a trailing-edge debounce reset on every scroll event, so the fetch cannot *start* until scrolling stops.**
`src/apps/desktop/src/helpers/VirtualScroller.vue:888-938`:
```js
if (loadMoreDebounce) clearTimeout(loadMoreDebounce)                  // :890 — reset on EVERY scroll event
loadMoreDebounce = setTimeout(() => { … emit('loadMore') … }, 200)    // :891 … :938
```
Every fling frame pushes the 200 ms timer out, so the positional check only runs ~200 ms after the *last* event. On a fling ending at `scrollTop = 0`, "last event" **is** "user already at the top". The half-screen head start bought by `loadMoreThresholdRatio` (helper `virtualScrollerThreshold.ts`, commit `118cd073`) is consumed by the debounce before the request is issued. Scope note: a mid-fling pause (finger lift, trackpad break) would fire it earlier, so this is a contributing ~200 ms delay plus the loss of the head start — **not** the entire stall.

**RC2 — the trigger is purely positional, so it cannot beat the network.** `VirtualScroller.vue:916-928` fires at `scrollTop < max(200, clientHeight × 0.5)`. A fling crosses 200-600 px in ~40-300 ms, while the page it then requests (`limit=100` from `GET /api/llm/session/:id/messages`, `api/index.ts:1216-1265`, backend cursor query `llm_history.zig:602-640`) must round-trip, parse, map, prepend, and then be measured/anchored. Raising the ratio cannot fix this for fast flings; only an earlier *decision* can.

**RC3 — all of the work happens while the user is parked at the top.** `handleLoadMore` (`ChatView.vue:2149-2245`) → `loadChatHistory(true)` (`:1819`) → `isLoadingMore = true` → `await api.getChatHistory(...)` → `beginPreserve` (`:1932`) → prepend (`:1944`) → `nextTick` → `endPreserve` (`:1953`) → post-preserve re-stick (`:1986-2026`). Fetch latency *and* the whole preserve dance are serialized in front of a user who has nothing left to scroll.

**RC4 — one page at a time, no in-memory buffer.** After a commit, the next page needs another `loadMore` emit, i.e. another scroll event (or the `endPreserve` restore's event). Every successive scroll-back pays a full round trip again.

**RC5 (adjacent, smaller) — a non-scrollable container can never auto-fetch.** `VirtualScroller.vue:911-914` emits `loadMoreSuppressed('not-scrollable')`; the only route to older rows is the manual button (`ChatView.vue:3537-3557`, gated on `!scrollerIsScrollable`). See Open questions.

### Related "nothing loads at the top" causes — NOT fixed by this plan (documented so triage does not confuse them)
- The 4-guard chain in `handleLoadMore` (`:2183-2222`): `auto-stick-active` → `no-more-messages` → `already-loading` → `no-messages`. During an active stream the auto-stick gate is the most common blocker (the code comment at `:2165` says exactly this); the gate is `isAtBottom && (now - lastAutoStickAt) < 500 ms` (`autoStickGate.ts`), i.e. by design it only blocks a user who is at the bottom.
- Scroller-side suppressions (`VirtualScroller.vue:892-935`): the `isPreservingScroll` branch returns **silently** (no suppression log), which is why a log tail can show `reached-top` followed by silence.
- ChatView passes `:total-count="0"` (`ChatView.vue:3576`), so the scroller's own `hasMore = totalCount === 0 || items.length < totalCount` (`VirtualScroller.vue:898`) is **always true**; `hasMoreMessages` in ChatView is the only real exhaustion gate, and the 200 ms backstop keeps emitting `loadMore` after exhaustion — each one suppressed at `:2199`. The arm path must check `hasMoreMessages` first (it does).

## Why the obvious fixes don't work
| Candidate | Verdict |
|---|---|
| Raise `loadMoreThresholdRatio` | Marginal: a fling crosses any fixed distance in O(100 ms). Eagerly fetches pages the user may never reach, and affects every `VirtualScroller` consumer. |
| Change the shared 200 ms debounce to leading-edge + cooldown | Helps RC1 but not RC2/RC3 — the request still *starts* inside the band, so the round trip still lands after arrival on a fast fling. Changes behavior for `components/kanban/KanbanColumn.vue:821-831` and `components/views/ChatsList.vue:628-635` (both bottom-load). **Do not do this in this PR.** |
| Shrink `PAGE_SIZE` | Multiplies requests and re-enters territory #434 deliberately left (TTFB/height-estimate blowup). Not an ordering fix. |
| Prepend as soon as the early fetch resolves, mid-fling | `beginPreserve`/`endPreserve` write `scrollTop` and fight an in-progress momentum scroll → the jump/teleport class already fought in #308/#337/#349. Rejected: **arm ≠ commit**. |

## Proposed design — arm → commit → refill (one page of lookahead)

Two-phase, because *fetching early* is free and *mutating the DOM early* is not:

1. **ARM (speculative, invisible).** A trigger inside `ChatView.handleVirtualScroll` decides "the user is close enough to the top that a fetch will not finish in time". It issues `GET /messages?cursor=<current>` in the background and stores the mapped page in a **memory buffer**. `messages` is untouched, no scroll position is touched, `isLoadingMore` is not set, `lastAutoStickAt` is not bumped. Cost: one page of message objects (≤100).
2. **COMMIT (positional, visible, semantics unchanged).** When the user enters the scroller's existing band (`distanceFromTop < effectiveLoadMoreThreshold`) — or the 200 ms `@load-more` backstop fires, or the manual button is clicked — the buffered page is committed through the **existing** preserve path. Perceived latency drops to the preserve dance with zero network wait.
3. **REFILL.** After a commit, if `has_more` is still true, arm the next page using the **advanced** cursor, so page-after-page scroll-back is instant rather than only the first page.
4. **DROP.** A buffer is dropped (never committed) when the cursor it was fetched with no longer matches `messageCursor`, the session changed, an initial `loadChatHistory(false)` refresh ran, the component unmounted, or the request failed. Documented causes in the log.

Guard split — the one contract that makes this safe:
- **ARM is gate-free and DOM-free.** It must not be blocked by `isAutoStickActive`: the gate requires `isAtBottom === true` (`autoStickGate.ts`), and the arm requires `distanceFromTop <= armRadius`, which for a scrollable chat is incompatible with being at the bottom — the two conditions are effectively mutually exclusive, so a gate check would add a rule that can never fire.
- **COMMIT honours the auto-stick gate, `hasMoreMessages`, and `isLoadingMore`** exactly as `handleLoadMore` does today (a committed prepend during an active stream is precisely the jitter case `autoStickGate.ts` exists for). The consequence is accepted and documented: if the gate suppresses the commit, the buffer simply waits and commits on the next scroll event / backstop / gate expiry.

### Trigger math
Arm when `!buffered && !inFlight && hasMoreMessages && !isLoading && !isCommitting && !isPreservingScroll && sessionId` **and**
`distanceFromTop <= armRadiusPx(clientHeight)` where
`armRadiusPx(h) = computeLoadMoreThreshold(ARM_RADIUS_FLOOR_PX = 800, ARM_RADIUS_RATIO = 1.5, h) = max(800, 1.5h)`.

Reuses the existing pure helper `computeLoadMoreThreshold` (`helpers/virtualScrollerThreshold.ts:26-45`) instead of adding a second max() helper. Because `max(800, 1.5h) > max(200, 0.5h)` for every `h ≥ 0`, the arm is **always** strictly earlier than the commit band (asserted as an invariant unit test).

`estimatedFetchMs` is an EMA of measured `getChatHistory` round trips (α = 0.4, clamp `[60, 1200]`, cold start 220 ms). In v1 it is **recorded and logged but does not drive the trigger** (distance-only); it exists so Phase 2 can flip the velocity/time-to-top predicate on without re-deriving state, and so the PR can report "the page would have needed X ms, we gave it Y ms of head start".

## New pure helper — `src/apps/desktop/src/helpers/prefetchOlderMessages.ts`
```ts
export const ARM_RADIUS_FLOOR_PX = 800
export const ARM_RADIUS_RATIO = 1.5
export const PREFETCH_SAMPLE_INIT_MS = 220
export const FETCH_EMA_ALPHA = 0.4
export const FETCH_SAMPLE_MIN_MS = 60
export const FETCH_SAMPLE_MAX_MS = 1200

/** Arm radius in px. Reuses computeLoadMoreThreshold — one max() rule in the codebase, not two. */
export function armRadiusPx(clientHeight: number): number

/** EMA of observed getChatHistory durations, clamped and NaN-safe. */
export function nextFetchEstimate(prevMs: number, measuredMs: number): number

export type PrefetchSkip =
  | 'no-session' | 'no-more-messages' | 'already-buffered' | 'already-fetching'
  | 'initial-load' | 'committing' | 'preserving' | 'backoff' | 'not-close-enough'

export interface PrefetchInput {
  distanceFromTop: number
  armRadiusPx: number
  hasMore: boolean
  isLoading: boolean          // initial load in flight
  isCommitting: boolean       // a commit (prefetch/preserve) is in flight
  isPrefetching: boolean      // an arm request is in flight
  hasBufferedPage: boolean
  isPreservingScroll: boolean
  sessionId: string | null
  backoffActive: boolean
  // Phase 2 (ignored in v1 — v1 passes 0 / Infinity):
  velocityPxPerMs?: number
  estimatedFetchMs?: number
  safetyMs?: number
}
export interface PrefetchDecision {
  arm: boolean
  trigger: 'margin' | 'velocity' | 'none'
  reachPx: number
  timeToTopMs: number         // Infinity unless the velocity term is enabled
  skip?: PrefetchSkip
}
export function decidePrefetchOlder(i: PrefetchInput): PrefetchDecision
```
Pure, no DOM, no Vue. Skip codes exist so a log tail answers "why didn't it prefetch?" without guessing — the same philosophy as `loadMoreSuppressed`'s `guard` payload. Re-exported from `helpers/index.ts` next to `isAutoStickActive` (`helpers/index.ts:24`).

## Code changes — `src/apps/desktop/src/components/views/ChatView.vue`

### 1. New state (next to `isLoadingMore`/`hasMoreMessages`, `:991-993`)
```ts
let bufferedOlderPage: BufferedOlderPage | null = null
let prefetchPromise: Promise<void> | null = null   // single source of truth for "arm in flight"
let isCommittingOlder = false                      // synchronous claim flag
let commitGeneration = 0                           // bumped on session change / refresh / unmount
let fetchEstimateMs = PREFETCH_SAMPLE_INIT_MS
let prefetchBackoffUntil = 0

interface BufferedOlderPage {
  fetchedWithCursor: string | null
  commitGeneration: number
  messages: ChatMessage[]
  hasMore: boolean
  nextCursor: string | null
  measuredMs: number
  armedAt: number
}
```
All plain `let` (never rendered, no template consumer) to avoid reactivity churn inside a per-scroll-event handler — same rationale the module-scope diagnostics document at `:2297-2298`, but per-instance. `prefetchPromise !== null` is the **single** in-flight truth; there is no separate `isPrefetching` variable (derive it at the call site when building the decision input). `prefetchBackoffUntil` lives outside the pure decision and is passed in as `backoffActive`.

### 2. Extract the network half of `loadChatHistory`
Pull fetch + row mapping out of `:1831-1890` into:
```ts
const fetchOlderPage = async (cursor: string | null): Promise<BufferedOlderPage>
```
Measures the round trip (`performance.now()`), folds it into `fetchEstimateMs` via `nextFetchEstimate`, and maps rows through the **same mapper the initial load uses** (extract that inline mapper to `toChatMessages(rows)` so the two paths can never drift — the #291 wire-shape lesson). It mutates no component state besides `fetchEstimateMs`.

### 3. `commitOlderPage(page)` — the current `loadMore` branch, moved not rewritten
Move `ChatView.vue:1896-2026` (suppress flag → `wasAtBottom` snapshot → `beginPreserve` → dedupe by id → prepend → cursor advance → `nextTick` → `markProgrammatic` → `endPreserve` → preserve-end log → re-seed `lastObservedScrollHeight` → post-preserve re-stick) into:
```ts
const commitOlderPage = async (page: BufferedOlderPage, trigger: 'buffered'|'foreground'|'manual') => { … }
```
**Synchronous claim, before any `await`** (this is the fix for the double-commit race — see §5):
```ts
if (isCommittingOlder) return                     // second caller loses, synchronously
isCommittingOlder = true
const page = claimBufferedPageOrNull() ?? page    // clears bufferedOlderPage BEFORE the first await
isLoadingMore.value = true
try { …existing body… } finally { isLoadingMore.value = false; isCommittingOlder = false }
```
Then, if `page.hasMore && !isLoading.value`, `armPrefetchOlder('refill')`, subject to the auto-chain budget (§9).

### 4. `armPrefetchOlder(trigger)` — invisible prefetch
- Dedupe: `if (prefetchPromise) return` (single slot; a second arm is a no-op).
- Reads `const cursor = messageCursor.value` and `const gen = commitGeneration`, stores the promise.
- On resolve: drop if `gen !== commitGeneration` **or** `messageCursor.value !== cursor` (session switch / refresh / another path advanced the cursor) → log `load-more-prefetch-dropped` with `cause`. Otherwise store the page and log `load-more-prefetch-armed` with `distanceFromTop`, `armRadiusPx`, `estimatedFetchMs`, `cursor`.
- On reject: `scrollLogger.warn` (`load-more-prefetch-failed`, the logger does have `warn` — `scrollLogger.ts:336-342`) + exponential backoff (`min(2^n × 250 ms, 5000 ms)`, reset on success) so a dead backend is not hammered. Failure never blocks the foreground path.
- Never touches `messages`, `isAtBottom`, `lastAutoStickAt`, `container.scrollTop`, or `isLoadingMore`.

### 5. `maybeLoadOlder(trigger)` — the existing guard chain, extracted from `handleLoadMore`
Move the four guards (`:2150-2244`) verbatim, with one documented exception: the **auto-stick gate applies only to `trigger === 'edge'`**. Today the manual button calls `loadChatHistory(true)` directly (`:3546`) and is therefore never gate-suppressed; preserving that for an explicit click is required.
```ts
const maybeLoadOlder = async (trigger: 'edge' | 'manual') => {
  …guards…
  if (isCommittingOlder) return                                  // race guard
  const buffered = claimBufferedPageOrNull()                     // SYNCHRONOUS claim, clears the slot
  if (buffered) return commitOlderPage(buffered, 'buffered')
  if (prefetchPromise) { await prefetchPromise; …commit the now-buffered page if still valid… }
  return commitOlderPage(await fetchOlderPage(messageCursor.value), 'foreground')
}
```
`claimBufferedPageOrNull()` returns the page only when `page.fetchedWithCursor === messageCursor.value && page.commitGeneration === commitGeneration`, and clears `bufferedOlderPage` in the same tick. `handleLoadMore` becomes a thin wrapper: `handleLoadMore = () => { void maybeLoadOlder('edge') }` (its existing log lines move along unchanged). The `@load-more` template binding (`:3584`) stays as-is.

### 6. Predictive trigger inside `handleVirtualScroll` (`:2301-2360`)
After the geometry block (`:2335-2352`), **skipping sampling rather than returning** on `isProgrammatic` (a programmatic write must not feed the decision, but the handler's own delta persistence at the tail must still run):
```ts
if (!isProgrammatic) {
  const decision = decidePrefetchOlder({
    distanceFromTop, armRadiusPx: armRadiusPx(clientHeight),
    hasMore: hasMoreMessages.value, isLoading: isLoading.value,
    isCommitting: isCommittingOlder, isPrefetching: prefetchPromise !== null,
    hasBufferedPage: bufferedOlderPage !== null,
    isPreservingScroll: virtualScrollerRef.value?.isPreservingScroll === true,
    sessionId: sessionId.value || null,
    backoffActive: performance.now() < prefetchBackoffUntil,
  })
  if (decision.arm) armPrefetchOlder(decision.trigger)
  else if (decision.skip && decision.skip !== 'not-close-enough') scrollLogger.debug({ …reason:'load-more-prefetch-skipped', extra:{ skip: decision.skip, distanceFromTop, armRadiusPx } })

  // Positional COMMIT: inside the scroller's band with a page already armed → commit now
  // instead of waiting for the 200 ms @load-more backstop.
  const band = virtualScrollerRef.value?.effectiveLoadMoreThreshold ?? 200
  if (bufferedOlderPage && !isCommittingOlder && distanceFromTop < band) void maybeLoadOlder('edge')
}
```
Cost per scroll event: a few comparisons plus one `performance.now()` — cheaper than the logging already on that path. No new timer/rAF (consistent with the deliberate synchronous-write contract at `VirtualScroller.vue:874-887`). `effectiveLoadMoreThreshold` is already exposed (`VirtualScroller.vue:1128+`) and read the same way at `ChatView.vue:2230`.

**Double-commit safety:** the backstop (`@load-more`, ~200 ms later) and the positional commit both funnel into `maybeLoadOlder`, which is safe only because the buffer is claimed **synchronously before the first await** and `isCommittingOlder` is set in the same tick. Without that ordering both callers would observe a non-null buffer. This is an explicit contract assertion in §B.

### 7. Invalidation
`resetOlderPrefetch(cause)`: `bufferedOlderPage = null`, `prefetchPromise = null`, `isCommittingOlder = false`, `commitGeneration++`, `prefetchBackoffUntil = 0`. Call sites (all real):
- the two existing `sessionId` watchers (`ChatView.vue:3199-3216` profile load, `:3266-3269` scroll-logger refresh) and `onMounted`'s sessionId assignment;
- `loadChatHistory(false)` (initial load / refresh);
- `onUnmounted` (with the generation bump, a late resolve is inert).
The SSE `full` echo does **not** get a reset call: it patches `messages` in place without replacing the array and without touching `messageCursor`, so the buffer stays cursor-valid and the id-dedupe covers any overlap. (Replacing the array wholesale would be a separate reason to reset — do not add a call "just in case".)

### 8. Logging
Add to the `ScrollReason` union (`helpers/scrollLogger.ts:133-166`):
`'load-more-prefetch-armed' | 'load-more-prefetch-committed' | 'load-more-prefetch-skipped' | 'load-more-prefetch-dropped' | 'load-more-prefetch-failed'`.
`extra` on armed/committed carries `trigger`, `distanceFromTop`, `armRadiusPx`, `bandPx`, `estimatedFetchMs`, `measuredMs`, `bufferedAgeMs`, `cursor`, `autoChainCount`.

### 9. Auto-chain budget (bound on refill)
Refill keeps exactly one page of lookahead, but a commit whose `endPreserve` restore leaves `scrollTop` inside the band can chain buffer-commit-refill-commit… without a new gesture (accelerated version of today's one-page-per-200 ms behavior). Bound it: `autoChainCount` resets on any real user scroll event (`!isProgrammatic && deltaTop < 0`) and stops refilling after `MAX_AUTO_CHAIN = 3` consecutive commits until a fresh gesture. Log `autoChainCount` so the budget is visible.

## Phase 2 (deferred, only if §D/logs show margin-only is insufficient)
Enable the velocity term already present in `decidePrefetchOlder`: add `helpers/scrollVelocity.ts` (EMA of px/ms toward the top, direction-reversal reset, `VELOCITY_GAP_MS = 250`, clamp) + spec, pass `velocityPxPerMs`/`estimatedFetchMs`/`safetyMs` from `handleVirtualScroll`, and assert in the UI test that the request is issued earlier than the margin-only build for a very fast fling. Not in v1: it is least reliable exactly in the regime it claims to help (EMA not yet converged).

## Verification

### A. Pure unit tests (vitest, no DOM)
`src/apps/desktop/src/helpers/__tests__/prefetchOlderMessages.spec.ts`
- `armRadiusPx`: floor/ratio/NaN/negative/zero height; **invariant** `armRadiusPx(h) > computeLoadMoreThreshold(200, 0.5, h)` for `h ∈ {0, 200, 400, 800, 1440, 3000}` (the arm is always earlier than the commit band).
- `nextFetchEstimate`: clamps to `[60, 1200]`, moves toward the sample, ignores non-finite/negative.
- Decision matrix: arm at the margin; every skip code in isolation (`no-session`, `no-more-messages`, `already-buffered`, `already-fetching`, `initial-load`, `committing`, `preserving`, `backoff`, `not-close-enough`).
Run: `cd src/apps/desktop && pnpm vitest --run src/helpers/__tests__/prefetchOlderMessages.spec.ts`

### B. ChatView source-contract spec (the repo's pattern for this 4.9k-line monolith)
`src/apps/desktop/src/__tests__/ChatView.lazyPrefetch.spec.ts`, modeled on `ChatView.userPillRail.spec.ts` (reads `ChatView.vue` as text; no mount). Use **`indexOf` ordering**, not body-extraction regexes — a non-greedy `[\s\S]*?\n\}` match breaks the first time a `}` lands at column 0 in the ~130-line moved body. Assert:
1. `handleVirtualScroll` calls `decidePrefetchOlder` and `armPrefetchOlder`.
2. `armPrefetchOlder`'s body contains **no** `messages.value =` assignment (arm must not mutate the list).
3. `armPrefetchOlder`'s body contains **no** `messageCursor.value =` (arm never advances the cursor; the initial-load reset at `:1826` legitimately stays outside).
4. In `commitOlderPage`: `indexOf('beginPreserve') < indexOf('messages.value =')` and `indexOf('markProgrammatic') < indexOf('endPreserve')`, with `nextTick` between the mutation and `markProgrammatic`.
5. `maybeLoadOlder` still `toContain`s each guard identifier/string: `isAutoStickActive`, `hasMoreMessages`, `isLoadingMore`, `'no-messages'`.
6. `commitOlderPage` sets `isCommittingOlder = true` **before** its first `await` (the synchronous-claim contract).
7. `resetOlderPrefetch` appears in `onUnmounted` and adjacent to both `sessionId` watchers.

### C. Mount-level regression spec (jsdom)
`src/apps/desktop/src/__tests__/views/ChatView.lazyPrefetchMount.spec.ts`, using the `ChatView.scrollRestore.spec.ts` recipe: full mount, `vi.spyOn(api,'getChatHistory')` returning a *distinct page per call* (page 1 then page 2 with `has_more: true`), prototype `scrollHeight = 20000` / `clientHeight = 800`, the `scrollTo` polyfill, `waitForInitialLoad` polling. Known pitfalls and the exact approach:
- **jsdom never fires `scroll` on `scrollTop =` assignment.** Assign `container.scrollTop = n` then `container.dispatchEvent(new Event('scroll'))` per step (the `virtualScrollerGlitchAudit.spec.ts` `scroll()` helper).
- **`handleVirtualScroll` is setup-internal** (not `defineExpose`d), so the only route is dispatching through `wrapper.find('.virtual-scroller')`.
- **Mount with real timers**, then `vi.useFakeTimers()` **after** mount (mount's poll uses `setTimeout 0`; SSE/git handles freeze harmlessly), `vi.useRealTimers()` + `vi.restoreAllMocks()` in `afterEach`.
- **Pin the trigger clock to `performance.now()`** in the implementation, then `let now = 1000; vi.spyOn(performance,'now').mockImplementation(() => now)` and bump `now` between dispatches. Do not rely on fake timers to move the clock (version-dependent), and never double-mock it.
Assert:
1. A burst of upward dispatches with the debounce held `< 200 ms` total triggers the 2nd `getChatHistory` call while `scrollTop` is still well above the band, and `messages` is unchanged (**arm ≠ commit**).
2. One further dispatch inside the band commits **without a 3rd request** (zero new requests when a valid buffer exists).
3. After the commit, the anchor element's offset is preserved (reuse the existing ±2 px style assertion).

### D. MANDATORY functional UI test — real backend + real Vite + real Chromium (post-implementation gate)
`tests/functional_ui/chatview_lazy_prefetch_ui_test.py`, modeled on `chatview_sse_stick_ui_test.py` + `chatview_ui_test.py`. Harness verified present and tracked: `tests/functional_ui/{ui_harness.py,db_seed.py,conftest.py}`; the `ui_harness` fixture boots real `nalar` + real Vite in an isolated tmpdir HOME and reserves ports `(5173, 8081)` while the backend port comes from `[40000, 60000]` — **never 8081**.

Setup:
```bash
# binary must exist first (zig-out/bin/ is not in a fresh worktree)
zig build
NALAR_BIN=./zig-out/bin/nalarcore-linux-x86_64 \
  python3 -m pytest tests/functional_ui/chatview_lazy_prefetch_ui_test.py -v
```
- Seed one session with 250 alternating `seed_user_message`/`seed_assistant_message` rows via `DbSeed` so the initial page (100) has `has_more = true`; open the canonical URL `/app?view=chat&session=<id>` (`_open_chatview`) and wait for the newest seeded text.
- **Instrumentation (one clock, in-page):** wrap `window.fetch` *after* the initial load, recording `performance.now()` for requests matching `/\/messages\?/` into `window.__fetchLog`. (`apiFetch` calls the global `fetch` at call time — `api/index.ts:76`, `API_BASE = '/api'` at `:6` — so no `add_init_script` is needed; and the filter must be `?sort_by=`-anchored, because `/llm/session/:id/queue_messages` (`api/index.ts:3115`) also contains "messages".) Then: `window.__fetchLog.length = 0` so the initial page is not counted, run an rAF fling from the current `scrollTop` to `0` over ~240 ms recording `__tFlingStart`/`__tArrive`, and watch the scroller subtree with a `MutationObserver` for `__tCommit`.
- Assertions — **hard gate (wire fact, robust in CI):**
  1. **fetch-before-arrival** — the first `/messages?` request timestamp is `< __tArrive`. This is the literal request in the task; on the pre-fix build it fails structurally (trailing-edge debounce ⇒ the request starts ~200 ms *after* arrival).
  2. **buffer-hit is free** — a band-crossing with a valid buffer issues **zero** new requests.
  3. **no duplicate pages** — no two requests in the run share the same `cursor` value.
  4. **no duplicate rows** — no two rendered `[data-group-key]` values collide after two consecutive commits, and the rendered group count grows by roughly one page.
- Assertions — **informational with generous fail bounds** (chronium/Vite CI jitter: measure debounce 50 ms + `nextTick` + `endPreserve` rAF + font-dependent layout):
  5. commit latency `__tCommit - __tArrive < 2000 ms` (record the real number in the PR; the feature's claim is "much smaller than before", not a hard ms budget),
  6. anchor drift `< 10 px` (snapshot the top visible message's `getBoundingClientRect().top` around the commit).
- Additional cases:
  7. **exhausted history** — a session seeded below `PAGE_SIZE` (or with `has_more` false) issues **zero** `/messages?` requests on a fling to the top.
  8. **session-switch drop** — delay the messages response with `page.route("**/api/llm/session/*/messages*", … 500 ms)` so the race is deterministic, start a fling in chat A, switch to chat B mid-flight, and assert B renders only its own rows; capture the drop via `page.on("console")` (the `load-more-prefetch-dropped` scrollLogger line) — never compare a Python-side timestamp with an in-page one.
- **Control run (required):** run the same file against `main` (`git stash`/checkout the pre-fix revision in a scratch worktree) and confirm assertion 1 **fails**; paste both runs' numbers into the PR.

### E. No regressions
- `cd src/apps/desktop && pnpm vitest --run` (full suite; last known green: 2667 tests).
- `cd src/apps/desktop && pnpm type-check` (script is `vue-tsc --build` — **`pnpm vue-tsc --noEmit` does not exist**) and `pnpm run build` (also what `.husky/pre-push` runs, together with `zig build test`).
- `pytest tests/functional_ui/chatview_*.py -v` — especially `chatview_sse_stick_ui_test.py` (the auto-stick gate must be untouched for streams) and `chatview_pill_rail_ui_test.py` (group identity after a prepend).
- `pytest tests/functional/` — no backend change in this plan.
- Manual log tail: fling to the top of a long chat, confirm `load-more-prefetch-armed` appears **before** `reached-top`, followed by one `load-more-prefetch-committed` with `trigger: 'buffered'`, and no `load-more-prefetch-failed`.
- `git diff --stat` must show no change to `VirtualScroller.vue`, `virtualScrollerThreshold.ts`, `autoStickGate.ts`, `KanbanColumn.vue`, `ChatsList.vue`, or any `.zig` file.

## Acceptance criteria
1. On a fast upward fling in a long chat, the older-page request is issued **before** the container reaches the top edge (D.1; fails on `main`).
2. With a page armed, crossing the band prepends rows with no network wait, and a second crossing issues zero new requests (D.2, D.5).
3. No duplicate requests, cursors, or rendered rows (D.3, D.4).
4. `has_more` false never issues a request; a session switch never leaks a buffer across sessions (D.7, D.8).
5. Streaming auto-stick behavior is unchanged (E: the SSE stick UI test is green).
6. The pre-fix control run fails D.1 — proving the test measures the bug, not the implementation.
7. Existing suites green; shared components untouched (E).

## Risks & mitigations
| Risk | Mitigation |
|---|---|
| Duplicate pages (the #434 cursor-bug class) | Single arm slot (`prefetchPromise`), one buffered page, cursor+generation equality at claim, id-dedupe preserved verbatim, cursor advanced only at commit (§B.3). |
| Double commit (positional + 200 ms backstop) | Synchronous claim before the first `await` + `isCommittingOlder` (§3, §6) asserted in §B.6. |
| Prepend during an active fling causes a jump | arm ≠ commit; the buffer is only materialized inside the positional band or by the backstop. Preserve/post-preserve logic is moved, not rewritten. |
| Unbounded background auto-chaining (refill loop) | `MAX_AUTO_CHAIN = 3` consecutive commits, reset by a real user scroll event (§9), logged. |
| Wasted requests for pages never read | One page of lookahead, arm radius ≥800 px / 1.5 viewports, `hasMoreMessages` gate, nothing at all for short chats. |
| Interference with streaming / SSE stick | ARM is DOM-free; COMMIT keeps the gate exactly as today; `chatview_sse_stick_ui_test.py` in the regression gate. |
| Failed prefetch hammers a dead backend | Exponential backoff ≤5 s, reset on success, `warn` log; foreground path unaffected. |
| Stale buffer committed into the wrong session | `commitGeneration` + session + cursor equality at both resolve and claim; `resetOlderPrefetch` on the two `sessionId` watchers, refresh, unmount. |
| Timing-test flakiness | Logic in pure helpers (A); monolith pinned by a text-contract spec (B); jsdom spec uses dispatch + pinned clock (C); the only real-browser test asserts wire/DOM facts as the hard gate and treats milliseconds as informational with generous bounds (D). |
| Scope creep into shared components | Explicit non-goal, verified by `git diff --stat` in step 10. |

## Open questions for the human (answer before implementation)
1. **Non-scrollable containers** (RC5): keep the manual "Load more messages" button as the only route, or auto-commit the armed page once when `hasMoreMessages && !scrollerIsScrollable` (removing the click)? The arm trigger can never fire without a scroll event, so this case needs its own decision.
2. **Prefetch on chat open**: also arm one page right after the initial load of a long chat (no scroll at all), so even the *first* scroll-back is instant? One extra request per long chat opened.
3. **Arm radius**: `max(800 px, 1.5 × viewport)` — comfortable but eager. Prefer `max(600, 1.0 × viewport)` (less waste, less head start)?

## Steps (execution order)
- [ ] 1. `helpers/prefetchOlderMessages.ts` + spec (pure): `armRadiusPx` (delegating to `computeLoadMoreThreshold`), `nextFetchEstimate`, the decision matrix, and the arm-earlier-than-commit invariant.
- [ ] 2. Export from `helpers/index.ts`; add the five `ScrollReason` members.
- [ ] 3. **Refactor only, behavior-neutral:** extract `toChatMessages`, `fetchOlderPage`, `commitOlderPage` (with the synchronous claim), `maybeLoadOlder`; `handleLoadMore` becomes a wrapper. Run the full vitest suite here — it must be green before any prefetch logic lands.
- [ ] 4. Add the state, `armPrefetchOlder`, `resetOlderPrefetch`, the trigger + positional commit in `handleVirtualScroll`, refill with the auto-chain budget.
- [ ] 5. Logging (`armed/committed/skipped/dropped/failed`) with the numeric `extra` fields.
- [ ] 6. Source-contract spec (B) + jsdom mount spec (C).
- [ ] 7. **Functional UI test (D)** — write it, run it on the implementation branch, then run it against `main` as the control and record both outputs.
- [ ] 8. Regression gate (E): full vitest, `pytest tests/functional_ui/chatview_*.py`, `pnpm type-check`, `pnpm run build`, manual log tail.
- [ ] 9. Confirm `git diff --stat` touches no shared component; confirm the UI test is green and the control run is red.
- [ ] 10. PR from this worktree with: the two UI-test runs, the pre/post commit-latency numbers, and a log excerpt (`load-more-prefetch-armed` before `reached-top`).

## Files to touch (expected)
- **NEW:** `src/apps/desktop/src/helpers/prefetchOlderMessages.ts`; `src/apps/desktop/src/helpers/__tests__/prefetchOlderMessages.spec.ts`; `src/apps/desktop/src/__tests__/ChatView.lazyPrefetch.spec.ts`; `src/apps/desktop/src/__tests__/views/ChatView.lazyPrefetchMount.spec.ts`; `tests/functional_ui/chatview_lazy_prefetch_ui_test.py`
- **EDIT:** `src/apps/desktop/src/components/views/ChatView.vue` (state, refactor, trigger, logging, invalidation), `src/apps/desktop/src/helpers/index.ts` (re-export), `src/apps/desktop/src/helpers/scrollLogger.ts` (reason union + doc comment)
- **UNCHANGED (asserted in step 9):** `src/apps/desktop/src/helpers/VirtualScroller.vue`, `src/apps/desktop/src/helpers/virtualScrollerThreshold.ts`, `src/apps/desktop/src/helpers/autoStickGate.ts`, `src/apps/desktop/src/components/kanban/KanbanColumn.vue`, `src/apps/desktop/src/components/views/ChatsList.vue`, any `.zig` file

---

# Implementation outcome (2026-09-15) — DONE, verified end-to-end

Branch `worktree/chatview-lazyscroll-auto-fetch-make-it-smoot-1789505349776`. PR #527 (this PR now carries
the implementation as well as the plan).

## What shipped
| File | Change |
|---|---|
| `src/apps/desktop/src/helpers/prefetchOlderMessages.ts` | NEW — pure decision: `armRadiusPx` (delegates to `computeLoadMoreThreshold`), `nextFetchEstimate`, `decidePrefetchOlder` + `PrefetchSkip` codes |
| `src/apps/desktop/src/helpers/__tests__/prefetchOlderMessages.spec.ts` | NEW — 31 tests (margin/NaN edges, every skip code, EMA clamps, arm-earlier-than-commit invariant over `h ∈ {0…3000}`) |
| `src/apps/desktop/src/__tests__/ChatView.lazyPrefetch.spec.ts` | NEW — 14 source-contract tests (arm is invisible; synchronous buffer claim before the first `await`; preserve ordering; cursor writes; invalidation sites) |
| `tests/functional_ui/chatview_lazy_prefetch_ui_test.py` | NEW — 3 real-browser tests (hard gate, exhausted history, multi-page) |
| `src/apps/desktop/src/components/views/ChatView.vue` | `toChatMessages` / `fetchOlderPage` / `resetOlderPrefetch` / `armPrefetchOlder` / `claimBufferedOlderPage` / `commitOlderPage` / `evaluateOlderPrefetch` / `maybeLoadOlder` + the trigger in `handleVirtualScroll`; `loadChatHistory` lost its `loadMore` parameter |
| `src/apps/desktop/src/helpers/index.ts`, `helpers/scrollLogger.ts` | re-exports + 5 new `ScrollReason` members |
| `src/apps/desktop/src/__tests__/ChatView.userPillRail.spec.ts` | retargeted one assertion to `commitOlderPage` (the cursor-advance fix moved there with the code) |
| **UNCHANGED, as planned** | `VirtualScroller.vue`, `virtualScrollerThreshold.ts`, `autoStickGate.ts`, `KanbanColumn.vue`, `ChatsList.vue`, every `.zig` file — verified with `git diff --stat` |

## Deviations from the plan (and why)
1. **No eager prefetch evaluation on open** (plan §C step 4 said "evaluate once after the initial load settles").
   The real browser disproved it: at that point the initial-load scroll has not been applied yet, so
   `container.scrollTop` still reads `0`, the arm radius check passes, and **every chat open burned one
   scroll-back request** which was then dropped a frame later (observed: request at `t=2269 ms`,
   `scrollTop=0`, dropped at `scroll#20`). Removed; the arm now waits for the first real user scroll event.
   This also made the "no scroll-back request on open" gate meaningful (it was vacuous before).
2. **The ChatView mount spec (plan §C) was dropped.** `ChatView.scrollRestore.spec.ts` and
   `chatViewWorktree.spec.ts` fail on a clean `main` in this environment (`.virtual-scroller` never renders
   in jsdom here) — a new mount spec would have been born red. The structural invariants are pinned by the
   source-contract spec instead, and the real-browser test covers the behaviour. Recorded as a known gap.
3. **State lives in one cohesive block** in the pagination section rather than next to `isLoadingMore`
   (~`:991`) — keeps the whole feature reviewable as one hunk.
4. **Velocity is Phase 2 only** (as planned): `decidePrefetchOlder` accepts the term, v1 passes neither
   `velocityPxPerMs` nor `estimatedFetchMs`; `fetchEstimateMs` is measured and logged so the numbers are
   available when/if it is switched on.
5. **`index.ts` was reformatted to single quotes** — it was the one file in `helpers/` not matching
   `.prettierrc.json` (`singleQuote: true`); it now passes `prettier --check`.

## Verification — actual numbers
*(run in this worktree; `NALAR_BIN` pointed at the existing `nalarcore-linux-x86_64` because the backend is
untouched by this task and a fresh worktree has no `zig-out/`)*

| Gate | Command | Result |
|---|---|---|
| Pure units | `pnpm vitest --run src/helpers/__tests__/prefetchOlderMessages.spec.ts` | **31/31 pass** |
| Source contract | `pnpm vitest --run src/__tests__/ChatView.lazyPrefetch.spec.ts` | **14/14 pass** |
| Whole unit suite vs `main` | `pnpm vitest --run` (both trees, failure-set diff) | **31 failures on `main`, the same 31 here** — zero new, zero fixed (all pre-existing env failures: jsdom mount specs, `FilePickerDialog.windows`, `workspacesStore*`) |
| Types + build | `pnpm type-check`, `pnpm run build` | clean |
| **Functional UI (hard gate)** | `pytest tests/functional_ui/chatview_lazy_prefetch_ui_test.py` | **3/3 pass** (ran twice: 3 passed / 3 passed) |
| **Control run (pre-fix)** | same file, frontend stashed back to `main` | **hard gate FAILS**: *"no scroll-back request was issued while the user was still above the load-more band (band=330px) — the prefetch never armed"*; the other two tests still pass |
| UI regression gate | `pytest tests/functional_ui/chatview_*.py` | 24 passed / 4 failed — **the same 4 fail on `main`** (`sse_stick::test_user_scroll_up_during_stream_is_respected`, 3 × `pill_rail`), i.e. pre-existing |

Hard-gate evidence with the fix (band = `max(200, 0.5 × clientHeight)` = 330 px, clientHeight 661 px,
arm radius = 990 px):

```
requests=[{t: 4020, scrollTop: 829, cursor: '1789509429268592'}, …]
[prefetch] commit landed -2 ms after the user reached the top
```

The request is issued at `scrollTop = 829` (≈ 2.5× the band, while the user is still travelling) and the
prepended page is on screen at the moment of arrival — the round trip is off the critical path. Pre-fix the
only request happens after the fling settles, i.e. from inside the band.

## Follow-ups (deliberately not in this PR)
- **Velocity trigger** (Phase 2, §"Phase 2"): flip on `velocityPxPerMs` + `estimatedFetchMs` and add
  `helpers/scrollVelocity.ts` if logs show the margin alone misses very fast flings.
- **Non-scrollable containers** (RC5): the manual button is still the only route; auto-committing once when
  `hasMoreMessages && !scrollerIsScrollable` remains an option.
- **ChatView mount specs**: fix the jsdom harness (`.virtual-scroller` rendering) so a mount-level prefetch
  spec can exist; today the state machine is pinned textually.
- **`has_more` after a short last page**: the browser run showed the backend still reports `has_more=true`
  after a 60-row page, so REFILL arms one extra page fetch that the user may never use. Wasted work is one
  page; worth a backend look separately.
