# Right sidebar redesign — 2026-10-04

Task: `task_1791129885927_2` (kanban `pabrik`).
Scope: `src/apps/desktop/src/components/views/chat_right_sidebar/ChatRightSidebar.vue`
and `.../SidebarDiffPanel.vue`. No backend, no API, no URL-contract change.

## 1. The problem, from the screenshot

The panel that shows PR #799's 43 files spends its first ~150px on four
stacked chrome rows and none of it on the thing it exists for:

```
┌─ Changes ──────────────────────────────────────── ✕ ─┐  h-10   ← redundant title
│  Explorer │ Files changed │ ⌁ Terminal             │          ← panel tabs
│ Files changed │ Pull request (43) │ Commits │ Checks │ Evals │ ← sub-tabs
│ 🔀 #799                            [Merged] [43] ↻  │  h-10   ← PR header
├────────────────────────────────────────────────────┤
│ Merged — this PR was merged on GitHub. …           │          ← banner
│ PR files (43)                                      │
│ 📝 docs/plans/2026-10-04-skills-sqlite-table.md    │
│ 📝 src/agentic_loop/run_skill_eval.zig             │
│ … 43 rows of identical-weight full paths …         │
└────────────────────────────────────────────────────┘
```

Six concrete failures, each of which the redesign below names a fix for:

| # | Failure | Cost |
|---|---|---|
| 1 | Four chrome rows before row one of content | 150px of a ~900px panel |
| 2 | "Files changed" is the outer tab **and** the inner sub-tab | two different things, one name |
| 3 | Tab labels carry inline counts (`Pull request (43)`) | the strip clips between 200px and 600px |
| 4 | 43 raw full paths, one weight, no grouping, no filter | `PrChecksPanel.vue` gets the last 12px of the row |
| 5 | Up to six full-width banner boxes stacked above the list | the list starts below the fold |
| 6 | Status is a colour emoji at six different rendered sizes | 📝➕🗑️🔄📋❓ next to monospace paths |

## 2. The design

```
┌─ rail ──────────────────────────────────────────────────────────┐
│ [ ▤ Explorer ][ ⎇ Changes ][ ⌁ Terminal ]                    ✕  │  h-11
├─ sub-tabs ───────────────────────────────────────────────────────┤
│ Files·3   PR·43   Commits   Checks   Evals               ⌕  ↻   │  h-9
├─ context band ───────────────────────────────────────────────────┤
│ 🔀 #799   [Merged]   worktree/x…main                        [43] │  h-9
├─ notices ───────────────────────────────────────────────────────┤
│ ⚠ Merge conflicts in 2 files — resolve them        Conflicts only│  h-8
├─ filter ─────────────────────────────────────────────────────────┤
│ ⌕ Filter files…                                          7/43    │  h-8   (only >8 rows)
├─ list ───────────────────────────────────────────────────────────┤
│ ▾ PR FILES (43)                                                  │  h-7
│   [M] src/apps/desktop/src/components/tool_outputs/ EditSkill.vue│  h-7
│   [A] src/agentic_loop/                                skills.zig │
│   [?] docs/plans/                          2026-10-04-skills.md   │
└──────────────────────────────────────────────────────────────────┘
```

### A. One rail, not a title plus a tab strip

The panel's name is already the active tab's label, so the title row is
deleted and the tab strip moves up into a single `h-11` rail with the close
button on its right. Segments are `flex-1 min-w-0 truncate` inside an
`overflow-x-auto` row, so a fourth panel added later narrows the segments
instead of clipping them.

Active segment: `--semantic-active-bg` fill + `inset 0 -2px 0 0
var(--color-violet)` underline + `--semantic-active-text`. Inactive:
`--semantic-text-dim`. Same "2px violet underline" language as
`PabrikTabStrip.vue` and the old `shell/RightSidebar.vue`.

### B. One sub-tab strip, one-word labels, counts as pills

`Files changed (3)` → `Files` + a `3` pill. `Pull request (43)` → `PR` + a
`43` pill. That is 148px → 46px on the widest tab, which is the whole
reason the strip stopped fitting. Counts move from the label into a
`rounded-full` chip on `--color-bg-p1`, the `KanbanColumn.vue` badge idiom.

The strip is two nested flex rows: a scrollable tab cluster and a
non-scrolling right cluster holding the filter toggle and `↻`. `↻` moves
here from the PR header, and so does the git header's `Files`/`Commits`
toggle — both were third and fourth rows of chrome for one 24px button.

### C. Context band, on `--color-bg-m1`

A single `h-9` band that reads as the second line of the header block
rather than a new bar, because it is tinted rather than outlined. PR mode:
`🔀 #799` (mono, semibold) · status chip · conflict chip · `base…head` ·
count chip. Git mode: `🌿 branch` · count chip.

### D. Notice strips

Every banner becomes the same one-line strip — `h-8`, `rounded-md`, 12%
`color-mix` tint, a glyph, a `truncate`d text span whose full string stays
in `title`, and an optional action on the right. Six different full-width
prose boxes become a tidy stack of rails, and the list starts ~80px higher.
Truncation is safe because every notice is already duplicated in its
`title` attribute.

### E. File rows — the part that matters

The single highest-value change in a 43-row list is making the **filename
the bright part**:

```
[ M ]  src/apps/desktop/src/components/tool_outputs/   EditSkill.vue
 └chip  └──────── dim ───────────────────────────┘  └ bright ┘
```

Same one line, same `h-7`, same truncation. The eye now skips the
`src/apps/desktop/src/components/` prefix that every row shares and lands
on `EditSkill.vue`. The status emoji is replaced by a **letter chip** — a
16px rounded square, `text-micro font-bold`, tinted per status (`M`
orange, `A` green, `D` red, `R` violet, `C` dim, `?` dim). One glyph
width, one baseline, no colour-emoji size lottery.

Selection adopts the app's own idiom from `ChatsList.vue:1085` —
`--semantic-active-bg` plus `box-shadow: inset 2px 0 0 0
var(--color-violet)`.

### F. Filter

`Filter files…` appears only once the visible list passes 8 rows, so a
three-file panel is not asked to carry a search box. Filters the worktree
groups and the PR list. It is transient text, not a view, so it stays a
local `ref` — `?panel=`, `?sidebar=` and `?conflicts=` already carry every
piece of state that must survive a reload.

### G. Shared primitives

Three hand-copied spinner SVGs and four bespoke emoji-centred empty blocks
become `SpinnerIcon.vue` and `EmptyState.vue`, which already exist for
exactly this.

## 3. What is deliberately NOT changed

Every testid, every exact text, every URL param and every source-grep
contract survives. The riskiest ones, and why they still hold:

| Contract | Held by |
|---|---|
| inline tab `:style` with `var(--semantic-text)` + `inset 0 -2px` | `SidebarDiffPanel.tabs.spec.ts:163-168` — the active/inactive mechanism is unchanged, only the padding and the label move |
| `sidebar-tab-files` / `-pr` hidden without `prUrl` | still `v-if="isPrMode"` |
| `#42`, `2`, `Merged`, `Open`, `3` exact `.toBe()` | those elements keep a single text node, no glyph added inside |
| `Staged Changes (1)` / `PR files (0 of 1)` `toContain` | group headers keep their wording; the chevron is a separate span |
| `findAll('[data-testid^="sidebar-pr-file-"]').length === 1` | no new element may start with that prefix |
| no `watch(` in `ChatRightSidebar.vue` | the rail is pure presentational; the panel→rail count is an emit, never a watcher |
| exactly 1 `local/no-silent-fallback-catch` in that file | no `try`/`catch` was added |
| `loadPanel()` reads `window.location.search` before the router | untouched |
| `v-show` panels (PTY survives tab switches) | untouched |

## 4. Also considered and rejected

- **Directory grouping with collapsible headers.** The strongest answer to
  "43 rows of full paths", and it needs collapse state, a URL param and a
  whole new interaction surface. The dim/bright split in (E) gets most of
  the benefit for none of the risk. Grouping is the right follow-up.
- **A width slider / wider default.** `useChatRightSidebar.spec.ts` pins
  default 280 and clamp 200–600. The layout now works across that whole
  range instead of asking for a bigger one.
- **Virtualising the file list.** `VirtualScroller.vue` exists, but 43–500
  rows of `h-7` content are not the frame cost the chats list has.
- **Redesigning `shell/RightSidebar.vue`.** It is dead code — no importer
  outside its own poll spec. Out of scope; deleting it is a separate task.
