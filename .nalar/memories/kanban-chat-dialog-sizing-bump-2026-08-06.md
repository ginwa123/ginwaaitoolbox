# Kanban chat dialog sizing — 3rd bump (2026-08-06)

## Symptom (user report)

User said *"make chatview dialog bigger on kanban mode"* with a screenshot
showing the dialog occupying about 60% of the viewport width. The current
size was 95vw × 90vh with max 1400×1000 — visible as a centered panel with
~150px margin on each side of a typical 1600px viewport.

## What landed (commit `c47c94ac`)

Bumped `KanbanChatDialog.vue` panel sizing:

| | Before | After |
|---|---|---|
| width | 95vw | 98vw |
| height | 90vh | 95vh |
| max-width | 1400px | 1600px |
| max-height | 1000px | 1200px |
| min-width | 720px | 800px |
| min-height | 480px | 540px |
| Area (vw×vh) | 0.855 | 0.931 (+8.9%) |

Also restored the stale header comment block. Previous bumps had updated
the code but not the comments, so the header claimed 90vw/85vh while the
actual code was 95vw/90vh. The new block tracks all 4 bumps:

```
80vw × 80vh / max 1100×800 / min 480×320  (original)
90vw × 85vh / max 1200×900 / min 640×420  (1st bump — stale comment block)
95vw × 90vh / max 1400×1000 / min 720×480 (2nd bump — code only, comments forgot)
98vw × 95vh / max 1600×1200 / min 800×540 (3rd bump — current)
```

## TDD trace

RED: 4 new tests in `KanbanChatDialog.spec.ts` (one describe block
"dialog sizing (2026-08-06, 3rd bump)") — 3 fail (the inline-style regex
assertions), 1 passes (the pure numeric `98*95 > 95*90` area check).

GREEN: patched the .vue file. All 13 dialog tests pass.

## Tests

```ts
describe('dialog sizing (2026-08-06, 3rd bump)', () => {
  it('uses 98vw width + 95vh height for viewport-relative sizing')
  it('caps at max-width 1600px and max-height 1200px on large screens')
  it('keeps a usable min size on small viewports')
  it('dialog area exceeds the previous 95vw x 90vh sizing')  // pure numeric
})
```

Each style-asserting test reads `panel.getAttribute('style') ?? ''` and
runs `expect(style).toMatch(/width:\s*98vw/)` (etc). The CSS `:style`
binding on the panel compiles to an inline `style` attribute, which is
trivial to read in jsdom.

## Why lock in CSS via inline-style regex

CSS visual sizing isn't normally unit-tested (you'd need Playwright or
visual regression). But the kanban dialog has been bumped 3 times in
3 weeks — each time the code changed but a regression guard was missing.
A 4-line regex check on the inline `style` attribute is the cheapest
possible regression guard that catches "someone shrank the dialog".

For PURE cosmetic tweaks (border-radius, color, gradient), a CSS regex
test is overkill. But for "the dialog keeps getting smaller because
someone 'tweaks' the value", a locked-in assertion is worth the 4 lines.

## Verification

- `bun run build` clean (vue-tsc passes)
- `bunx vitest run src/__tests__/KanbanChatDialog.spec.ts` — 13/13 pass
- `bunx vitest run` (full suite) — 2078 pass / 19 fail. The 19 are
  PRE-EXISTING on main, matching the documented baseline exactly
  (`DesignView.undoHidden×5`, `AppLayout.urlPersist×7`,
  `AppLayout.memoriesGate×4`, `DesignElement static contract×1`,
  `AppLayout.translateResize×1`, `DesignView.nudge clamp×1`).
  Zero regressions.

## Branch / commit

- Branch: `worktree/kanban-chat-dialog-bigger`
- Commit: `c47c94ac`
- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-chat-dialog-bigger`
- Files: 2 changed (+91/-12)
