# `<html>` frame: theme + height fix (chatview)

**Task:** `task_1789312493325_7` "html render" — *"is that html render why the ui bad ?"*

**Answer: yes.** The bad UI in the screenshot is the `<html>` wrapper-tag iframe
(shipped in PR #309). It rendered with a hardcoded **white** background inside the
dark Kanagawa-Dragon transcript, at the browser's default **150 px** iframe height —
so a long LLM report showed up as a white slab with its own scrollbar, in the
middle of the chat.

**Goal:** make an LLM HTML answer look like part of the transcript — the app's
card surface, no nested scrollbar, native widgets dark — without touching the
`<html>` contract, the sandbox, or the markdown path.

## Root cause (measured, not guessed)

The exact wire payload was recovered from the real DB
(`~/.config/nalar/agent.db`, `llm_history` row `1789306073475690430`, session
`task_1789301162387_3`, 3 661 chars): one prose sentence, then a single
`<html>` block holding an `h2`/`h3`/`p`/`table`/`code` report. The model used
HTML mode legitimately — the response-formatting prompt offers it.

Playwright against a DB-seeded transcript (real Chromium, real Vite, isolated
`$HOME`) measured, **pre-fix**:

| measurement | pre-fix | post-fix |
|---|---|---|
| `getComputedStyle(iframe).backgroundColor` | `rgb(255, 255, 255)` | app card surface (dark) |
| frame document `body` background / colour / `color-scheme` | `#fff` / `#111` / `normal` | dark surface / light ink / `dark` |
| frame height vs content height (3.6 kB report) | 150 px vs 2 000+ px → inner scrollbar | equal (no inner scrollbar) |
| near-white pixels in the 1280×800 screenshot | 11.4 % | 0.19 % |

Two defects, both in the render path:

1. **Colour** — `buildHtmlSrcdoc` hardcoded
   `body{...background:#fff;color:#111}` and `.chat-html-frame` hardcoded
   `background:#fff` ("white background so arbitrary LLM pages read as *a
   page*"). A null-origin frame inherits nothing, so the theme has to be
   inlined — it just wasn't.
2. **Height** — nothing measured the frame. `min-height: 120px` with no
   `height` left the browser default (150 px) in place, so any report taller
   than that was clipped behind an inner scrollbar.

The two stray `"` marks flanking the box in the report screenshot are the
frame's own scrollbar/border rendering at the top corners of that white slab —
they disappear with the colour fix.

## Changes

| File | Change |
|---|---|
| `src/apps/desktop/src/helpers/iframeAutoResize.ts` | NEW — shared "frame reports its own height" protocol (script + parser + clamp + sender lookup), two source tags |
| `src/apps/desktop/src/helpers/index.ts` | EDIT — re-export the helper |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT — theme palette for the srcdoc shell (`color-scheme: dark`, link/code/table/blockquote styling), `autoResizeScript(...)`, `onHtmlFrameResize` listener (paired add/remove), `.chat-html-frame` paints `--semantic-card-bg` |
| `src/apps/desktop/src/components/preview/PreviewContentRenderer.vue` | EDIT — consume the shared script/parser (no behaviour change; it had the same protocol inline) |
| `src/apps/desktop/src/__tests__/iframeAutoResize.spec.ts` | NEW — 12 unit tests (clamp, foreign-message filtering, sender identity, script shape) |
| `src/apps/desktop/src/__tests__/ChatView.hiddenMessages.spec.ts` | EDIT — source contracts for the theme + auto-size wiring |
| `tests/functional_ui/chatview_html_frame_layout_test.py` | NEW — 3 DB-seeded Playwright tests using the real payload |

### Design decisions

- **Theme values are read from the app's own tokens** (`getComputedStyle` on
  `:root`, memoized once) with the Kanagawa-Dragon literals as fallbacks, so
  the frame can never drift from `style.css` again. `color-scheme: dark` is
  what keeps the frame's native scrollbars dark.
- **`sandbox="allow-scripts"` is unchanged** — the null origin is still the
  security boundary. The injected reporter only reads its own metrics and
  posts one `{source, height, width}` object; the parent only writes a
  clamped `iframe.style.height` (120–2 000 px).
- **Per-consumer source tags** (`chat-html-frame-auto-resize` vs
  `show-preview-auto-resize`) so the preview iframe's listener can never
  resize a chat frame, or vice-versa.
- **Sender identity, not registration order** — a message is applied only to
  the frame whose `contentWindow === event.source`, resolved by querying the
  DOM at message time (VirtualScroller mounts/unmounts rows).
- **`min-height: 120px` kept** — short HTML widgets keep the old floor; only
  the *growth* case changes.

## Verification

- `tests/functional_ui/chatview_html_frame_layout_test.py` — **fails 3/3 on
  pre-fix source** (first assertion: `rgb(255,255,255)`), **passes 3/3 after**.
  Screenshots: 11.4 % → 0.19 % near-white pixels.
- `tests/functional_ui/chatview_html_tag_ui_test.py` — 5/5 still pass
  (sandbox contract, in-frame script execution, mixed markdown, unclosed
  tag, legacy path).
- `pnpm exec vitest --run` on the touched specs: 48/48.
- Full vitest suite: 3074 passed; the 4 failures are pre-existing on `main`
  (`FilePickerDialog.windows`, `WorkspaceItemHideTasksForDesign`,
  `workspacesStoreNormalizeTaskDates`, `workspacesStoreNormalizeTaskImageUrls`)
  — verified by running those 4 specs against `main` unmodified.
- `pnpm run lint:check` clean, `pnpm run type-check` clean.

## Out of scope

- The `show_preview` iframe keeps its own (white) page styling — it is a
  deliberate "preview a page" surface. Only its script/parser moved to the
  shared helper.
- Re-flowing `<html>` blocks that contain *prose only* (the model choosing
  HTML mode) — the fix makes that case look right instead of forbidding it.
