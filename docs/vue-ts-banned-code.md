# Banned code in Vue / TypeScript

The Vue/TS counterpart to React's **"You Might Not Need an Effect"**
([react.dev/learn/you-might-not-need-an-effect](https://react.dev/learn/you-might-not-need-an-effect)).
React bans a *shape* — an effect whose only job is to sync state that was
already computable — because it costs a render hop, can fire twice, and
cascades. Vue has the same shape under different names, so the same ban
applies.

**Everything on this page is enforced by lint**, not by good intentions.
The rules live in `src/apps/desktop/eslint-rules/` and are registered in
`eslint.config.ts`. If a pattern is listed here as banned and no rule
enforces it, that is a bug in this document — file it.

---

## 1. The React → Vue mapping

| React doctrine | Vue spelling | Banned? | Enforced by |
|---|---|---|---|
| `useEffect(() => setState(derived), [dep])` | `watch(src, (v) => { x.value = v })` | **yes** — use `computed()` | `local/no-derived-state-watch` |
| `useEffect(() => setCount(count+1), [count])` — infinite rerender | `watch(a, (v) => { a.value = … })` — retriggers itself | **yes** — stop mirroring | `local/no-watch-feedback-loop` |
| `useEffect` with no dep array (runs every render) | `watchEffect(cb)` — implicit deps | **yes, outright** | `local/no-watch-effect` |
| Reset state when a prop changes | `watch(() => props.x, () => { draft.value = '' })` | **yes** — use `:key` | `local/no-derived-state-watch` |
| `catch` that swallows a fetch failure | `catch { return [] }` | **yes** — carry the failure in the type | `local/no-silent-fallback-catch` |
| `as any` to silence the compiler | `@ts-ignore` / `@ts-nocheck` | **yes** | `@typescript-eslint/ban-ts-comment` |
| — | bare `any` | **yes**, with a written reason | `@typescript-eslint/no-explicit-any` |

### What is NOT banned, and why

This matters as much as the bans. A rule with false positives gets deleted,
and deleting it takes the ban with it.

**`watch(() => props.id, () => load())` is the legitimate `useEffect`
equivalent — and it is the dominant idiom in this repo.** 46 of the 103 real
`watch` call sites have exactly this shape. It fetches, it touches the DOM,
it starts a timer, it calls a store action. All of that is what an effect is
*for*. A regex that banned `watch(` would flag it; the AST rule does not,
because the rule requires the callback body to contain **no call at all**
before it will call the watcher derived-state.

```ts
// ❌ BANNED — computable from the source, so it needs no watcher.
const doubled = ref(0)
watch(() => props.n, (v) => { doubled.value = v * 2 })

// ✅ — one line, no render hop, cannot fire twice.
const doubled = computed(() => props.n * 2)
```

```ts
// ✅ ALLOWED — a real side effect. This is what watch() is for.
watch(() => props.id, async (id) => { rows.value = await fetchRows(id) })
```

`attempt.value += 1` inside a watcher is also allowed when the body also
does something observable: an accumulator depends on the value's own history,
so `computed()` cannot express it. A watcher that does *nothing but*
accumulate is still reported — that one is usually an event counter that
belongs in the handler that caused it.

---

## 2. The feedback loop — `watch` writing into what it watches

```ts
// ❌ BANNED. Vue re-runs a watcher when a dependency it READS changes, so
//    writing `items` schedules another run. It stops only because the second
//    write happens to be identical — termination by accident, not design.
watch(items, (v) => { items.value = [...v, next] })

// ❌ BANNED. Mutating the watched prop feeds the same watcher.
watch(() => props.row, () => { props.row.busy = true })

// ❌ BANNED. `deep: true` re-runs on ANY nested mutation.
watch(list, (v) => { v.forEach(i => { i.done = true }) }, { deep: true })
```

Enforced by `local/no-watch-feedback-loop`. **1 site in this repo**:
`ChatsList.vue:978`, a `deep: true` watcher that mutates `item.processing` on
the very array it watches.

```ts
// ✅ Derive instead of mirroring.
const withDone = computed(() => list.value.map(i => ({ ...i, done: true })))
```

This is a **separate rule from `no-derived-state-watch` on purpose.** That
rule only fires when the callback contains no call at all, which is exactly
why it allows a mixed body like `watch(a, v => { a.value = f(v); save() })` —
and that mixed body is where a self-write hides. The `save()` call makes the
watcher look like a legitimate side effect while the assignment keeps feeding
itself.

Three things are deliberately *not* flagged, each of which was a false
positive in the first draft:

| Shape | Why it is allowed |
|---|---|
| `watch(() => props.x, v => local.value = v)` | `props` is the dependency, not `x` |
| `watch(() => vm.name, n => { document.title = n })` | a global is outside the reactivity graph |
| `watch(list, v => { v.forEach(i => i.x = 1) })` *(no `deep`)* | a nested mutation without `deep` fires no trigger |

---

## 3. The two error-hiding bans

These implement the AGENTS.md rule *"No `try`/`catch` in the desktop app; use
Effect-TS"*, which was written but not enforced. 441 production `catch`
blocks existed; 242 of them emitted no diagnostic at all.

### `local/no-silent-fallback-catch`

Fires when a `catch` **both** assigns an empty-looking fallback (`null`,
`[]`, `{}`, `''`, `false`, `0`) **and** emits no diagnostic — no
`console.*`, no `throw`, no write to an `error`-shaped ref.

This is PR #719 exactly:

```ts
// ❌ The failure becomes an empty session.
try {
  const data = await api.getChatHistory(sid, PAGE_SIZE, undefined)
  messages.value = data.messages
} catch {
  return { messages: [], has_more: false, next_cursor: null, skills: [] }
}
```

`messages: []` now means both "backend is down" and "this session is empty",
so `error` stayed `null` and the empty state rendered **"How can I help
you?"** for a session full of messages. The `chat-load-error` block and its
Retry button were dead code.

All three of these are accepted:

```ts
catch (e) { console.error('load', e); return [] }        // logs it
catch (e) { error.value = String(e); return [] }         // surfaces it
catch { /* quota exceeded — the live fetch still works */ }  // explains it
```

The last one is AGENTS.md's own sanctioned escape — *"say a comment why the
failure cannot be handled by the type"*. Flagging it would train people to
delete the rule instead of obey it.

**Preferred fix:** put the failure in the type. `src/apps/desktop/src/sync/`
is the reference implementation — `runSyncResult` keeps *both* outcomes
distinguishable (`{ ok: true, value }` / `{ ok: false, reason }`), which is
what a rendered error UI actually needs.

### `local/no-watch-effect`

`watchEffect` is the one form of `watch` banned outright. `watch(a, cb)`
names its dependencies; `watchEffect(cb)` infers them from every reactive
value the body happens to read — so adding a ref read six months from now
silently changes when the effect re-runs. Zero occurrences today, so it
ships at `error` with no baseline.

---

## 4. The ratchet: how pre-existing debt is handled

Banning `catch` outright would have failed CI on 441 files, and a ban that
lands red gets reverted. So the two ratcheted rules run against a **baseline**
of the violations that already exist:

```jsonc
// src/apps/desktop/eslint-suppressions.json  (114 sites, committed)
{
  "src/components/AppLayout.vue": {
    "local/no-derived-state-watch": { "count": 2 },
    "local/no-silent-fallback-catch": { "count": 2 }
  }
}
```

- Fix a site → the count no longer matches → `lint:check` stays green and the
  stale baseline entry should be regenerated.
- Add a new site → the count exceeds the baseline → **CI goes red**.
- The count can therefore only go **down**.

Regenerate after intentionally fixing debt:

```bash
cd src/apps/desktop
pnpm run lint:banned-baseline
```

> **Mechanics worth knowing:** ESLint's `--suppress-rule` records **only
> error-severity** violations. A `warn`-level baseline is silently written as
> an empty `{}` and the ratchet never engages. That is why every rule in
> `eslint.config.ts` is severity `error` — the tiering is done by *suppression*,
> not by severity. Do not "soften" a rule to `warn` to make it less annoying;
> that silently disables its baseline.

Both directions are pinned by
[`src/__tests__/bannedCodeRules.spec.ts`](src/apps/desktop/src/__tests__/bannedCodeRules.spec.ts)
— 22 tests asserting each ban fires *and* that the legitimate shapes stay
silent. A lint rule that silently stops matching is worse than no rule, so
the "allows" half is the one that matters.

---

## 5. Current baseline

| Rule | Before | Now | How |
|---|---|---|---|
| `local/no-watch-effect` | 0 | **0** | `error`, no baseline needed |
| `local/no-watch-feedback-loop` | 0 | 1 | baselined, ratcheting |
| `local/no-derived-state-watch` | 25 | 26 | baselined, ratcheting |
| `local/no-silent-fallback-catch` | 87 | 87 | baselined, ratcheting |
| `ban-ts-comment` (`@ts-ignore`) | 0 | **0** | `error`, no baseline needed |
| `no-explicit-any` | 0 | **0** | `error`, no baseline needed |

The derived-state count rose by one during development, and that is the
ratchet working as intended rather than a slip: tightening the rule to
recurse through `else` branches (so a watcher that only assigns is caught
even behind a guard) surfaced one more genuine case. It went into the
baseline rather than being suppressed with a disable comment.

`@ts-ignore` and bare `any` cost nothing to enforce because the codebase had
already done the work: all 631 `as any` carry an inline
`// eslint-disable-next-line … -- <reason>`. The rule just makes that
discipline stick for new code.

`@ts-expect-error` is **allowed with a `-- reason`**. It is not a blanket
escape — it fails the build if the error it covers is ever fixed, which
`@ts-ignore` does not. The 10 existing uses are deliberate negative-type
tests: `sseIsInputOutput.spec.ts` assigns `'1'` to a boolean field precisely
to assert the compiler rejects it.

---

## 6. Fixing a baselined violation

The derived-state fixes are usually one-liners:

```ts
// useChatScrollRestore.ts:107 and its two siblings
watch(storageKey, (v) => { keyRef.value = v }, { immediate: true })
// →
const keyRef = toRef(storageKey)   // a Ref alias — no watcher at all
```

```ts
// FilePickerDialog.vue:870 — prop-mirror with a default
watch(() => props.showHidden, (v) => { showHiddenLocal.value = v ?? false })
// →
const showHiddenLocal = computed(() => props.showHidden ?? false)
```

When a watcher does one real thing *and* an assignment, keep the side effect
and move the assignment — then the rule stops firing:

```ts
// PropertiesPanel.vue:187 — seed a draft without clobbering an in-progress edit
watch(() => singleElement.value?.id, () => {
  if (!htmlExpanded.value && singleElement.value) {
    void fetchRows(singleElement.value.id)   // ← the call makes it a real effect
    htmlDraft.value = singleElement.value.text_content || ''
  }
})
```