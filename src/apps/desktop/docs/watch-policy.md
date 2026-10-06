# Watch policy — derived state first, no reactive wrappers

`local/no-watch` bans every `watch()` call. Pre-existing sites are pinned as
baseline debt in `eslint-suppressions.json` (147 sites across 83 files at
PR #825). The baseline only shrinks: regenerate with
`pnpm run lint:banned-baseline` **after fixing debt, never to silence a
violation**.

There is deliberately **no sanctioned reactive wrapper** (no
`useExternalSignal`, no `useWatch`-by-another-name). A wrapper around
`watch()` keeps the reaction hidden inside reactivity instead of removing
it, which is what the ban exists to eliminate. If a case cannot be written
without reacting, bring it to review — the exemption is a deliberate
decision, not a helper import.

## 1. Derived state — `computed()`, no watch needed (default)

If the body only assigns state computable from its source, it is not an
effect. Write it as a pure function of the source:

```ts
// ❌ banned: useEffect(() => setState(derived), [dep]) shape
watch(processingState, (s) => { navItems.value = navItems.value.map(...) })

// ✅ derived: computed at render, no reaction, no double-fire
const navItems = computed(() => baseItems.value.map(...))
```

Covers: `processingState → navItems` maps, `props.expanded → isExpanded`
read-only mirrors, `text → lastSeenText` bookkeeping, counter resets that
are pure functions of the commit. This PR removes 4 sites this way
(`AgentView` no-op, `ChatsList` duplicate, `KanbanDescriptionEditor`
bookkeeping merge, `KanbanTaskDetail` reset moved to the open handler).

## 2. Causing handler — do it where the change originates

If a user action caused the change, the reaction belongs in that handler,
not in a watcher:

- dialog open resets (`name = ''`, `nextTick` + focus) → `openDialog()`
  called from the parent's open path (plus `onMounted` for `immediate`).
  Covers all 16 `watch(() => props.show)` dialog sites (Group A triage).
- debounced search fetch → `@input` handler with its own timer.
- `pendingAction = null` → the dialog-open reset, not `watch(isCreating)`.
- v-model out (`emit('update:modelValue', v)`) → `@input` in the template,
  so programmatic sets and keystrokes share one path.

## 3. External signals — explicit imperative sync, never reactive

These five kinds have no causing handler (the browser chrome is the event
source). Replace the watcher with the explicit subscription that owns the
signal — do not wrap `watch()`:

| Kind | Instead of `watch(...)` | Explicit spelling |
|---|---|---|
| router Back/Forward (`?detail=`, `?layout=`) | `watch(() => route.query.detail)` | `router.afterEach` / `onBeforeRouteUpdate` + `onMounted` sync |
| SSE reconnect | `watch(bus.state)` | `bus.subscribe('open', fetchInitial)` in the store |
| `document.title` | `watch(stores)` | set title in the navigation action (`setActiveChatName`, workspace switch) |
| scroll restore / sentinel | `watch(containerRef)` | `restoreInto(el)` + `attachObserver()` in `onMounted` |
| template-ref remount | `watch(scrollSentinel)` | attach/detach in mount/unmount hooks |

Each replacement is countable: the `watch()` call disappears and the
baseline count for the file drops by one.

## Exemption process

1. Classify the site with the triage table (Group A–D, in the PR
   description): `computed-able` → §1, `causing-handler` → §2,
   `external-signal` → §3, `needs-human` → ask.
2. If §1–§3 genuinely cannot express it, bring the case to review with
   the site, the attempted spelling, and why it fails. An exemption is a
   `// eslint-disable-next-line local/no-watch -- <reason>` with a review
   link, not a new composable.
3. Never add a reactive wrapper to bypass the rule, and never regenerate
   the baseline to silence a new violation.
