# Bottom ChatView UX — Wireframe + Improvement Plan

> Task: `ui ux better bottom Chatview` — plan first, implement after approval.
> Scope: `ChatView.vue` footer (status bar ~L4971–5190) + `FileInput.vue` composer row.
> No code changes in this task — wireframe + plan only.

## 1. Current anatomy (from screenshot + source)

```
Row 1 (FileInput.vue <form>):  [textarea flex-1] [📎 attach] [■ Stop (red)] / [Send (violet→blue)]
Row 2 (ChatView.vue status bar): [🗜️ Compact] [🤖 muse/spark/auto ▾] [Tokens: 82,679 / 900,000 ▬] [🌿 worktree/<very-long-branch> ✓ ▾] (+ skills 🧠 / bg-commands when present)
```

Container: `div.p-4` with top border, inner `div.max-w-4xl.mx-auto`. Row 2 is
`flex items-center gap-2 mt-3` — visually detached from the input.

## 2. What's ugly (ranked)

| # | Problem | Evidence |
|---|---------|----------|
| 1 | **Two disconnected rows.** Input is a rounded card; status row floats below with `mt-3`, different radius (`rounded-xl` vs `rounded-lg`), different bg treatment. Reads as two components, not one composer. | `ChatView.vue:4955`, `FileInput.vue` form |
| 2 | **Action vs status affordance mixed.** `Compact`, model picker, worktree look identical (same card bg + border + `hover:scale-105`), but Tokens is display-only with the same chip style. User can't tell what's clickable. | status bar `gap-2` row |
| 3 | **Emoji vs SVG inconsistency.** 🗜️ 🤖 🌿 🧠 in status row vs SVG paperclip / SVG stop square in input row. Emoji render at different sizes/weights per OS. | status bar buttons |
| 4 | **Long branch name eats the row.** Worktree chip is `flex` with full branch text, no `max-width`/`truncate` — `worktree/in-kanban-has-a-media…-1790182349446` pushes everything, wraps awkwardly on narrow widths. | screenshot right chip |
| 5 | **Stop button dominates.** Solid `var(--color-red)` fill + same size as Send draws the eye hardest at the exact moment the user should be reading output. Standard pattern is a quiet square-stop inside/attached to the input. | `FileInput.vue:899` |
| 6 | **Token chip is noisy.** `Tokens: 82,679 / 900,000` + 64px bar in its own bordered card duplicates info the Compact button already implies; number pair is hard to scan. | `ChatView.vue:5075` |
| 7 | **No grouping / overflow story.** Skills pill + bg-commands popup append inline with no wrap (`flex` no `flex-wrap`), so on narrow panes the row overflows instead of collapsing. | status bar container |

## 3. Proposed wireframe — "single composer card"

One bordered card; input on top, toolbar strip pinned to its bottom edge
(inside the same border, separated by a hairline). Status becomes
quiet text/icons; only real actions look like buttons.

```
┌─ composer card (rounded-xl, card-bg, border) ─────────────────────┐
│ Type a message... (@ to search files)                              │
│                                                                    │
│ [📎] [Queued 2 ▾]                              [■ Stop] / [Send ➤] │  ← inside input row, icon-size
├─ toolbar strip (hairline top border, 32px, muted) ─────────────────┤
│ [🗜 Compact] [muse/spark/auto ▾] │ 82k/900k ▬▬▬░░ │ 🌿 branch… ✓ ▾ │
└────────────────────────────────────────────────────────────────────┘
  legend: [x] = quiet ghost button · │ = divider · middle items truncate
```

Detailed rules:

- **A. Single card.** Move the status row *inside* the composer card as a
  bottom toolbar (`border-top: hairline`, `px-3 h-8`, `bg: transparent`).
  Remove `mt-3` gap and the second `max-w-4xl` nesting — one container.
- **B. Three zones in the toolbar.**
  1. Left (actions): Compact (ghost icon+label), model picker (ghost).
  2. Middle (status, non-clickable): tokens as muted text `82k / 900k` +
     slim 48px bar, no border, no hover. Tooltip keeps exact numbers.
  3. Right (context): worktree chip with `max-w-[220px] truncate`, skills
     count, bg-commands dot. `margin-left: auto` so long branches shrink,
     never push left items.
- **C. Icon consistency.** Replace 🗜️/🤖/🌿/🧠 emoji with the app's SVG
  icon set (same 14px stroke icons as the sidebar). Keeps OS-independent
  rendering and matches the paperclip SVG one row above.
- **D. Stop tamed.** Stop becomes a quiet square icon-button attached to
  the input row (subtle border, no red fill; red only as icon ink or on
  hover). Same `h/w` as attach button so the row doesn't jump when
  Send ↔ Stop swaps (`v-if` keeps layout: fixed-width slot).
- **E. Send stays primary** (violet→blue gradient) but shrinks to icon +
  label parity with Stop slot; `Queue` state keeps spinner, no width jump.
- **F. Overflow.** Toolbar gets `flex-wrap: nowrap; overflow-x: auto;
  scrollbar-width: none` + `flex-shrink: 0` on left actions, `min-w-0`
  + `truncate` on branch/tokens. Narrow panes scroll the strip instead of
  breaking layout.
- **G. A11y/titles preserved.** Keep all `data-testid`s
  (`stop-session-button`, `send-message-button`, `worktree-status-button`,
  `profile-picker-*`), keep tooltips, keep keyboard flow.

### Wireframe variants (pick one)

- **V1 (recommended): toolbar inside card** — as drawn above. Smallest
  diff, fixes #1 directly. ~2 files touched.
- **V2: floating pill composer** — card becomes `rounded-2xl shadow-lg`,
  toolbar floats as a separate pill overlapping the card's bottom edge.
  Prettier but more CSS risk + overlaps message list spacing.
- **V3: status quo, polish only** — keep two rows, just fix truncate,
  icons, Stop color. Cheapest, but #1 (disconnect) remains.

## 4. Implementation plan (next task, after approval)

1. `FileInput.vue` — accept a `#toolbar` slot rendered *inside* the card
   below the `<form>` (hairline divider); fix Send/Stop to equal-size
   icon slots; swap emoji → SVG (no logic change).
2. `ChatView.vue` — move status-bar block into the new slot; add
   zone layout (left actions / middle status / right context), dividers,
   `truncate` + `max-w` on branch chip, tokens to muted text + slim bar.
3. CSS only: toolbar strip styles, `overflow-x-auto no-scrollbar`,
   responsive collapse (`<640px`: tokens bar hides, branch truncates to
   120px). No API/store changes.
4. Tests:
   - Existing specs keep passing (`data-testid`s unchanged).
   - Add `ChatView.footer.spec.ts`: toolbar renders inside card; branch
     truncates (`max-w` class present); tokens non-clickable (no button).
   - Manual: narrow-width (kanban 3-col) screenshot before/after.

## 5. Open questions for you

1. V1 vs V2 vs V3?
2. Keep the `Compact` button in the toolbar, or move it to the chat header
   (it's a session action, not a compose action)?
3. Token display: compact `82k/900k` (proposed) vs full `82,679 / 900,000`?
4. Model picker: keep full `muse/spark/auto` 3-line label or shorten to
   model name only (`spark`) with full name in tooltip?
