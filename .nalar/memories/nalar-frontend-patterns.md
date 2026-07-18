# nalar — frontend patterns (Vue 3 / TypeScript / desktop app)

This file consolidates nalar desktop app frontend patterns. For backend patterns, see `nalar-backend-architecture.md`. For build/CI infra, see `nalar-infra-and-build.md`.

---

## `bun run build` is the TypeScript type-check, NOT `vitest run`

`bunx vitest run` runs the test suite but does **not** run `vue-tsc` for strict TypeScript type checking. The test files pass type-erasure at runtime, so TS errors like `Object is possibly 'undefined'` (TS2532) only surface during a full `vue-tsc` pass — which happens during `bun run build`, not during `bunx vitest run`.

**Symptom:** A code reviewer approves a TS change because `vitest run` passes (all tests green), but the next `bun run build` fails with multiple `TS2532: Object is possibly 'undefined'` errors in the new test file. The bug was always there; `vitest run` just doesn't see it.

**Why:** Vitest is a test runner. It compiles each test file to JS at runtime, with TypeScript's type checking effectively elided (Vitest uses `esbuild` for transform, which strips types without checking them). The `vue-tsc` step that DOES check types only runs in `bun run build`.

**Fix — always run BOTH:**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20      # type-check + bundle
timeout 120 bunx vitest run 2>&1 | tail -n 20    # unit tests
```

If both are clean, the change is good.

**When this bites:**
- Reviewing a TypeScript change where the implementer only ran tests
- Writing spec files with optional-chaining shortcuts that don't propagate to property access (e.g., `result?.[0].name` is `T | undefined` — needs `result?.[0]?.name`)
- The `??` operator on nullish-coalesced values (`a ?? b` where both can be undefined) — `vue-tsc` flags this in strict mode
- Any test that mocks types with `as` casts that the runtime never actually exercises

---

## `apiFetch` mock helpers need `text()` method + active Pinia

The shared `apiFetch` wrapper in `src/apps/desktop/src/api/index.ts` has two requirements that bare-bones `fetch` mocks miss:

1. **`response.text()` is called on every non-OK response** to extract the body for the error notification. Mocks must implement `text: () => Promise.resolve(...)` in addition to `json: () => Promise.resolve(...)`.

2. **`useNotificationStore()` is called on every non-OK response** to fire a toast. Tests must set up an active Pinia instance via `setActivePinia(createPinia())` in `beforeEach`, otherwise the call throws `[🍍]: "getActivePinia()" was called but there was no active Pinia`.

**Symptom:**

```
TypeError: response.text is not a function
```

or

```
[🍍]: "getActivePinia()" was called but there was no active Pinia.
```

**Fix — two-line addition to the mock helper:**

```ts
function mockFetchOnce(status: number, body: unknown) {
  fetchMock.mockResolvedValueOnce({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),  // ← add
  } as Response)
}

beforeEach(() => {
  setActivePinia(createPinia())  // ← add (apiFetch needs it for toasts)
  // ... existing test setup
})
```

**Why bare-bones mocks fail:** the old `fetch` + `if (!response.ok) throw new Error()` pattern only reads `response.json()`. The `apiFetch` wrapper additionally:
- Calls `await response.text().catch(() => '')` to extract the body for error reporting
- Calls `useNotificationStore().notifyError(...)` to surface the error as a toast

**When this bites:** any test that mocks `fetch` for a function that was just migrated to `apiFetch`. Adding a new test for an `apiFetch`-using function that exercises 4xx/5xx responses. Reviewing a PR that migrates a function to `apiFetch` — the test mock needs both additions; only fixing one causes a confusing follow-up error.

---

## Browser EventSource — Named Events Must Be Pre-Registered

The browser-native `EventSource` dispatches a server-sent `event: <name>` line ONLY to listeners registered for that exact name via `addEventListener('<name>', ...)`. There is no "catch-all" or "dispatch all named events" API. The default (unnamed) `message` event is the only one that gets auto-routed to `onmessage`.

**Symptom:** Server-sent events appear in the browser's Network tab (wire format correct: `event: foo\ndata: {...}\n\n` reaches the browser), but they **never reach the JS handler**. Heartbeats, pings, and unnamed events work, but every named event is silently lost.

**Why:** `EventSource.addEventListener('queue_message', cb)` is required. If the wrapper only registers `'message'` and `'connected'`, named events like `queue_message`/`worker_event` are silently lost.

**Fix — the wrapper must let the consumer declare which named event types to receive:**

```ts
createSseClient({
  url: '/api/...',
  onEvent: (raw, eventType) => { /* 'message' | 'connected' | 'queue_message' | … */ },
  additionalEventTypes: ['queue_message', 'worker_event'],  // ← required for named events
})
```

**Heartbeat filter:** backends typically send `data: ping\n\n` as keepalive. This arrives as a default `message` event with `raw === "ping"` — noise to the consumer and can grow an unbounded JSON buffer. The wrapper should filter it by default — `heartbeatData: 'ping'` is the convention. Consumers can opt out with `heartbeatData: null`.

**When this bites:** any SSE wrapper exposing `onEvent(raw, eventType)`; any time the server emits named events and the consumer never sees them but the wire format is clearly correct.

---

## Frontend — jsdom normalizes hex colors to `rgb()`

When a Vue component sets an inline style with a hex color literal (`:style="{ backgroundColor: '#22c55e' }"`), `jsdom` (the test environment used by Vitest) reads it back through `wrapper.attributes('style')` as `rgb(34, 197, 94)`, not the original `#22c55e`.

**Symptom:**

```
AssertionError: expected 'background-color: rgb(34, 197, 94);'
                to match /green|#22c55e/i
```

**Why:** jsdom uses the browser CSSOM to serialize style values. Per CSSOM spec, `getComputedStyle().backgroundColor` returns colors in `rgb(r, g, b)` form, not the original literal.

**Hex → RGB reference (Tailwind 500 colors):**
- `#22c55e` (green-500) → `rgb(34, 197, 94)`
- `#ef4444` (red-500) → `rgb(239, 68, 68)`
- `#eab308` (yellow-500) → `rgb(234, 179, 8)`
- `#10b981` (emerald-500) → `rgb(16, 185, 129)`

**Fix — assert the `rgb()` form in tests:**

```ts
// Option 1: assert the exact rgb() string
expect(dot.attributes('style') ?? '').toContain('rgb(34, 197, 94)')

// Option 2: parse and assert the channel values
const style = dot.attributes('style') ?? ''
expect(style).toMatch(/background-color:\s*rgb\(\s*34,\s*197,\s*94\s*\)/)
```

The component code can keep the hex literal; only the test needs to know about the jsdom normalization.

---

## Vue 3 async `onMounted` + bus listener test timing

Vue 3's `onMounted(async () => { ... })` doesn't run its body until several microtask cycles after `mount()` resolves. Tests that mount a component and immediately fire events into a bus the component subscribes to during onMounted can miss the first event because the listener wasn't registered yet.

**Symptom:** A test that:
1. `mount(ChatView)` (which `onMounted` calls `connectSse()` that calls `bus.on('llm', cb)`)
2. Calls `__dispatchSseBus('llm', { session_id: 'mySid', ... })`
3. Asserts `vm.streamingContent === 'expected'`

fails with `expected '' to be 'expected'`, even though the bus is installed and the listener was clearly meant to fire. The listener debug log is silent — the listener was never registered by the time the dispatch ran.

**Fix — production code: set the "ready" flag LAST:**

```ts
const connectSse = () => {
  bus.subscribeSessionChannels(sid)
  // Set isStreaming LAST so external observers (tests, UI) can poll
  // it as a "listeners are wired up" signal — flipping it before
  // would race with test assertions.
  isStreaming.value = true
}
```

**Fix — test code: poll the flag with a bounded loop:**

```ts
async function mountChatView(chatId = 'session_test') {
  const wrapper = mount(ChatView, { props: { chatId, ... } })
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as any).isStreaming
    if (streaming) break
  }
  return wrapper
}
```

20 iterations × 4ms minimum per `setTimeout(0)` = up to 80ms budget.

**Why this is invisible in production:** the user clicks a chat tab → router sets the chat id → ChatView mounts → onMounted runs → connectSse registers listeners. The user takes hundreds of ms to type their next message; the listener is always ready by then.

---

## Vue 3 async onMounted + click race (the "empty chat on toggle" bug)

A common pattern is to kick off an async "resolve existing row" lookup in `onMounted` (so the UI can show the persisted state after a page reload), then have a click handler that *creates* a new row if the resolve hasn't finished. **This is a race condition that silently corrupts the DB.**

**Symptom:**
1. User opens a page where the component does an async lookup in `onMounted`.
2. User clicks a toggle button BEFORE the lookup finishes (~50-200ms race window).
3. Click handler sees `existingRowId.value === null` (lookup hasn't completed) → falls into "create new" branch.
4. A SECOND row is created with the same discriminator.
5. The new row has no associated data; new row is what gets mounted.
6. User sees: "sidebar shows the original (populated) row, but the detail view is empty."

**Why this bites (3 reasons):**
1. **No UNIQUE constraint protects the discriminator column.** `workspace_item_tasks(workspace_item_id, name)` has no UNIQUE index, so the DB silently accepts the duplicate.
2. **The first click seems to work.** The user clicks "Chat", a panel appears, they type "hello", and the response comes back. But they're chatting with the EMPTY new task, not the original.
3. **The bug looks like a network/DB issue from the user's POV.** They report "the chat is empty when I open it" — not "two Chat tasks are being created".

**The fix pattern — make the click handler wait for the eager resolve:**

```ts
async function handleClick() {
  // OFF path ...

  // ON path: wait for the eager resolve if it's still in flight.
  if (!xxxReady.value) {
    xxxLoading.value = true
    try {
      await resolveExistingXxx()  // idempotent — no-op if already done
    } finally {
      xxxLoading.value = false
    }
  }

  // Now we know for sure: chatReady is true, chatTaskId reflects
  // the current DB state. Safe to create if still null.
  if (!xxxId.value) {
    const created = await api.createXxx(...)
    xxxId.value = created.id
  }

  // Flip the UI state atomically (AFTER the createTask), not
  // before. Avoids the "Chat On" state flashing with no panel mounted.
  showXxx.value = true
}
```

**Source-level regression test:**

```ts
test('DesignView toggle awaits the eager resolve before creating', () => {
  const fnMatch = source.match(/async function handleToggleChat\(\) \{([\s\S]*?)\n\}/)
  if (!fnMatch || !fnMatch[1]) throw new Error('handleToggleChat missing')
  const body: string = fnMatch[1]

  // 1. The await must be in the ON path.
  if (!body.includes('await resolveExistingChatTask')) throw new Error(...)

  // 2. showChat.value = true must come AFTER the await.
  const flipPos = body.indexOf('showChat.value = true')
  const awaitPos = body.indexOf('await resolveExistingChatTask')
  if (awaitPos < 0 || awaitPos > flipPos) throw new Error(...)
})
```

---

## SPA HTML5-history reload returns 404 (Vue Router / React Router)

The desktop app uses Vue Router's `createWebHistory` (HTML5 history mode) for `/app`, `/app/settings`, `/app/chat/:sessionId`, `/app/task/:taskId`. A SPA build output has only `index.html` + `assets/`. Reloading at any client-side route (e.g., `http://localhost:8081/app/settings`) sends `GET /app/settings` to the server, which tries to find `app/settings` in the static dir, fails, returns 404.

This is the **classic SPA reload 404 problem**. The fix is a **prefix-scoped SPA fallback** in the static-file handler — when a request path doesn't resolve to a real file AND doesn't have a file extension AND falls under a configured SPA prefix, serve the root `index.html` so the SPA's router takes over.

**Fix shape — opt-in, prefix-anchored, explicit:**

A SPA fallback that catches ALL non-asset paths would mask real 404s for unregistered API paths. The fix must be:

1. **Opt-in via `StaticDirConfig.spa_fallback_prefix`** — null default preserves the old 404-for-everything behavior.
2. **Prefix-anchored matching** — `/app` matches `/app` and `/app/...`, but NOT `/apple`. Requires exact-match OR `prefix + "/"` (boundary check).
3. **Asset-vs-route distinction** — paths with a file extension in the final path component (e.g., `/assets/missing.js`) get 404, even under the prefix.

**Why not "just always fall back to index.html":** The naive fix silently masks real 404s. For nalar, 89 API routes plus operational routes are registered. Each `router.matchRoute` runs first; matches return real responses. For UNREGISTERED paths (`/api/not-real`, `/test/foo`), `router.matchRoute` returns null, falls through to static-dir handler. Without prefix scoping, the handler would silently serve `index.html` for any of these — masking real API bugs as "SPA shell is fine".

**Code location:** `src/modules/static_files.zig::resolve()` — see the `error.FileNotFound` branch. New helpers: `looksLikeAssetPath(path)` (true if last `/`-delimited component contains `.`), `pathMatchesSpaPrefix(path, prefix)`.

**Verify end-to-end:**

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8090/app              # 200
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8090/app/settings     # 200
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8090/app/chat/xyz    # 200
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8090/api/health       # 404 (correctly!)
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8090/apple            # 404 (boundary!)
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8090/assets/missing.js # 404
```

---

## cloak_browser snapshot does NOT capture JavaScript-rendered content

`cloak_browser`'s `snapshot` action returns the page's accessibility tree (similar to a screen reader). This includes **static HTML elements only**. Values populated by client-side JavaScript (currency rates, live prices, SPAs, dynamic charts) appear as empty placeholders or raw CSS class names (e.g., `:rr:`, `:r13:`) — never as the actual numbers.

**Symptom:** Browsing `https://www.xe.com/currencyconverter/...` returns the page navigation, footer, FAQs, chart controls — but the actual converted-amount value is missing or shows a placeholder like `:rr:`. Page is fully loaded (status 200, title correct), but dynamic value just isn't there.

**Why:** The accessibility tree is captured from the rendered DOM at the moment of the snapshot. JavaScript that runs AFTER the initial DOM parse populates elements (often via framework hydration). The accessibility tree does not see post-hydration content unless the snapshot is taken after hydration completes — and the snapshot does NOT wait for hydration.

**Fix for live-data needs — use a free API endpoint via curl:**

```bash
curl -sS "https://open.er-api.com/v6/latest/USD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(f"1 USD = {d[\"rates\"][\"IDR\"]:,.4f} IDR")
'
```

Other free FX APIs:
- `https://api.exchangerate-api.com/v4/latest/USD`
- `https://open.er-api.com/v6/latest/USD` (used above — `{"result":"success","base_code":"USD","rates":{...},"time_last_update_utc":...}`)
- `https://api.frankfurter.app/latest?from=USD&to=IDR,EUR,SGD,MYR` (European Central Bank reference rates)

**When this bites:** "get today's rate / price / weather / score" requests; Single Page Apps (Vue, React, Svelte) — hydrate client-side and the snapshot misses it; Google search's currency converter widget (JS-injected, not in tree).

---

## Frontend — fixed-positioned top-right badges MUST use `pointer-events-none`

A fixed-positioned pill / toast / status indicator at the top-right of the viewport (e.g., `fixed top-3 right-3 z-50`) **captures clicks** in the rectangle it occupies. If a view underneath also places a control at the top-right (a chat close ✕, a settings cog, a notification bell, etc.), that control becomes **unclickable** while the badge is visible.

**Symptom:**
- A view's close (✕) / menu / settings button stops responding to clicks while the status badge is on screen.
- DevTools Elements panel → the badge element is the click target (`event.target` shows the badge `<div>`, not the button underneath).
- Z-index appears "right" (badge < button) but the badge is still the target — z-index only affects PAINT order, not HIT TESTING.

**Why this bites in this codebase:** The kanban 3-column layout puts `ChatView` as the right-hand column. ChatView's header has a ✕ close button sitting at the top-right. The SSE status badge is also at the top-right of the VIEWPORT. When the SSE reconnects after a network blip, the "Reconnecting..." pill appears and the user cannot click ✕ to close the chat.

**Fix — `pointer-events-none` on the badge container:**

```vue
<div
  class="fixed top-3 right-3 z-50 pointer-events-none"
  data-testid="sse-status-badge-container"
>
  <SseStatusBadge />
</div>
```

**When NOT to use this pattern:**
- The badge has its OWN clickable children (e.g., a "Retry now" button inside the toast). Apply `pointer-events-none` to container and `pointer-events-auto` on inner buttons.
- The badge needs to FOCUS keyboard input (e.g., an inline edit field). `pointer-events: none` blocks focus too.
- The badge blocks clicks intentionally (e.g., a "loading" overlay).

**Why z-index alone is not enough:** z-index controls PAINT ORDER, not HIT TESTING. The badge placed AFTER the button in the DOM wins the hit test regardless of any z-index on the button. `pointer-events: none` is the ONLY clean way to make an element visible-but-click-through.

---

## Related / cross-references

- `nalar-backend-architecture.md` — backend patterns
- `nalar-infra-and-build.md` — build/CI patterns
- `zig-build-and-test.md` — Zig test patterns (parallel to vitest patterns)