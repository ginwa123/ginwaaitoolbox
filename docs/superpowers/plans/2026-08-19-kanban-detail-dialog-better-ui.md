# 2026-08-19: Kanban task detail dialog — better UI & button consistency

## What

Polish the `KanbanTaskDetailDialog` so the **buttons are visually consistent**
across all three (Cancel, Save / Create task, Start agent / Create task & run agent),
the layout reads as coherent sections rather than scattered rows, and metadata
chips stop floating as plain dim text. No backend changes, no schema changes, no
new features — pure UI pass.

## Why

User feedback: "make the ui kanban detail more better. and consistent" followed
by "the button espcially is not consistent". The dialog's three action buttons
currently look like three unrelated controls:

| Button                     | Background              | Text color         |
|----------------------------|-------------------------|--------------------|
| Cancel                     | `var(--semantic-card-bg)` | `text-muted`       |
| Save / Create task (primary) | gradient violet→blue  | `color-bg` (dark)  |
| Create task & run agent    | `transparent`           | `text` (bright)    |
| Start agent                | `transparent`           | `text` (bright)    |

The codebase convention (used in `NalarSaveBar`, `McpServersSection`,
`ProfilesSection`, `McpHeadersEditor`) is `transparent` + `text-muted` for
secondary outline buttons — so **Cancel** (card-bg) and the two "run agent"
 buttons
(bright text) are both outliers. With three buttons all looking similar-but-
not-identical, the visual weight doesn't match the action hierarchy:
**primary (commit) vs. secondary (cancel / kick-off agent)**.

Beyond the buttons, the dialog also has:

- **Header** — bare title with no subtitle and no icon, while every other
  dialog (`KanbanSettingsDialog`, `AddKanbanDialog`) carries both. This made
  the title feel disconnected from the form.
- **Metadata strip** — column name rendered as plain dim text (e.g. `todo`),
  while tags + picker chips in the same dialog use proper bordered pills. The
  metadata read as "orphan text" instead of "badges".
- **Body padding** — `py-4` on the body combined with `pb-4` on the header
  stacks 32px of dead air between the title and the first field.
- **Tags label** — bare label, while `Unattended mode` below it has
  descriptive subtext. Inconsistent information density between sibling
  controls.
- **Settings scattering** — cwd picker, profile picker, and unattended toggle
  each occupied their own row with their own `border-top` separator. Three
  rows, three dividers, no subheading. They all answer the same question
  ("how will this task run?") but the layout didn't say so.

## Files

| File | Change |
| --- | --- |
| `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | Header gets icon + subtitle. Body padding reduced. Column / type / pinned rendered as small chips with emoji prefixes. Description label gains a hint and the counter splits into its own corner. Tags label gains a hint. All three settings controls (cwd picker, profile picker, unattended toggle) grouped under a "Settings" subheading with consistent chip-style triggers. Cwd picker chip re-labelled "Project root /path" (or "Project root (none)") to match the profile picker's chip shape. Cancel, Create task & run agent, and Start agent buttons all normalized to `transparent` + `text-muted` for visual consistency. |
| `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts` | Two tests updated to assert the new "Project root (none)" copy instead of the old "Skip (no project root)" placeholder (the chip layout moved the placeholder text out of the picker's `textContent`). All other tests pass without changes — the buttons' `data-testid`s and disabled-state contracts are unchanged. |

No backend, schema, API, or other-component changes. No migration. No new
testids (the existing `kanban-task-detail-cancel`, `kanban-task-detail-save`,
`kanban-task-detail-create-and-run`, `kanban-task-detail-start-agent`,
`kanban-task-detail-cwd-picker`, `kanban-task-detail-profile-picker`,
`kanban-task-detail-unattended` testids all still resolve to the same
buttons / pickers they did before — only the visual styling changed).

## Plan

### Step 1 — Header: icon + subtitle

Mirror the `KanbanSettingsDialog` header pattern (icon emoji + title +
descriptive subtitle on a second line). For edit mode use `✏️` + "Task
details" + "Edit name, description, and tags. Changes save on click." For
create mode use `➕` + "New task" + "Create a new task. Optionally start an
agent on it right after."

### Step 2 — Body padding

Change `<div class="flex-1 overflow-y-auto min-h-0 px-5 py-4">` to
`px-5 pt-4 pb-4` so the body's top padding matches the header's bottom
padding (`pb-4` = 16px). Eliminates the 32px dead-air gap between the title
and the first form field.

### Step 3 — Metadata chips

Replace the plain `<span>{{ columnLabel }}</span>` (and the `·` separators
around type / pinned) with bordered chips matching the cwd-picker / profile-
picker visual language:

```html
<span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md
             text-xs font-medium"
      style="background-color: var(--semantic-sidebar-bg);
             border: 1px solid var(--color-border);
             color: var(--semantic-text);">
  <span aria-hidden="true">📋</span>
  {{ columnLabel }}
</span>
```

Type + pinned get the same shape but `var(--semantic-text-muted)` color and
no emoji (or `📌` for pinned). The create-mode column picker also gets the
same chip treatment so the create-mode column affordance matches the
read-only edit-mode chip.

### Step 4 — Description label

Split the `<label>Description (N / 5000)</label>` into two parts: the label
on the left and the counter in the top-right corner (`justify-between`).
Add a hint paragraph below: "Markdown supported. Type `@` to link a file.
Paste or attach images."

### Step 5 — Tags label

Add a hint below the label: "Optional. Press Enter or comma to add. Letters,
digits, underscores, hyphens."

### Step 6 — Settings section group

Wrap the cwd picker, profile picker (create mode only), and unattended
toggle in a single `<div>` with a `border-top` separator and a "Settings"
subheading. Inside:

- **Row 1**: cwd picker + profile picker, both using the new chip-style
  trigger (label + value + ▾ caret, same padding/border-radius). The cwd
  picker button now reads `📁 Project root /home/foo/bar ▾` (or `Project
  root (none) ▾` when empty) — this is the change that breaks the two old
  "Skip (no project root)" text assertions in the spec.
- **Row 2**: unattended toggle, separated by a `border-top` divider so it
  reads as a distinct control rather than "part of the picker row".

### Step 7 — Button consistency

Three secondary buttons normalize to the same outline + muted-text style:

```css
background-color: transparent;
border: 1px solid var(--color-border);
color: var(--semantic-text-muted);
```

- `kanban-task-detail-cancel` — was `var(--semantic-card-bg)` + `text-muted`,
  change fill to `transparent`.
- `kanban-task-detail-create-and-run` — was `text` (bright), change to
  `text-muted`.
- `kanban-task-detail-start-agent` — was `text` (bright), change to
  `text-muted`.

Save / Create task (primary) keeps the gradient — that's the only button
that should pop. After the change the visual hierarchy is unambiguous:
**1 primary (gradient) + 3 secondary (outline + muted)**.

## Verification

- `bun run type-check` — clean.
- `bunx vitest --run KanbanTaskDetailDialog` — **97 / 97 pass**.
- `bunx vitest --run Kanban` — **502 / 502 pass** across 41 files.

The two failing tests after Step 6 were the only ones that asserted the
old `"Skip (no project root)"` placeholder text in the picker's
`textContent`; both updated to assert the new `"Project root"` + `"(none)"`
chip copy.