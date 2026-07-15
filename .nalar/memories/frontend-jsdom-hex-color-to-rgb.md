# Frontend — jsdom Normalizes Hex Colors in inline `style` attributes to `rgb()`

When a Vue component sets an inline style with a hex color literal
(e.g. `:style="{ backgroundColor: '#22c55e' }"`), `jsdom` (the test
environment used by Vitest in this project) reads it back through
`wrapper.attributes('style')` as `rgb(34, 197, 94)`, not the
original `#22c55e`. A test that asserts the hex value with
`toMatch(/green|#22c55e/i)` will fail.

## Symptom

```
AssertionError: expected 'background-color: rgb(34, 197, 94);'
                to match /green|#22c55e|#10b981/i
```

The component is correct; the test assertion is wrong.

## Why

jsdom uses the browser CSSOM to serialize style values. Per
CSSOM spec, `getComputedStyle().backgroundColor` (and the
CSSStyleDeclaration API) returns colors in `rgb(r, g, b)` /
`rgba(r, g, b, a)` form, not the original literal. When
`@vue/test-utils` calls `element.attributes('style')`, jsdom
parses the inline style, normalizes each declaration through
the CSSOM, and re-serializes — converting `#22c55e` to
`rgb(34, 197, 94)`.

## Hex → RGB reference (Tailwind 500 colors)

- `#22c55e` (green-500) → `rgb(34, 197, 94)`
- `#ef4444` (red-500) → `rgb(239, 68, 68)`
- `#eab308` (yellow-500) → `rgb(234, 179, 8)`
- `#9ca3af` (gray-400) → `rgb(156, 163, 175)`
- `#6b7280` (gray-500) → `rgb(107, 114, 128)`
- `#10b981` (emerald-500) → `rgb(16, 185, 129)`
- `#dc2626` (red-600) → `rgb(220, 38, 38)`

## Fix

In the test, assert the `rgb()` form. Pick one of:

```ts
// Option 1: assert the exact rgb() string
expect(dot.attributes('style') ?? '').toContain('rgb(34, 197, 94)')

// Option 2: parse and assert the channel values
const style = dot.attributes('style') ?? ''
expect(style).toMatch(/background-color:\s*rgb\(\s*34,\s*197,\s*94\s*\)/)
```

The component code can keep the hex literal (more readable); only
the test needs to know about the jsdom normalization.

## When this bites

- Tests for any new status dot / colored badge / colored icon
  that asserts the inline-style color.
- Any test for a computed that returns a hex color string.
- The plan-provided tests for Chunk 7 of the task-routines
  feature (workspaceItemTaskRoutine.spec.ts) had the
  `toMatch(/green|#22c55e|...)` pattern — they failed locally
  with rgb() form, fixed by switching to `.toContain('rgb(...)')`.

## How to verify

If a test fails with "expected '...rgb(N, N, N)...' to match
/...#XXXXXX/i", the fix is to switch the test to the rgb() form
(or to `parseInt` the channels and assert the numeric values).
