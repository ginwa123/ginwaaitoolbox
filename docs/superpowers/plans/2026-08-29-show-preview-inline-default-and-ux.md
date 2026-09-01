# `show_preview` inline UX — make side the default, polish the inline path

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop rendering `show_preview` agent tool outputs inline inside the chat bubble by default. The chat column is too narrow for the kind of content the LLM produces (HTML pages, dashboard mocks, kanban cards, long markdown tables) — the iframe gets crushed, the horizontal scrollbar overlaps the content, and the user has to click "Open preview panel" anyway. Flip the default back to **`side`** (the right-side panel) and polish the inline path so the users who **opt in** to inline get a clean experience with a prominent "Open in side panel" CTA above the scrollbar.

**Architecture (one-liner):** Flip `DEFAULT_MODE` in `usePreviewDisplayMode.ts` from `'inline'` back to `'side'` (matches the original 2026-08-06 spec at line 34; someone flipped it later without re-running the spec). Keep the toggle, keep the inline renderer, but stop forcing it on every new user. Polish the inline path with two surgical UI fixes: (1) move the floating "↗ Open full" button out of the iframe's top-right corner (where it overlaps content) into a centered CTA strip **below** the iframe; (2) give the iframe a real, non-overlapping horizontal scrollbar when the content is wider than the chat column.

**Tech Stack:** Vue 3 (`<script setup>`), TypeScript, `@vue/test-utils` + Vitest. No backend changes, no migration, no Zig changes, no new dependencies. localStorage persists the user's choice — anyone who already opted into inline keeps their setting.

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/show-preview-inline-default` on branch `worktree/show-preview-inline-default` (per project rule).

---

## Background — what the user saw (verified 2026-08-29)

The screenshots in the kanban card `task_1787988286635_2` show two states:

1. **Chat bubble with the inline preview** — the iframe is constrained to the chat column width (~600px), the inner HTML page is designed for ~1200px, and the browser's horizontal scrollbar inside the iframe overlaps the rightmost column of the kanban mockup. The "↗ Open full" floating button in the iframe's top-right corner is barely visible behind the content. The text wraps awkwardly mid-word where the iframe narrows.

2. **The side panel after clicking "Open preview panel"** — the same content is rendered in a 480px+ dedicated column (resizable up to full viewport) with a clean tab strip, proper scrollbars, and the full preview id visible. This is what the user actually wanted.

The user said "show preview inline is bad" — they want the side panel as the default.

## Root cause

`src/apps/desktop/src/composables/usePreviewDisplayMode.ts:37`:

```ts
const DEFAULT_MODE: PreviewDisplayMode = 'inline'
```

The 2026-08-06 spec (`docs/superpowers/specs/2026-08-06-show-preview-display-mode-design.md`, Decision log line 34) explicitly says:

> **Default mode is `side`** | Matches current behavior — every existing user keeps what they have today. Backwards compatible.

Someone flipped the default after the spec merged (no spec update recorded). The current default is `'inline'`, which means every new user gets the broken-looking chat-bubble iframe first. The `localStorage` fallback in the spec kept the toggle alive for users who opted out — but new users see the bad path.

The inline renderer itself (`PreviewContentRenderer.vue:315-348`) is also rough in two ways:

- The floating "↗ Open full" button at `top-1 right-1` (line 343) sits **on top of** the iframe's content. For HTML pages with their own header or top-right UI, the button covers it.
- The iframe's `w-full` plus `max-w-full` on the container forces the iframe to be **at most** the chat column's width. When the inner content is wider than that, the browser injects a horizontal scrollbar INSIDE the iframe — and the scrollbar overlaps the content (no padding reserved on the bottom of the iframe for the scrollbar reservation).

Both polish issues are independent of the default — they matter for users who DO opt into inline.

---

## User-visible changes

1. **`show_preview` defaults to the side panel.** A new user (no localStorage entry) opens the chat, the LLM emits a `show_preview` with a wide HTML page → the right-side panel appears with the preview rendered at full panel width, no horizontal scrollbar inside the iframe, the tab strip is visible, the user can resize the panel. The chat bubble shows just the small header card (`show_preview → Migration Plan · 11 KB ✓`), the same as every other tool output (`read_file`, `bash`, `update_plan`).

2. **Inline rendering is still available** — the existing toggle in the panel header (`PreviewSidePanel.vue:239-267`) flips the mode to inline; the new floating "📋 Open preview panel" button (already in `ChatView.vue:3597-3607`) flips it back to side. Anyone who has `localStorage['nalar-preview-display-mode'] === 'inline'` already is **unaffected** — the change is only for new users and for the default.

3. **Inline renderer has a centered CTA strip instead of a floating-corner button.** When the inline iframe is mounted, a small horizontal CTA strip renders BELOW the iframe (not inside it) with:
   - "↗ Open in side panel" button (primary) — same handler as the existing `@open` emit, opens the side panel.
   - A dim "Preview wider than chat — scroll for full content" hint that appears only when the inner content's reported width exceeds the iframe's rendered width (detected via the existing postMessage protocol — extend it to also report `width`).

4. **Inline iframe gets a clean horizontal scrollbar.** `PreviewContentRenderer.vue` adds `overflow-x: auto` style on the iframe's container so the horizontal scrollbar (when content is too wide) appears OUTSIDE the iframe content area, not overlapping it. The iframe itself keeps `sandbox="allow-scripts"` (no change — security).

---

## Global Constraints

- **Cross-platform**: every change MUST work on Linux, macOS, AND Windows.
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` / `indexOf(u8, source, ...)` patterns.
- **No port 8081**: smoke tests use port 8080 (NOT 8081).
- **Behavioural Vue tests use `@vue/test-utils` `mount` with `setActivePinia(createPinia())`** in `beforeEach`. Re-install the localStorage stub every test.
- **TDD discipline**: every implementation task starts with a failing test, then minimal code to make it pass, then a commit.
- **Surgical patches**: don't refactor `PreviewContentRenderer.vue` wholesale — change only the 4 sites listed in the file map. Don't touch any backend, migration, or Zig code.
- **`prefers-reduced-motion`**: the CTA strip's hover transition MUST be suppressed under `prefers-reduced-motion: reduce` (same pattern as `SessionSlider.vue`).
- **No new dependencies** — everything we need (`@vue/test-utils`, `vitest`, `marked`) is already in `package.json`.

---

## File map

| File | Action | Why |
|---|---|---|
| `src/apps/desktop/src/composables/usePreviewDisplayMode.ts` | EDIT (1 line) | Change `DEFAULT_MODE` from `'inline'` back to `'side'` to match the original spec |
| `src/apps/desktop/src/composables/__tests__/usePreviewDisplayMode.spec.ts` | EDIT | Update the 3 test cases that hard-code `'inline'` as the default (`it('defaults to "inline"…`, `setMode("side") flips back`, `SSR-safe`) to expect `'side'`. Document the default flip in a comment block above each touched test. |
| `src/apps/desktop/src/components/preview/PreviewContentRenderer.vue` | EDIT (3 sites) | (a) Move the floating "Open full" button OUT of the iframe corner — render a CTA strip BELOW the iframe container instead. (b) Add `overflow-x: auto` to the iframe container so the horizontal scrollbar doesn't overlap content. (c) Extend the auto-resize postMessage protocol to also report `width` so the CTA strip can show the "wider than chat" hint when the inner content overflows. |
| `src/apps/desktop/src/__tests__/PreviewContentRenderer.spec.ts` | EDIT + ADD | (a) Update tests that reference the floating button position (`data-testid="preview-open-full-button"` now lives OUTSIDE the iframe). (b) Add 3 new tests: (i) CTA strip renders below iframe for inline + html variant; (ii) CTA strip absent for side variant; (iii) iframe container has `overflow-x: auto`. |
| `src/apps/desktop/src/components/tool_outputs/ShowPreview.vue` | NO CHANGE | The inline body container (`data-testid="show-preview-inline-content"`) keeps mounting the renderer with `variant="inline"`. The CTA strip + scrollbar polish happens inside the renderer. |
| `src/apps/desktop/src/components/views/ChatView.vue` | NO CHANGE | The `setMode('side')` restore button at line 3597-3607 already works for the new default. The `watch(isInline)` at line 583 already handles the auto-dismiss + restore when the user toggles. |
| `docs/SPEC.md` §10.2 | EDIT | Add PR entry for this fix |
| `AGENTS.md` (changelog) | EDIT | Append "### 2026-08-29: show_preview inline default → side + inline polish" entry |

Total: **4 file edits + 2 docs + 0 new files**. Smallest possible change that fixes the user's bug.

---

## Task 1 — Flip `DEFAULT_MODE` back to `'side'` (TDD)

**Why:** Every other task is polish on the inline path; this one is the actual fix. New users stop landing on the bad default.

**Files:**
- `src/apps/desktop/src/composables/__tests__/usePreviewDisplayMode.spec.ts` — EDIT (3 tests)
- `src/apps/desktop/src/composables/usePreviewDisplayMode.ts` — EDIT (1 line)

### Step 1.1: Update the 3 failing tests

The composable's default test (line 49) currently reads:

```ts
it('defaults to "inline" when localStorage is empty (matches other tool outputs)', () => {
```

…and the SSR-safe test (line 91) and the `setMode("inline") flips back` test (line 69) all hard-code the default. Change them all to `'side'` and update the test name + comment to reflect the 2026-08-29 flip.

Open- `src/apps/desktop/src/composables/__tests__/usePreviewDisplayMode.spec.ts`:

1. Line 49 test name → `it('defaults to "side" when localStorage is empty (side panel is the better home for show_preview)', ...)`. Update `expect(mode.value).toBe('inline')` → `expect(mode.value).toBe('side')`. Add a 1-line comment above the test referencing the kanban task + the 2026-08-06 spec.
2. Line 69 (`setMode("inline") flips back`) → keep the test but flip the starting assertion: `expect(mode.value).toBe('side')` → still side at start, flip to inline via `setMode('inline')` → still asserts `inline` at end. The localStorage assertion stays `expect(localStorage.getItem(STORAGE_KEY)).toBe('inline')`. No semantic change — just adjust the start value.
3. Line 79 (`falls back to "inline" when localStorage contains an invalid value`) → keep as-is (the FALLBACK for an invalid stored value should still be `'side'` — update the assertion if it currently says inline. Re-read: line 82 says `expect(mode.value).toBe('inline')`. Change to `'side'`.
4. Line 85 (empty string fallback) → same fix: line 87 `expect(mode.value).toBe('inline')` → `'side'`.
5. Line 91 (`SSR-safe: returns "inline" without throwing`) → rename to `SSR-safe: returns "side" without throwing`. Line 105: `expect(mode.value).toBe('inline')` → `'side'`. Line 108: `setMode('side')` → keep, but the start assertion now reads `'side'` at line 105 already; the next assertion at line 109 `expect(mode.value).toBe('side')` after `setMode('side')` is a tautology — change the test to actually flip: `setMode('inline'); expect(mode.value).toBe('inline')`.

Run: `cd src/apps/desktop && pnpm test:unit -- usePreviewDisplayMode.spec` — expect **FAIL** (the production code still defaults to `'inline'`).

### Step 1.2: Flip `DEFAULT_MODE`

Edit `src/apps/desktop/src/composables/usePreviewDisplayMode.ts:37`:

```ts
// BEFORE
const DEFAULT_MODE: PreviewDisplayMode = 'inline'

// AFTER
// 2026-08-29: flipped from 'inline' back to 'side' (matches the original
// 2026-08-06 spec decision). Inline rendering was crushing the iframe
// in the narrow chat column — users had to click "Open preview panel"
// anyway. New users land on the side panel; existing inline users keep
// their localStorage value. Kanban: task_1787988286635_2.
const DEFAULT_MODE: PreviewDisplayMode = 'side'
```

Run: `cd src/apps/desktop && pnpm test:unit -- usePreviewDisplayMode.spec` — expect **PASS**.

### Step 1.3: Sanity-check the consumers

`PreviewSidePanel.vue:189` and `ChatView.vue:580` both call `usePreviewDisplayMode()` and read `mode`/`isInline`. Both already gate behaviour on `isInline.value` (not on the default). The flip changes nothing for them — they continue to work because the consumer code already branches correctly.

Quick smoke: `cd src/apps/desktop && pnpm test:unit 2>&1 | tail -n 10` — expect all green. No regressions in existing components.

### Step 1.4: Commit

```bash
git add src/apps/desktop/src/composables/usePreviewDisplayMode.ts \
        src/apps/desktop/src/composables/__tests__/usePreviewDisplayMode.spec.ts
git commit -m "show_preview default mode flips back to 'side'

Inline rendering was crushing wide HTML previews in the narrow chat
column — horizontal scrollbar overlapped content, the floating
'Open full' button covered the page's own header, and users had to
click 'Open preview panel' anyway. Side panel is the right home for
show_preview (the original 2026-08-06 spec said so; someone flipped
the default to inline after that spec merged).

Behaviour change is localStorage-only: existing inline users keep
their setting (no migration). New users land on side.

Kanban: task_1787988286635_2"
```

---

## Task 2 — Move the "Open full" button from iframe-corner to a CTA strip below the iframe (TDD)

**Why:** Even for users who opt into inline, the floating-corner button overlaps the iframe's content. Move it OUT of the iframe's bounding box to a small CTA strip BELOW the iframe. Same handler, same data-testid, just a new DOM position.

**Files:**
- `src/apps/desktop/src/__tests__/PreviewContentRenderer.spec.ts` — EDIT (3 tests)
- `src/apps/desktop/src/components/preview/PreviewContentRenderer.vue` — EDIT (move button)

### Step 2.1: Write the failing tests

Open `src/apps/desktop/src/__tests__/PreviewContentRenderer.spec.ts`. Three existing tests reference the button position:

- **Line 230** (`renders an "Open full preview" button next to the html iframe`) — keeps working but its DOM position assertion is updated: the button is no longer the iframe's absolute child; it's a sibling under the iframe container. Test passes when the testid exists anywhere in the rendered DOM. Likely needs no edit, but verify.
- **Line 242** (`does NOT render the "Open full preview" button in side-panel variant`) — keeps working.
- **Line 253** (`does NOT render the "Open full preview" button for non-html content types`) — keeps working.

Add 3 new failing tests at the bottom of the `describe('variant: inline')` block:

```ts
it('places the "Open full preview" button OUTSIDE the iframe (below it, not absolute-corner-overlapping)', () => {
  const wrapper = mount(PreviewContentRenderer, {
    props: { contentType: 'html', args: { content: '<h1>x</h1>' }, variant: 'inline' },
  })
  // The button must NOT be a child of the iframe (it was, as absolute top-right).
  const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]').element as HTMLIFrameElement
  const button = wrapper.find('[data-testid="preview-open-full-button"]').element as HTMLElement
  expect(iframe.contains(button)).toBe(false)
})

it('renders a CTA strip wrapper ([data-testid="preview-inline-cta"]) around the button', () => {
  const wrapper = mount(PreviewContentRenderer, {
    props: { contentType: 'html', args: { content: '<h1>x</h1>' }, variant: 'inline' },
  })
  const cta = wrapper.find('[data-testid="preview-inline-cta"]')
  expect(cta.exists()).toBe(true)
  // Button is inside the CTA strip.
  expect(cta.find('[data-testid="preview-open-full-button"]').exists()).toBe(true)
})

it('does NOT render the CTA strip in side variant (panel already shows the content full-width)', () => {
  const wrapper = mount(PreviewContentRenderer, {
    props: { contentType: 'html', args: { content: '<h1>x</h1>' }, variant: 'side' },
  })
  expect(wrapper.find('[data-testid="preview-inline-cta"]').exists()).toBe(false)
})
```

Run: `cd src/apps/desktop && pnpm test:unit -- PreviewContentRenderer.spec` — expect **3 FAIL** (CTA strip data-testid doesn't exist yet).

### Step 2.2: Move the button + wrap it in a CTA strip

Edit `src/apps/desktop/src/components/preview/PreviewContentRenderer.vue`. The current button (lines 340-347) lives INSIDE the `<div data-testid="preview-html-container">` with `class="absolute top-1 right-1 …"`. Change the structure:

```vue
<!-- BEFORE (lines 315-348 — abbreviated for clarity) -->
<div data-testid="preview-html-container" :class="…">
  <iframe … />
  <button
    v-if="isInline"
    type="button"
    class="absolute top-1 right-1 …"
    data-testid="preview-open-full-button"
    @click.stop="openFullPreview"
  >↗ Open full</button>
</div>

<!-- AFTER -->
<div data-testid="preview-html-container" :class="…">
  <iframe … />
</div>
<!-- CTA strip — lives OUTSIDE the iframe container so it can't overlap
     the iframe's content. Only rendered for inline + html (other content
     types have their own affordances; image is already responsive). -->
<div
  v-if="isInline"
  class="flex items-center justify-between gap-2 mt-1 text-[0.65rem] font-mono text-[var(--semantic-text-muted)]"
  data-testid="preview-inline-cta"
>
  <button
    type="button"
    class="px-2 py-1 rounded border border-[var(--color-border)] bg-[var(--semantic-card-bg)] hover:bg-[var(--color-violet)]/20 hover:border-[var(--color-violet)]/60 hover:text-[var(--color-violet)] text-[var(--semantic-text)] cursor-pointer transition-colors"
    data-testid="preview-open-full-button"
    title="Open this preview in the side panel at full width"
    @click.stop="emitOpenInSidePanel"
  >↗ Open in side panel</button>
  <span
    v-if="overflowsHorizontally"
    class="italic"
    data-testid="preview-inline-overflow-hint"
    title="The preview content is wider than this chat column"
  >Preview wider than chat — scroll for full content</span>
</div>
```

Then add the `emitOpenInSidePanel` and `overflowsHorizontally` wiring in `<script setup>`:

```ts
// ─── Emit "open in side panel" — inline CTA button ────────────────────
//
// Replaces the old floating-corner "Open full" button. Same effect:
// the parent focuses the side panel for this preview (ChatView.vue's
// `openPreviewForMessage` handler — wired in ShowPreview.vue's @open
// emit). We emit a NEW event name 'open-in-side-panel' (rather than
// reusing 'open') so a future caller can distinguish "open in new
// tab" from "open in side panel" if needed; for now both events do
// the same thing.
const emit = defineEmits<{
  'open-in-side-panel': []
}>()
function emitOpenInSidePanel() {
  emit('open-in-side-panel')
}

// ─── Overflow hint (inline only) ─────────────────────────────────────
//
// The auto-resize postMessage protocol (see AUTO_RESIZE_SCRIPT) only
// reports the iframe's scrollHeight. Extend it to also report
// scrollWidth — when scrollWidth > the iframe's clientWidth, the
// content is wider than the chat column and the user needs the hint
// (and the horizontal scrollbar).
//
// We track the LAST reported overflow state via a ref; the CTA strip
// reads it via a computed.
const overflowsHorizontally = ref(false)
function onIframeMessage(e: MessageEvent) {
  if (
    !e.data ||
    typeof e.data !== 'object' ||
    e.data.source !== 'show-preview-auto-resize' ||
    typeof e.data.height !== 'number'
  ) {
    return
  }
  const iframe = iframeRef.value
  if (!iframe) return
  const clampedH = Math.max(MIN_IFRAME_HEIGHT, Math.min(MAX_IFRAME_HEIGHT, e.data.height))
  iframe.style.height = `${clampedH}px`
  // Width hint — only show if the iframe's own clientWidth is the
  // bottleneck (chat column). Guard against the iframe reporting 0
  // before it has laid out.
  if (typeof e.data.width === 'number' && iframe.clientWidth > 0) {
    overflowsHorizontally.value = e.data.width > iframe.clientWidth + 1
  }
}
```

…and update the existing `onIframeMessage` (line 98-112) to the new shape. Add `width` to the `AUTO_RESIZE_SCRIPT` postMessage payload:

```js
// BEFORE (lines 141-152)
var h = Math.max(
  de ? de.scrollHeight : 0,
  body ? body.scrollHeight : 0,
  de ? de.offsetHeight : 0,
  body ? body.offsetHeight : 0
);
parent.postMessage({ source: REPORT_SOURCE, height: h }, '*');

// AFTER
var h = Math.max(
  de ? de.scrollHeight : 0,
  body ? body.scrollHeight : 0,
  de ? de.offsetHeight : 0,
  body ? body.offsetHeight : 0
);
var w = Math.max(
  de ? de.scrollWidth : 0,
  body ? body.scrollWidth : 0,
  de ? de.offsetWidth : 0,
  body ? body.offsetWidth : 0
);
parent.postMessage({ source: REPORT_SOURCE, height: h, width: w }, '*');
```

### Step 2.3: Wire the new event in `ShowPreview.vue`

`ShowPreview.vue` already has `@click="handleClick"` on the card and an `emit('open', ...)` in side mode. The CTA button in the renderer now emits `'open-in-side-panel'` (a new event) — `ShowPreview.vue` should listen for it AND propagate it up via the same `open` event so the existing parent (`ChatView.vue:3093`) keeps working without changes.

Edit `ShowPreview.vue` to add the listener:

```vue
<PreviewContentRenderer
  :content-type="resolvedContentType"
  :args="rendererArgs"
  variant="inline"
  @open-in-side-panel="emit('open', messageId)"
/>
```

(Vue 3's `$emit` shorthand — `emit` is already destructured at line 80 from `defineEmits`.)

### Step 2.4: Update existing PreviewContentRenderer tests for the new button position

Re-read each test in `PreviewContentRenderer.spec.ts` that references the button. The data-testid `preview-open-full-button` is preserved, so the existing tests still pass. The new tests added in Step 2.1 verify the position change.

Run: `cd src/apps/desktop && pnpm test:unit -- PreviewContentRenderer.spec` — expect **PASS**.

Run: `cd src/apps/desktop && pnpm test:unit -- ShowPreview.spec` — expect **PASS** (the `@open` event still fires; the new `open-in-side-panel` event is just another path to the same handler).

### Step 2.5: Commit

```bash
git add src/apps/desktop/src/components/preview/PreviewContentRenderer.vue \
        src/apps/desktop/src/components/tool_outputs/ShowPreview.vue \
        src/apps/desktop/src/__tests__/PreviewContentRenderer.spec.ts
git commit -m "show_preview inline: move 'Open in side panel' out of iframe corner

The floating '↗ Open full' button was absolute-positioned at the
top-right INSIDE the iframe's bounding box, where it overlapped the
preview content (especially pages with their own top-right UI).

Move it OUT of the iframe — render a small CTA strip BELOW the
iframe container. Same handler (opens the preview in the side panel
via the existing @open event path), same data-testid, just a new
DOM position. The CTA strip also shows a 'Preview wider than chat —
scroll for full content' hint when the iframe's inner content is
wider than the chat column (detected via the postMessage protocol
extended to also report width).

New event: 'open-in-side-panel' (emitted by the renderer, mapped
to the existing 'open' event by ShowPreview.vue). No parent
(ChatView.vue) changes — the @open handler at line 3093 still
works.

No behavioural change for users already on 'side' default.

Kanban: task_1787988286635_2"
```

---

## Task 3 — Add `overflow-x: auto` to the iframe container (TDD)

**Why:** When the inner content is wider than the iframe, the browser's horizontal scrollbar appears INSIDE the iframe's content area and overlaps the rightmost column. Adding `overflow-x: auto` to the WRAPPING container moves the scrollbar reservation to a dedicated gutter OUTSIDE the iframe, so the content is never overlapped.

Wait — actually the iframe IS the scrollable element here. The container has no overflow. Let me reconsider.

The cleanest fix is on the iframe itself: `overflow: hidden` by default (no outer scrollbar) + a JS-driven scroll position when the inner content overflows. But that's heavy.

**Simpler fix that matches the spirit:** Add a thin `padding-right` to the iframe container equal to the browser's typical scrollbar width (~12-15px) when overflowsHorizontally is true. The browser reserves the bottom scrollbar gutter by default (we already see it in the screenshots). The horizontal scrollbar that overlaps the content is INSIDE the iframe — that's because the iframe has `width: 100%` of its container, and the iframe's content is wider, so the iframe's own body scrolls horizontally.

**Actual root cause:** The iframe's body element has horizontal overflow; the iframe element itself doesn't reserve space for a scrollbar because the browser doesn't know the iframe's content is overflowing until after layout. The fix is to give the iframe a `min-width` larger than the chat column when the content needs it — but that breaks the chat column constraint.

**Pragmatic fix:** Accept that the iframe's horizontal scrollbar is inside the iframe (that's how all browsers work) and mitigate the visual collision by ensuring the iframe has a small **bottom padding** so the scrollbar (which lives at the bottom-right of the iframe when it can't fit horizontally either) doesn't visually collide with the content above it. The `body { padding-bottom: 12px }` rule in the auto-resize `<style>` tag already does this — verify it's still there (line 238: `padding:0;` … actually wait, the rule is `margin:0;padding:0;background:#fff;` — it does NOT add a bottom padding).

**Final decision:** Skip this task. The fix doesn't work cleanly (scrollbar reservation inside an iframe is a browser limitation, not something CSS can fix from outside). The CTA strip + overflow hint from Task 2 is enough — when the user sees the "Open in side panel" button BELOW the iframe, the affordance is discoverable, and the user understands to click it. Move on.

Mark this task as **NOT DOING** in the commit log with a one-paragraph explanation. The polish lands in Task 2 alone.

---

## Task 4 — Update docs (SPEC + AGENTS changelog)

### Step 4.1: `docs/SPEC.md`

Find the show_preview section (search for "show_preview" in §10.2 — PR index). Add an entry:

```
### 2026-08-29 — `show_preview` inline UX fix

**Kanban**: task_1787988286635_2

**What changed**: The default rendering mode for `show_preview` agent tool
outputs is now `'side'` again (was incorrectly flipped to `'inline'`).
Inline rendering is still available via the existing toggle, but the
floating-corner "Open full" button was moved OUT of the iframe to a
CTA strip below it (no more content overlap). Existing inline users
keep their setting (localStorage).
```

### Step 4.2: `AGENTS.md` changelog

Append at the bottom of `## 📜 Recent changes (changelog)` (search for the heading — it's near the top of the file):

```markdown
- **`show_preview` default flips back to side + inline CTA strip below iframe (2026-08-29)**: Two surgical polish fixes for `task_1787988286635_2`. (1) `usePreviewDisplayMode.DEFAULT_MODE` flips from `'inline'` back to `'side'` — the 2026-08-06 spec said side, someone flipped it after merging, and the inline path was crushing the iframe in the narrow chat column with a horizontal scrollbar that overlapped content. New users land on the side panel; existing inline users keep their localStorage value (no migration). (2) The floating "↗ Open full" button inside the iframe's top-right corner is replaced by a small CTA strip BELOW the iframe container with "↗ Open in side panel" (primary) + an optional "Preview wider than chat — scroll for full content" hint (visible only when the iframe reports its inner content is wider than the chat column via the existing postMessage protocol, extended to also report `width`). No new files, 4 file edits (1 component + 1 helper + 2 test files), no backend/migration/Zig changes. `pnpm test:unit`: all green.
```

### Step 4.3: Commit

```bash
git add docs/SPEC.md AGENTS.md
git commit -m "docs: SPEC + changelog entry for show_preview inline UX fix"
```

---

## Verification (final)

Run the full trio:

```bash
cd /home/ginwa/ginwaaitoolbox

# Frontend (type-check + tests + build)
cd src/apps/desktop
timeout 120 pnpm run build 2>&1 | tail -n 20           # vue-tsc --build
timeout 180 pnpm test:unit 2>&1 | tail -n 10            # all unit tests

# Backend (no changes expected, but still verify)
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Eyeball smoke on port 8080 (NOT 8081) — `zig build nalar-desktop` + click through the chatview:

1. Open a fresh browser profile (no localStorage).
2. Trigger a `show_preview` with HTML content (e.g. an HTML page from a kanban design) — the side panel should appear with the preview, NOT the inline iframe.
3. Click the "Inline" button in the panel header → mode flips, panel hides, content renders inline in the chat.
4. Verify the CTA strip "↗ Open in side panel" is BELOW the iframe (not overlapping its content).
5. Click the CTA → mode flips back to side, panel reappears.
6. Reload the page → the user's mode preference persists (the change in Task 1 only affects the default; existing localStorage values are preserved).

If all green, **move the kanban task to `in_review_task`** (per the kanban workflow in the chat context — this signals "ready for human review / PR").

---

## Out of scope (deferred)

- **Full chat-column widening on inline preview mount** — would require restructuring the AppLayout flex container; the cost (other chat UI breaks) doesn't justify the benefit when the side panel is one click away.
- **Per-call LLM `display_mode` parameter** — explicitly rejected by the 2026-08-06 spec; UX-driven, not LLM-driven.
- **Animation when switching modes** — abrupt flip is fine for v1.
- **Fixing the iframe's horizontal scrollbar overlap from the OUTSIDE** — browser limitation; mitigated by the CTA strip + overflow hint.
- **Auto-opening the side panel when a new preview arrives** — explicitly rejected by the 2026-08-06 spec (was disruptive).

---

## Pitfalls (encountered during research / likely during execution)

- **`localStorage` reset in tests** — the existing tests pin the default via `localStorage.setItem(STORAGE_KEY, 'inline')` in `beforeEach`. Step 1.1's updates must change those to `'side'`. Forgetting one means a test that depended on the old default silently passes with stale localStorage.
- **The new `open-in-side-panel` event** — don't accidentally replace the existing `@open` emit. They're parallel paths to the same handler. `ShowPreview.vue` listens to the new event AND re-emits `'open'` so `ChatView.vue:3093` is unchanged.
- **AUTO_RESIZE_SCRIPT change is wire-format** — the parent's `onIframeMessage` now expects `e.data.width`. Old iframes (or stale srcdocs in tests) that post `{height}` only will not trigger the overflow hint; the existing tests that dispatch `{source, height}` still pass (the width check is gated by `typeof e.data.width === 'number'`).
- **Vue 3 `<script setup>` reactivity** — `overflowsHorizontally` is a `ref`, not a `computed`, because it's mutated by a side-effect (postMessage handler). Don't replace with `computed` — it'll be a one-shot read at component creation time.
- **`prefers-reduced-motion`** — the CTA strip's hover transition uses `transition-colors`. Wrap with `@media (prefers-reduced-motion: reduce) { .transition-colors { transition: none; } }` in the scoped style block. Same pattern as `SessionSlider.vue:152-156`.
- **Don't touch the `show_preview.zig` backend** — the LLM-controlled `display_mode` param was explicitly rejected. No backend changes at all in this plan.
- **Don't add a new Pinia store** — this is a localStorage-only change. The existing `usePreviewDisplayMode` composable is enough.

---

## Verification checklist (before "done")

- [ ] All 3 default-flip tests in `usePreviewDisplayMode.spec.ts` updated and passing
- [ ] `DEFAULT_MODE` flipped to `'side'` with the kanban-task comment
- [ ] 3 new tests in `PreviewContentRenderer.spec.ts` passing (CTA strip + button-not-inside-iframe + side-variant-no-CTA)
- [ ] Existing `ShowPreview.spec.ts` + `chatViewShowPreviewBubble.spec.ts` still pass (no `@open` contract change)
- [ ] `pnpm test:unit` — all green, no regressions
- [ ] `pnpm run build` — vue-tsc clean
- [ ] `zig build test --summary all` — backend untouched, all green
- [ ] Manual smoke on port 8080: new user (no localStorage) → side panel appears by default; existing inline user → keeps inline setting; CTA strip "↗ Open in side panel" visible BELOW the iframe (not overlapping content) for opt-in inline users
- [ ] `AGENTS.md` changelog entry appended
- [ ] `docs/SPEC.md` §10.2 PR entry added
- [ ] Kanban task moved to `in_review_task` column