# Replace every emoji-as-icon with inline SVG

Status: **implemented**. Task: `task_1791135465577_0` (kanban `pabrik`).

---

## 1. Answer in one paragraph

`AGENTS.md` has said "No Emoji as Icons; Use Inline SVG" since PR #802, but
the app still drew **43 distinct emoji as icons across 59 components**. Each
one is a pixel-height and palette liability on its own, and — the part that
finally made the sweep worth doing — none of them can be asserted on by a
test. So: add one registry (`components/ui/icons.ts`) and one component
(`components/ui/UiIcon.vue`), rewrite the 59 call sites to name a glyph
instead of embedding one, and fix the seven specs that were pinning the
emoji strings. The result is that `GitChanges.vue`'s status column renders
six glyphs of identical height in one colour, and a spec can say
`expect(row.find('[data-icon="trash"]').exists()).toBe(true)`.

## 2. What was actually there

A scan of `src/apps/desktop/src` for codepoints in
U+1F000–U+1FAFF / U+2600–U+27BF / U+2B00–U+2BFF found 436 hits over 134
files. Only ~190 of those are icons. The rest, and why they stay:

| Class | Example | Why it stays |
|---|---|---|
| Domain-model icon fields | `icon: '📁'` in `api/persistence.ts`, `stores/workspaces.ts`, ~100 spec fixtures | A user-editable field persisted in the DB. It is *data*, not a glyph the UI draws. Changing it changes the model. |
| Comments / JSDoc | ``the 💬 button`` in `DesignView.vue`'s header | Prose. Reworded only where it named a control that no longer renders that glyph. |
| `AGENTS.md` carve-out | `✕ ▶ ▼ ↻ ◫ ⌕ ⚠` | Explicitly allowed. Monochrome typographic characters with one font stack and a fixed advance. |
| Their monochrome siblings | `✓ ✗ ● ○ ▲ ⌗ → ⌘` | Same reasoning as the carve-out: text-presentation, not emoji-presentation. |
| Log strings | `helpers/scrollLogger.ts:524` `'⚙️' : '👆'` | A marker inside a log line, never rendered. |
| Keyboard accelerators | `⌘⇧G` in `DesignContextMenu.vue` | Text a user types. |

## 3. The design

### `components/ui/icons.ts` — one registry

```ts
export const ICON_PATHS = { trash: ['M10 11v6', …], folder: ['…'], … } as const
export type UiIconName = keyof typeof ICON_PATHS
```

Geometry is the **Lucide 24×24 outline set** (ISC), fetched as SVG and
normalised to plain path `d` strings — Lucide because it covers the whole
glyph set this app needs (`leaf`, `brain`, `bot`, `scroll-text`, `atom`,
`timer`) where Heroicons 404s on four of them. Normalising every primitive
(`<circle>`, `<rect rx>`, `<line>`, `<polyline>`) into `d` is what lets
`UiIcon` render one uniform element per shape.

`as const` is load-bearing: it makes `UiIconName` a closed union, so a typo
in `name="trashh"` is a **type error**, not a silently blank glyph.

### `components/ui/UiIcon.vue`

Mirrors the existing `ForgeIcon.vue` house pattern (the PR #802 component):
`currentColor`, `fill="none"`, 24×24, decorative-by-default.

Two things it does that an emoji could not:

- **`data-testid="ui-icon"` + `data-icon="<name>"`.** This is what makes an
  icon-only control assertable. `LayersPanel.spec.ts` had
  `expect(dz.text()).not.toMatch(/[▭◯T🖼◳◫◇]/u)` — a per-glyph blacklist that
  went vacuous the moment the glyph became an SVG. It is now
  `expect(dz.find('[data-icon]').exists()).toBe(false)`: one selector, every
  glyph, and it fails loudly if a future icon is added.
- **`inline-block shrink-0 align-middle` on the root.** An inline SVG sits on
  the text baseline and opens descender space below it, which is how a 16px
  glyph quietly grows a 20px row. Those three classes keep the box equal to
  the glyph and stop flex parents squashing it.

`stroke-width` defaults to **1.75**, not Lucide's 2 — 2 reads heavy next to
12px monospace in the muted palette.

### Accessibility contract

`aria-hidden="true"` unless `title` is passed. Every glyph this PR replaced
was inside `<span aria-hidden="true">` or next to a visible label
("Skills", "Browse…", "Delete"), so **no call site passes `title`** — passing
one would announce "Trash" after "Delete". `UiIcon.spec.ts` pins both halves
of that contract.

## 4. The two shapes a call site takes

**Literal glyph** — mechanical:

```vue
<span class="text-display mb-3" aria-hidden="true">🌿</span>
<UiIcon name="leaf" size-class="w-6 h-6" class="mb-3" />
```

The wrapper `<span>` goes away; its classes move onto the component. Note
that `text-display` sets `font-size`, which does nothing on an SVG — the
type-scale class becomes a `w-* h-*` box instead.

**Glyph returned from script** — needs a type change, not a string swap:

```ts
const icons: Record<string, string> = { M: '📝', D: '🗑️' }
<span class="text-lead">{{ getDisplayStatus(file).icon }}</span>
```
```ts
const icons: Record<string, UiIconName> = { M: 'note', D: 'trash' }
// render:
<UiIcon :name="getDisplayStatus(file).icon" size-class="w-4 h-4" />
```

Four icon maps took this path: `GitChanges.vue`, `GitCommits.vue`,
`RightSidebar.vue` (git status), `CodeEditor.vue` (file type). Two helper
functions were retyped to `UiIconName`: `FilePickerDialog.vue`'s `iconFor`
public prop, and `LayerRow.vue`'s `typeIcon`.

### Size ramp

`micro/meta/dense → w-3`, `body → w-3.5`, `lead → w-4`, `title-sm → w-4.5`,
`title → w-5`, `title-lg → w-6`, `display → w-7`. Sizing to the *effective*
font size, not to whatever class happened to be on the span, is what keeps a
row one height — the specific failure the sweep exists to fix. 57 call sites
carry an explicit `size-class`; the rest sit at the 16px default.

## 5. Two places a Vue component cannot reach

Both were handled without hand-copying a `<path>`, which is the thing
`AGENTS.md` bans:

- **`MarkdownDescription.vue`** builds a file chip as an HTML string for
  `v-html`. It inlines `ICON_PATHS.file`'s own two subpaths, joined into one
  multi-subpath `d` (which draws identically to two sibling paths), with a
  comment saying why it cannot use `<UiIcon>`.
- **`ChatView.vue:247`** builds its code-copy button with `innerHTML` after
  mount. It interpolates `ICON_PATHS.clipboard` into the string rather than
  pasting a path, so the button stays on the registry's geometry.

## 6. Specs fixed, not deleted

Seven specs asserted on emoji text. Each was rewritten to assert the icon the
component actually draws — and each **absence** assertion gained a positive
control first, so it cannot pass because the selector is dead:

| Spec | Was | Now |
|---|---|---|
| `KanbanDescriptionEditor.search.spec.ts` | `toContain('📁')` | `[data-icon="folder"]` present, `[data-icon="file"]` absent |
| `RightSideBarSkillList.spec.ts` | `not.toContain('🌐')`, `not.toContain('📁')` | asserts `[data-icon="brain"]` **is** present first, then the two absences |
| `SetGitWorktree.spec.ts` | `not.toContain('🌳')` | `[data-testid="ui-icon"]` absent — one assertion covers every glyph forever |
| `chatsListGitWorktree.spec.ts` | `not.toContain('🤖')` | `[data-icon="robot"]` absent |
| `chatViewWorktree.spec.ts` ×2 | `not.toContain('🌳')` | `[data-icon="tree"]` absent |
| `LayersPanel.spec.ts` | `not.toMatch(/[▭◯T🖼◳◫◇]/u)` | `[data-icon]` absent, with the real element row as positive control |
| `FilePickerDialog.spec.ts` | `iconFor: () => '🌿'` | `iconFor: () => 'leaf'` (a prop type change) |

New: `src/__tests__/UiIcon.spec.ts`, 48 tests. It renders **every** registry
name (so a key with an empty path array cannot ship), asserts the
`currentColor`/`fill="none"` contract and the layout classes, and pins the
decorative-vs-named accessibility split.

## 7. Verification

| Gate | Result |
|---|---|
| `pnpm exec vue-tsc --build --force` | clean, 0 errors |
| `pnpm exec eslint` (all 62 changed files) | clean, 0 problems |
| `pnpm exec oxlint` (all 810 files, 116 rules) | 0 warnings, 0 errors |
| `prettier --check` (the 3 new files) | clean |
| `vitest run` — this branch | 4682 passed / 49 failed (514 files) |
| `vitest run` — `origin/main` @ `7cfcf16e` | 4634 passed / 49 failed (513 files) |

**The 49 failures are identical in both runs, test name for test name**
(`comm -13` on the sorted failure lists returns empty). They are pre-existing
on `main` and are not this PR's. This branch adds 48 passing tests.

`preview-ui-icons.html` at the repo root renders all 43 names at the four
sizes call sites use, plus a strip of every glyph sharing one row — the
visual witness for the property no test asserts.

## 8. Deliberately not done

- **`icon: '📁'` on workspaces, chats and nav items** (and its ~100 spec
  fixtures) is a persisted, user-editable field. Converting it to a
  registry name is a schema question, not an icon question.
- **`⚙ ⚙️ ✏ ✍ ⌨ ⚛ ⏱`** in the 2600–2700 blocks were **not** converted. They are
  adjacent to the `AGENTS.md` carve-out and several are used in button labels
  where a typographic character reads better than an outline at 11px. Flagged
  here rather than silently included or silently ignored.
- **The ~40 files that already hand-copy inline `<svg>`.** Consolidating them
  onto the registry is a real follow-up, but it is a different PR: it touches
  files with no emoji in them at all.
- **`prettier --write` was NOT run on the 59 rewritten files.** Their
  formatting drift is pre-existing (`#1D1C19` → `#1d1c19`, a `>{{ content
  }}</pre>` reflow). Running it would have buried this change in several
  hundred unrelated lines. Only the three new files are formatted.

## 9. Reviewer's quick check

```bash
cd src/apps/desktop
pnpm exec vue-tsc --build --force          # must be silent
pnpm exec vitest run src/__tests__/UiIcon.spec.ts
# no pictographic emoji should remain in a rendered template:
rg '[\x{1F300}-\x{1FAFF}\x{2700}-\x{27BF}]' src --glob '*.vue' \
  | grep -v '⚠' | grep -vE '^\S+:\s*(//|\*|<!--)'
```
