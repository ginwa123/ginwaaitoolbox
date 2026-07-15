# nalar — Vue 3 async onMounted + bus listener test timing

Vue 3's `onMounted(async () => { ... })` doesn't run its body until
several microtask cycles after `mount()` resolves. Tests that
mount a component and immediately fire events into a bus the
component subscribes to during onMounted can miss the first event
because the listener wasn't registered yet.

## Symptom

A test that:
1. `mount(ChatView)` (which `onMounted` calls `connectSse()` that
   calls `bus.on('llm', cb)`)
2. Calls `__dispatchSseBus('llm', { session_id: 'mySid', ... })`
3. Asserts `vm.streamingContent === 'expected'`

…fails with `expected '' to be 'expected'`, even though the bus
is installed and the listener was clearly meant to fire. The
listener debug log inside the bus subscription is silent — the
listener was never registered by the time the dispatch ran.

The "ghost listener" tell: a SECOND test's dispatch can fire the
FIRST test's listener (because the bus `_instance` got swapped by
the new `installSseBus` in the second test's `beforeEach`, but
the first test's listener was registered LATE — after the bus
swap — and ended up in the new bus's listener Set).

## Why

`onMounted`'s callback is async, and the await chain inside
(`await loadChatHistory()` then `connectSse()` then
`bus.on('llm', cb)`) takes 1+ microtasks + 1 macrotask to
resolve. Test code that does `await nextTick()` × 3 + `await
setTimeout(0)` × 3 (the conventional "wait for everything"
recipe) may not be enough — `setTimeout(0)` doesn't fire if the
microtask queue is non-empty (Node 0.x-22 flushes all microtasks
first, but jsdom + Vue's lifecycle scheduling can interleave
differently).

## Fix (this codebase, Chunk 7)

In production code, set the "ready" flag LAST in the async
lifecycle, after all the listener-registration side effects:

```ts
const connectSse = () => {
  // ... register listeners, open bus channels ...
  bus.subscribeSessionChannels(sid)
  // Set isStreaming LAST so external observers (tests, UI) can
  // poll it as a "listeners are wired up" signal — flipping it
  // before would race with test assertions that fire events into
  // the bus expecting the listener to be registered.
  isStreaming.value = true
}
```

In test code, poll the flag with a bounded loop instead of
assuming `setTimeout(0) × 3` is enough:

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

20 iterations × 4ms minimum per `setTimeout(0)` = up to 80ms
budget for the async lifecycle to settle. Far more than
necessary in practice (the first iteration usually succeeds),
but bounded so a stuck lifecycle doesn't hang the test.

## Why this is invisible in production

In production, the user clicks a chat tab → router sets the chat
id → ChatView mounts → onMounted runs → connectSse registers
listeners. The user takes hundreds of milliseconds to type their
next message; the listener is always ready by then. Tests fire
events in the millisecond window after mount, which is the exact
window where the bug shows up.

## When this bites

- Any test that mounts a Vue 3 component with an `async onMounted`
  that subscribes to a bus / event stream / global singleton.
- The test pattern: `mount(Component) → await waits → fire event
  into bus → assert state mutated`. If the assertion fails
  silently (no listener log, no bus state error), the listener
  probably wasn't registered yet.
- Migrations of `createUnifiedSseConnection` to `bus.on` in
  follow-up chunks (Chunk 8 useSubAgentPeek, Chunk 9
  SubAgentPeekPanel, etc.) — same pattern, same race.

## How to verify

After the fix, the test log should show:
1. The bus install (`installSseBus` + `__setSseBusGlobalClient` +
   `__setSseBusSessionFactory` in `beforeEach`)
2. `connectSse` running (`console.log('[connectSse] ...')` if
   you left one in, or a debug log from the listener)
3. The test's `__dispatchSseBus` call
4. The listener firing
5. The state mutation
6. The assertion passing

If steps 2-3 appear AFTER step 4 in the log (out of order), the
race is still present. Add more polling iterations or a
"ready" promise.
