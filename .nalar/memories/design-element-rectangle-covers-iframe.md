# design — plain rectangle div covers iframe content (z-stack via DOM order)

## Symptom

In the design canvas, elements with a `file_path` show up as a blank
white rectangle even though the API returns real HTML for them and
the file at `.nalar/design/<page>/<element>.html` renders correctly
when opened directly in a browser. The user sees only the element's
`fill` color (typically `#ffffff`) covering the entire element
bounding box — no chat messages, no top-bar buttons, no input-area
content. A header label and small icons may be visible because they
are positioned outside or above the masked area, but the rendered
iframe HTML is invisible.

## Root cause

`src/apps/desktop/src/components/design/DesignElement.vue` renders
the iframe preview inside an absolutely-positioned wrapper
(`<div class="absolute inset-0 pointer-events-none overflow-hidden">`)
and then renders a SECOND absolutely-positioned "plain rectangle"
fallback div (`<div class="absolute inset-0 pointer-events-none">`)
AFTER it in the source.

Both divs use `position: absolute; inset: 0` and neither sets a
`z-index`. CSS stacking rules say: when stacking contexts are equal,
**DOM order wins — later siblings paint on top**. So the plain
rectangle paints **on top of** the iframe wrapper, not behind it as
the inline comment claimed.

The plain rectangle has
`backgroundColor: element.fill || 'rgba(127, 127, 127, 0.05)'`.
For elements with `fill="#ffffff"` (chat-area, top-bar, input-area,
most light-mode mocks), this is a **solid white rectangle** that
fully covers the iframe content. The author had added
`pointer-events: none` so click events pass through (which works)
but `pointer-events` only affects pointer events — **not visual
rendering** — so the bug was silent.

The inline comment on lines 466-481 of the old file even acknowledged
"this div is rendered after the iframe wrapper in DOM order, which
puts it ON TOP in the stacking context" but only used that knowledge
to add `pointer-events-none`. The visual coverage was unaddressed.

## Fix

Add `v-if="!htmlBody && !isLoadingHtml"` to the plain rectangle div
in `DesignElement.vue` so it only renders when there's NO iframe to
cover (legacy elements with no `file_path`, or HTML fetch failures).

The `!isLoadingHtml` half is required too — otherwise the rectangle
(being DOM-after the iframe wrapper) would cover the "loading…"
text rendered inside the wrapper below it.

```vue
<div
  v-if="!htmlBody && !isLoadingHtml"
  class="absolute inset-0 pointer-events-none"
  :style="{
    backgroundColor: element.fill || 'rgba(127, 127, 127, 0.05)',
    borderRadius: `${element.corner_radius}px`,
    border: element.stroke
      ? `${element.stroke_width}px solid ${element.stroke}`
      : '1px dashed rgba(127, 127, 127, 0.4)',
  }"
/>
```

## Pitfalls

- **Don't try `z-index` instead of `v-if`** — `z-index` only works
  inside the same stacking context; both divs are direct children of
  `position: absolute` element, so they'd both enter the same
  context. Adding `z-index: -1` to the rectangle would put it
  BEHIND the canvas itself (behind the design-element wrapper, even
  behind the canvas background), not just behind the iframe.
  `v-if` is the cleanest fix because it expresses the actual intent:
  "the rectangle is a fallback, only show it when the iframe is
  absent."
- **Don't hide the rectangle ONLY when `htmlBody` is set** — that
  hides it for loaded iframes (good) but keeps it shown during
  loading, where it would cover the "loading…" text inside the
  wrapper below it. The `&& !isLoadingHtml` half is required.
- **`pointer-events-none` is still needed when this div IS
  rendered** (legacy / failed cases) — without it, the dashed-
  outline div would capture drag/resize/select clicks that should
  reach the parent `DesignElement` wrapper.
- **`element.type === 'image'` and `element.type === 'text'` still
  render their own dedicated content divs** INSIDE the element
  wrapper, not via iframe. Those content divs are siblings of the
  iframe wrapper + plain rectangle, both `absolute inset-0`. Check
  that the order is OK for those paths if you move things around.
- **The iframe's `srcdoc` is prepended with
  `<style>html,body{margin:0;height:100%;}</style>`** to make
  percentage-based layouts inside the user's HTML resolve correctly
  (see `DesignElementPreview.vue`). Without the preamble, every
  `height: 100%` outer div collapses to 0 and iframe contents
  disappear — a separate (but related) cause of "blank iframe".
  When in doubt, also verify the srcdoc preamble is intact.

## Verification

```bash
# 1. Type-check (must run under node, not bun — see project memory)
cd /home/ginwa/ginwaaitoolbox/src/apps/desktop
timeout 120 node node_modules/vue-tsc/bin/vue-tsc.js --build

# 2. Unit tests (vitest). The new regression test is in
#    src/__tests__/DesignElement.spec.ts:
#    "hides the plain-rectangle fallback when iframe is rendering".
timeout 60 bunx vitest run src/__tests__/DesignElement.spec.ts

# 3. Live check against the running nalar (port 8081):
#    - The Vite dev server auto-hot-reloads the change.
#    - Reload the design page in nalar-desktop (or wait ~1s for
#      HMR) — chat-area / top-bar / input-area should now render
#      their content (purple message bubble, "MiniMax-M3" button,
#      "Draft 3 alternate headlines" chips, etc.) instead of white.
```

Confirmed 2026-07-26:
- `vue-tsc --build` exits 0
- `bunx vitest run src/__tests__/DesignElement.spec.ts` 13/13 pass (was 12/12; the new regression test added 1)
- `bunx vitest run` full suite 1453/1453 pass

## Why this is hard to catch with type-check or unit tests alone

- **TypeScript / vue-tsc** doesn't care about CSS stacking order —
  the template compiles cleanly even with the bug present.
- **Static-contract tests** (the convention used elsewhere in this
  codebase — see `nalar-frontend-patterns.md`) only grep the source
  for required substrings. They don't render the component. The bug
  required reading the template structure (DOM order) and CSS rules
  (no z-index → DOM order wins) to diagnose.
- **vue-test-utils rendering** would catch it, but DesignElement
  has no behavioral render tests — only the static `*.spec.ts`
  grep tests. A real mount test that opens the design page, hits
  `getDesignElementHtml`, and asserts `iframe.contentDocument.body`
  contains the expected text would catch this regression
  immediately.

When adding a render test for DesignElement, the assertion should:
1. Set `element.file_path` to a known `.html` file.
2. Wait for `htmlBody` to populate (the fetch resolves).
3. Mount the component (or assert via a test-only render helper).
4. Assert the iframe's `srcdoc` is non-empty AND that the plain
   rectangle div is NOT in the rendered DOM (`wrapper.findAll('[class*="pointer-events-none"]').length === <expected>` after the v-if).

## Related

- `nalar-frontend-patterns.md` — `bun run build` is the type-check
  (vue-tsc); `bunx vitest run` is just the test runner. The bug
  would have been caught by either, but the existing
  static-contract test convention is too coarse to detect it.
- `DesignElementPreview.vue` — the iframe component; its `srcdoc`
  preamble `<style>html,body{margin:0;height:100%;}</style>` is a
  separate but related cause of "blank iframe" if removed.
- `src/apps/desktop/src/components/design/DesignElement.vue:466-506`
  — the fixed div + the verbose bug-fix comment that explains the
  stacking issue for future maintainers.
