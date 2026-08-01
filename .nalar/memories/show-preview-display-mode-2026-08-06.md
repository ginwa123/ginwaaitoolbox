# show_preview display mode (2026-08-06)

## What landed (squash-merged as `d8454cbc`)

User-controlled 2-button Side/Inline toggle in the
PreviewSidePanel header (DiffView-style). Lets the user pick
where `show_preview` agent tool outputs render. Default: `side`
(matches existing behaviour; backwards compatible).

## Architecture

4 pieces, all frontend-only:

1. **`usePreviewDisplayMode` composable** (`src/composables/usePreviewDisplayMode.ts`)
   - Module-level singleton ref + `setMode()`.
   - Persists under `localStorage['nalar-preview-display-mode']`.
   - SSR-safe (returns `'side'` when `localStorage` is undefined).
   - Re-syncs from localStorage on every call (idempotent in
     production, lets tests pre-set the key).

2. **`<PreviewContentRenderer>` component** (extracted from
   `PreviewSidePanel.vue`)
   - Pure relocation: 5-branch content rendering
     (markdown / text / code / image / html) lifted into a
     shared component.
   - Both `PreviewSidePanel` (active tab) and `ShowPreview`
     (inline mode) mount it.

3. **`PreviewSidePanel.vue`** changes
   - Mounts `<PreviewContentRenderer>` (replaces inlined branches).
   - Adds the 2-button toggle UI in the header
     (testids: `preview-display-mode-toggle` / `-side` / `-inline`).
   - Active button has violet tint matching the rest of the
     tool outputs.

4. **`ShowPreview.vue` + `ChatView.vue`** changes
   - `ShowPreview` mounts the renderer inline when `isInline` is
     true. Drops `role=button` / `tabindex` (not a click target
     in inline mode — content already visible).
   - `ChatView` watches `isInline`. Switching to inline
     auto-dismisses the side panel; switching back restores the
     user's previous dismiss preference.
   - Floating "📋 Open preview panel" button at top-right of
     the chat area (testid: `restore-preview-panel-button`),
     visible only when `isInline` AND
     `showPreviewMessages.length > 0`.

## Tests

38 new behavioural tests across 5 files:

| File | New |
|---|---|
| `composables/__tests__/usePreviewDisplayMode.spec.ts` (new) | 9 |
| `__tests__/PreviewContentRenderer.spec.ts` (new) | 10 |
| `__tests__/previewSidePanel.spec.ts` | +6 |
| `__tests__/ShowPreview.spec.ts` (new) | 12 |
| `__tests__/chatViewShowPreviewBubble.spec.ts` | +6 |

## Pitfalls + lessons

- **Module-level singleton ref + re-sync on each call** is the
  cleanest pattern for a testable, SSR-safe, localStorage-backed
  user preference. The re-sync is a single key read per call
  (fast + idempotent in production because `setMode` persists on
  every flip). Tested via the "reads existing 'inline' value"
  case where localStorage is pre-set before each test.
- **Test isolation gotcha**: an SSR-safe test that does
  `delete globalThis.localStorage` will permanently break
  subsequent tests' `beforeEach` if the restore doesn't fire.
  Use `Object.defineProperty(globalThis, 'localStorage', { value: undefined, configurable: true })`
  + always restore in `afterEach` (don't rely on `try/finally`
  alone if vitest reorders).
- **Auto-merging AGENTS.md + docs/SPEC.md worked** when the
  other agent's worktree was the only blocker. Stashing their
  uncommitted work + `git merge --squash` + restoring the stash
  is the cleanest path. No conflicts on shared docs because
  PR #167's changelog entry didn't touch the show_preview
  section.
- **`previewPanelDismissed` semantics**: the existing flag is
  re-used for "user dismissed" AND for "mode=auto-dismissed".
  We track the previous user intent via a separate
  `previewPanelWasDismissedBeforeInline` ref so switching back
  to side mode restores the user's prior dismiss choice.
- **jsdom doesn't auto-encode iframe srcdoc** like browsers do.
  Test for the raw HTML in the attribute (browsers handle
  encoding at runtime).

## Related

- Spec: `docs/superpowers/specs/2026-08-06-show-preview-display-mode-design.md`
- Plan: not separate (TDD executed per the spec's "TDD sequence" section)
- Commit: `d8454cbc` on main
- Branch: `worktree/show-preview-display-mode` (deleted after merge)

## Out of scope (deferred for follow-ups)

- LLM-controlled `display_mode` param (explicitly rejected —
  UX-driven, not LLM-driven)
- Per-call mixing (single global toggle for v1)
- Animation when switching modes
- Keyboard shortcut (`Cmd/Ctrl+Shift+P`)
- `<SandboxedIframe>` shared-component extraction (now 2
  consumers would share it)
