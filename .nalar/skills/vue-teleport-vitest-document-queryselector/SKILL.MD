---
name: vue-teleport-vitest-document-queryselector
description: "How to test Vue 3 components that use <Teleport to=\"body\"> with @vue/test-utils: use attachTo: document.body and document.querySelector for DOM assertions (NOT wrapper.find)"
---
---
name: vue-teleport-vitest-document-queryselector
description: How to test Vue 3 components that use <Teleport to="body"> with @vue/test-utils: use attachTo: document.body and document.querySelector for DOM assertions (NOT wrapper.find)
tags: [pattern, fix, vue, vitest]
---

## When to Use
- Writing component tests for any Vue 3 dialog/modal/overlay that uses `<Teleport to="body">`
- Any time `wrapper.find('[data-testid=...]')` returns empty even though the component is mounted with `show: true`

## Context
`vue-test-utils@2`'s `mount()` returns a wrapper whose `wrapper.element` is the **mount target** — a fresh `<div data-v-app>` (or the `attachTo` target) — but **NOT the teleported content**. The Teleport moves the rendered DOM to a sibling of the mount target under `document.body`. `wrapper.find()` walks from `wrapper.element` downward, so it can never see the teleported nodes.

## Symptom
- Test renders the component with `show: true`
- `wrapper.html()` shows `<!--teleport start--><!--teleport end-->` (the Teleport placeholder)
- `wrapper.find('[data-testid=...]')` returns an empty wrapper
- `wrapper.find('button').trigger('click')` works only on the mount target's children — teleported buttons are invisible

## Verified Pattern (used in `imagePreview.spec.ts`, and the chunk-6 dialog specs)

```ts
import { mount, type VueWrapper } from '@vue/test-utils'

function mountDialog(props: { show: boolean; /* ... */ }) {
  // attachTo: document.body — the wrapper still tracks the mount
  // target, but querying the DOM via document.querySelector now
  // finds the teleported content as a sibling of the mount target.
  return mount(MyDialog, { props, attachTo: document.body })
}

afterEach(() => {
  // attachTo: document.body leaves the teleported DOM in
  // document.body between tests. Clean up so the next test sees
  // a fresh tree.
  wrapper?.unmount()
  wrapper = null
  // Defensive: force-remove any leftover teleported nodes
  document.querySelectorAll('[data-testid="my-dialog"]').forEach(el => el.remove())
})

it('emits close when the backdrop is clicked', async () => {
  const w = mountDialog({ show: true })
  await w.vm.$nextTick()
  const card = document.querySelector<HTMLElement>('[data-testid="my-card"]')!
  card.click()                              // native .click() on the teleported element
  expect(w.emitted('close')).toBeDefined()  // emitted() still works — it tracks the vm
})
```

## Key Points

1. **`mount({ attachTo: document.body })`** — required. Without it, even `document.querySelector` may miss the teleported content because the mount target is a detached div.

2. **`document.querySelector('[data-testid=...]')`** — for DOM assertions on teleported content. NOT `wrapper.find(...)`.

3. **`element.click()`** (native) — to interact with teleported elements. NOT `wrapper.find(...).trigger('click')`. The trigger() method walks from `wrapper.element` and won't find teleported nodes.

4. **`wrapper.emitted('foo')`** — still works! `emitted()` tracks the component instance, not the DOM tree, so it sees events regardless of where the DOM lives.

5. **Always `wrapper?.unmount()` + force-remove the testid in `afterEach`** — the teleported DOM survives between tests and causes bleed (duplicate elements, lingering event listeners).

6. **Lifecycle caveat — `watch(() => props.show, ...)` only fires on CHANGE**: if the watcher seeds form state on `show` going true, the test must mount with `show: false` then `setProps({ show: true })`. Mounting with `show: true` from the start does NOT fire the watcher (the value didn't change). See `EditRoutineDialog.spec.ts:openEditDialog` for the pattern.

## Why this is project-specific
The ImagePreview spec at `imagePreview.spec.ts` already follows this exact pattern. The Chunk 6 dialogs (AddTaskPickerDialog, AddRoutineDialog, EditRoutineDialog) needed the same treatment — they all use `<Teleport to="body">`. The plan's spec code used `wrapper.find` / `setValue` / `trigger` which would silently work for non-Teleport components but fail for these.

## How to verify
If `wrapper.find('[data-testid=...]')` returns empty:
1. Check if the component template starts with `<Teleport to="body">` — search the file
2. If yes, switch the test to `attachTo: document.body` + `document.querySelector`
3. Use native `element.click()` for interactions
4. Add the afterEach cleanup pattern

## Related
- `imagePreview.spec.ts:24-29` — the canonical `mountPreview` helper using this pattern
- `AddTaskPickerDialog.spec.ts`, `AddRoutineDialog.spec.ts`, `EditRoutineDialog.spec.ts` — three new specs following this pattern (Chunk 6)

