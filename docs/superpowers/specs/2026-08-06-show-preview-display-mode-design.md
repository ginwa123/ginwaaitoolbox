# show_preview display mode — Sidebar vs Inline toggle

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development
> (recommended) or executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose where `show_preview` agent tool outputs render —
in the right-side `PreviewSidePanel` (current behavior) OR inline within the
chat message bubble (new behavior) — via a UI toggle analogous to
`DiffView`'s split/unified switch. The choice persists across reloads via
`localStorage`.

**Architecture:** New composable `usePreviewDisplayMode()` (single source of
truth for `mode: 'side' | 'inline'`, persists to `localStorage`). The
content-rendering logic currently inlined in `PreviewSidePanel.vue`
(`renderedContent`, `imageSrc`, `htmlSrcDoc` + the template's 5-branch
`v-if/v-else-if` chain) is extracted into a new shared
`<PreviewContentRenderer>` component. Both `PreviewSidePanel` and
`ShowPreview` (the per-message card) consume it — when mode is `inline`,
`ShowPreview` mounts the renderer directly inside the chat bubble.

**Tech Stack:** Vue 3 + `<script setup lang="ts">` (existing), Vitest +
Vue Test Utils, localStorage (existing pattern). No Zig changes
(LLM-controlled `display_mode` was explicitly rejected — see "Decision log").

---

## Decision log (context for future readers)

| Decision | Why |
|---|---|
| **User-controlled toggle, NOT LLM-controlled `display_mode` param** | User request: "let user click, if want to show preview, it will show on preview if inline it will inline, like diffview, between split or unified". Mirrors the existing `DiffView` split/unified toggle — UX-driven, not LLM-driven. |
| **Mode persists across reloads via localStorage** | Standard project pattern (e.g. `nalar-preview-panel-width`, `kanban-column-width`, chat scroll restoration). Key: `nalar-preview-display-mode`. |
| **Default mode is `side`** | Matches current behavior — every existing user keeps what they have today. Backwards compatible. |
| **Extract `<PreviewContentRenderer>` shared component** | Two consumers (PreviewSidePanel + ShowPreview). DRY: avoids duplicating the 5-branch rendering logic and the HTML-escape / iframe-sandbox / marked() pipeline. |
| **Side panel auto-hides when mode=`inline`** | The side panel's purpose is to show previews; when previews render inline, hiding the panel reclaims the screen. Implemented via the existing `previewPanelDismissed` flag (set to `true` when switching to inline). |
| **Restore affordance: small "📋 Open preview panel" button in ChatView toolbar** | When in inline mode, the user needs a path back to side mode. A small floating button next to the chat scroll-to-bottom button (or in the existing profile-picker area) keeps the affordance discoverable. |

---

## UX

### Side panel mode (default — current behavior)
```
┌──────────────────────────────────┬─────────────────────┐
│ chat messages                    │ Preview      [◀ Side Inline] ✕ │
│                                  │ ───────────────────│
│ [user]: show me plan             │ ┌─ Preview 1 ──┐   │
│ [assistant]:                     │ │ # Plan       │   │
│   show_preview → Plan · 2 KB ✓   │ │ - step 1     │   │
│                                  │ │ - step 2     │   │
│                                  │ └──────────────┘   │
│ [user]: inline table             │ ───────────────────│
│ [assistant]:                     │                     │
│   show_preview → Inline · 0.5KB✓ │                     │
│                                  │                     │
└──────────────────────────────────┴─────────────────────┘
```

### Inline mode
```
┌──────────────────────────────────────────────────────────────┐
│ chat messages                                                │
│                                                              │
│ [user]: show me plan                                         │
│ [assistant]:                                                 │
│   show_preview → Plan · 2 KB ✓                               │
│   ┌──────────────────────────────────────────────────────┐  │
│   │ # Plan                                                │  │
│   │ - step 1                                               │  │
│   │ - step 2                                               │  │
│   └──────────────────────────────────────────────────────┘  │
│                                                              │
│ [user]: inline table                                         │
│ [assistant]:                                                 │
│   show_preview → Inline · 0.5KB ✓                            │
│   ┌──────────────────────────────────────────────────────┐  │
│   │ | Name | Status |                                       │  │
│   │ |------|--------|                                       │  │
│   │ | a    | done   |                                       │  │
│   └──────────────────────────────────────────────────────┘  │
│                                          [📋 Open preview]   │
└──────────────────────────────────────────────────────────────┘
```

The small "📋 Open preview panel" button appears at the top-right of the
chat area ONLY when `mode === 'inline'` AND there is at least one
`show_preview` message. Click → mode flips back to `side`, panel reappears.

### The toggle itself (in side panel header)
```
[◀ collapse] Preview   [Side | Inline]   [✕ dismiss]
```

Two-button segmented control. Active button has the violet tint matching
the rest of the tool outputs. Hovering the inactive button dims the
violet background to neutral.

---

## File structure

### Files to CREATE

| File | Why |
|---|---|
| `src/apps/desktop/src/composables/usePreviewDisplayMode.ts` | Composable — single source of truth for `mode: 'side' \| 'inline'` + localStorage persistence. |
| `src/apps/desktop/src/composables/__tests__/usePreviewDisplayMode.spec.ts` | Behavioural tests for the composable (init / setMode / persistence / default). |
| `src/apps/desktop/src/components/preview/PreviewContentRenderer.vue` | Extracted renderer. Takes `contentType` + `args` props, renders one of 5 branches (markdown/text/code/image/html) using the SAME logic currently inline in PreviewSidePanel. |
| `src/apps/desktop/src/__tests__/PreviewContentRenderer.spec.ts` | Behavioural tests for the 5 branches (sanity check that the extraction didn't regress anything). |

### Files to MODIFY (surgical patches only)

| File | Change |
|---|---|
| `src/apps/desktop/src/components/preview/PreviewSidePanel.vue` | Replace the inline `renderedContent` / `imageSrc` / `htmlSrcDoc` computed + the 5-branch template with `<PreviewContentRenderer :content-type="..." :args="..." />`. Add the 2-button toggle UI in the header. |
| `src/apps/desktop/src/components/tool_outputs/ShowPreview.vue` | When `mode === 'inline'`, mount `<PreviewContentRenderer>` after the existing header. Otherwise keep current behavior (header only, click to open panel). |
| `src/apps/desktop/src/components/views/ChatView.vue` | Read `mode` from `usePreviewDisplayMode`. When `mode === 'inline'`, set `previewPanelDismissed = true`. When `mode === 'side'` AND there are previews, ensure `previewPanelDismissed = false`. Mount a small floating "Open preview panel" button when `mode === 'inline'` AND previews exist. |
| `src/apps/desktop/src/__tests__/previewSidePanel.spec.ts` | Tests for the new toggle UI (clicking Side/Inactive flips mode, persisted, etc.). |
| `src/apps/desktop/src/__tests__/chatViewShowPreviewBubble.spec.ts` | Tests for inline mode (ShowPreview card renders content directly, side panel is dismissed, the restore button appears and works). |
| `docs/agent-tools.md` | Document the new user-controlled toggle in the `show_preview` section. |
| `docs/SPEC.md` §10.2.1 (PR index) | Add a new PR entry once merged. |

### Files NOT to modify (intentionally out of scope)

- `src/modules/agent/tools/show_preview.zig` — NO LLM-controlled `display_mode` param (per decision log).
- `src/ai_workflow/tui/agentic_loop/tools_exec_show_preview.zig` — executor unchanged.
- The `RenderedContent` etc. helpers in `PreviewSidePanel.vue` — extracted into the new component.

---

## TDD sequence

### Task 1 — Composable + localStorage persistence

Write `usePreviewDisplayMode` with TDD:

1.1 Failing test: `usePreviewDisplayMode` defaults to `'side'` when localStorage is empty.
1.2 Failing test: `usePreviewDisplayMode` reads existing value from localStorage (`'inline'` survives reload).
1.3 Failing test: `setMode('inline')` writes to localStorage AND flips the reactive ref.
1.4 Failing test: invalid localStorage value (e.g. `'sidebar'`) falls back to `'side'`.
1.5 Failing test: SSR-safe — `localStorage` undefined returns `'side'` without throwing.

Then implement the composable.

### Task 2 — Extract `<PreviewContentRenderer>` from PreviewSidePanel

2.1 Failing test: `<PreviewContentRenderer contentType="markdown">` renders `marked()` output.
2.2 Failing test: `<PreviewContentRenderer contentType="text">` renders `<pre>` with preserved whitespace.
2.3 Failing test: `<PreviewContentRenderer contentType="code">` renders `<pre><code class="language-X">`.
2.4 Failing test: `<PreviewContentRenderer contentType="image">` renders `<img>` with the data:/http URL.
2.5 Failing test: `<PreviewContentRenderer contentType="html">` renders iframe with `sandbox="allow-scripts"` and `srcdoc`.

Then extract from PreviewSidePanel (pure relocation — PreviewSidePanel mounts the renderer instead of inlining the logic).

### Task 3 — Add the toggle UI in PreviewSidePanel header

3.1 Failing test: clicking the "Inline" button in the header flips `mode` to `'inline'` and emits `update:displayMode` event.
3.2 Failing test: clicking "Side" when already in side mode is a no-op (or flips if it was inline).
3.3 Failing test: the active mode button has the violet-tinted background class.
3.4 Failing test: the toggle persists across remount (reads from localStorage on init).

### Task 4 — Wire `ShowPreview.vue` to render content inline

4.1 Failing test: when `mode === 'inline'`, the ShowPreview card renders the `<PreviewContentRenderer>` AFTER the header (rich content visible directly).
4.2 Failing test: when `mode === 'inline'`, the card no longer emits `open` on click (no point — content is already visible).
4.3 Failing test: when `mode === 'side'`, behavior is unchanged (header only, click emits `open`).

### Task 5 — Wire ChatView to hide panel + show restore button

5.1 Failing test: when `mode === 'inline'`, `previewPanelDismissed` is `true` (panel hidden).
5.2 Failing test: when `mode === 'inline'` AND previews exist, the floating "Open preview panel" button renders.
5.3 Failing test: clicking the restore button flips mode to `'side'`, panel reappears, button disappears.

### Task 6 — Docs + final verification

6.1 Update `docs/agent-tools.md` with the new toggle UX.
6.2 Update `docs/SPEC.md` §10.2.1 PR index.
6.3 Run full test trio (zig + frontend) — all green, no regressions.

---

## Out of scope (deferred)

- **Per-call LLM `display_mode` param** — explicitly rejected (UX-driven, not LLM-driven).
- **Mixed mode** (some previews in side, some inline) — could be added by promoting the user toggle to per-message, but YAGNI. The toggle is global.
- **Animation when switching modes** — abrupt flip is fine for v1.
- **Keyboard shortcut for the toggle** — could add `Cmd/Ctrl+Shift+P` later.
- **Refactor: extract `<SandboxedIframe>` shared component** — the html iframe is now in 2 places (PreviewContentRenderer + DesignElementPreview). Could extract, but separate refactor.

---

## Pitfalls

- **Don't lose the existing auto-collapse behavior** — the side panel's collapse/dismiss flags are already used to manage the panel. The new `mode` is orthogonal: `mode='side'` + `collapsed=true` = user collapsed panel; `mode='side'` + `dismissed=true` = user dismissed panel. `mode='inline'` = auto-dismiss (overlay). Don't conflate.
- **localStorage key collision** — `nalar-preview-display-mode` is new, not used anywhere. Verify by grep.
- **Vue reactivity** — `setMode` must update the reactive ref, not just localStorage. Subsequent reads of `mode.value` in computed properties must re-evaluate.
- **Mounting `<PreviewContentRenderer>` inside `<ShowPreview>` doesn't affect the side panel** — when `mode === 'side'`, ShowPreview stays in its current minimal-card form. When `mode === 'inline'`, the rich content renders ONLY in the chat bubble (not duplicated in the side panel).
- **Click handler differences** — in inline mode, clicking the header should NOT call `openPreviewForMessage` (the content is already visible). The new test `ShowPreview.vue` should lock this in.
- **The `previewPanelDismissed` flag is shared with other paths** — the existing `dismiss` event from PreviewSidePanel sets it to `true`. When user dismisses manually, then switches back to side mode, the panel should NOT auto-re-show (the user explicitly dismissed). Decision: only set `previewPanelDismissed = false` when the user clicks the "Side" button explicitly, not when switching modes via the restore button... wait, that's the same action. Keep it simple: the toggle / restore button just sets `previewPanelDismissed = false` along with `mode = 'side'`. The existing dismiss button continues to work as before.

---

## Verification

After all tasks complete, the mandatory verification trio:

```bash
cd /home/ginwa/ginwaaitoolbox

# Frontend (type-check + tests + build)
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20           # vue-tsc --build
timeout 180 bunx vitest run 2>&1 | tail -n 10          # all unit tests

# Backend (no changes expected, but still verify)
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5

# Cross-compile smoke
timeout 60 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc src/modules/agent/tools/show_preview.zig 2>&1 | tail -n 5
```

Eyeball check (live smoke on port 8080, NOT 8081):
1. Send a chat message that triggers `show_preview` with markdown content.
2. Verify default mode is `side` — content appears in right panel, not in chat.
3. Click the new "Inline" button in the panel header.
4. Verify mode flips, panel hides, content now appears inline in the chat bubble.
5. Refresh the page — mode should persist.
6. Click the floating "Open preview panel" button — panel reappears with all tabs.

If all green, move kanban task to `merged` (after PR is merged to main).