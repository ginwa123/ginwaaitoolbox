# Plan — Kanban task dialog: the 3 footer buttons

**Task** `task_1790616305483_5` · "make the 3 button more better"
**Wireframe** [`docs/plans/2026-09-29-kanban-task-detail-3-buttons-wireframe.html`](./2026-09-29-kanban-task-detail-3-buttons-wireframe.html)
**Component** `src/apps/desktop/src/components/kanban/KanbanTaskDetail.vue:1812-1907`
**Status** 🟡 planning — wireframe written, awaiting human pick. **No code changed yet.**

---

## 1. Problem

The sticky action row at the bottom of the New-task / Task-details panel is
`Cancel` · `Create task` · `▶ Create task & run agent`
(edit mode: `Cancel` · `Save` · `▶ Start agent`).

Eight defects, in descending order of cost. Full write-up with annotated
drawings in §1 of the wireframe.

| # | Defect | Evidence |
|---|---|---|
| 1 | **The primary is not rightmost.** The gradient `Create task` sits mid-row with a secondary to its right. | 22 of 24 footer rows in this app put the primary last. Only `RoutineView.vue:566-592` shares the inversion. |
| 2 | **Cancel and the run button are pixel-identical** — same `border: 1px solid var(--color-border)`, same `color: var(--semantic-text-muted)`, same size. | `:1816-1827` vs `:1857-1871` |
| 3 | **The user cannot tell which button they pressed.** | One host flag `createBusy` (`KanbanView.vue:1197`) drives both labels; `:1845` and `:1870` both read `isCreating ? 'Creating…' : …`. No spinner on either. |
| 4 | **No hover and no focus ring on any of the three.** | `class="… transition-all duration-200"` with nothing to transition. House model is `hover:opacity-80`, used by the Back button at `:1162-1181`, 20 lines above. |
| 5 | **The keyboard default contradicts the visual default.** Enter in the name field runs the *agent* in create mode. | `handleEnterKey` `:842-848` |
| 6 | **Two labels sharing their first two words** — "Create task" / "Create task & run agent" read as a diff, not a menu. | `:1845`, `:1870` |
| 7 | **No `flex-wrap`** → the row clips rather than reflows on a narrow panel. | `:1813` |
| 8 | **The subtitle argues with the row** — "Optionally start an agent on it right after". | `:1206-1212` |

## 2. Constraints (these bound every option)

1. **All four `data-testid`s must survive**: `kanban-task-detail-cancel`,
   `-save`, `-create-and-run`, `-start-agent`. ~69 test sites select them.
   Worse, `tests/functional_ui/kanban_lifecycle_ui_test.py:290` falls back to
   `button:has-text('Save')` and then degrades to `keyboard.press("Enter")` —
   a renamed testid **silently weakens** that test instead of failing it.
2. **No glyph or icon inside the Save/Create button.** Five assertions are
   byte-exact `textContent?.trim()).toBe(...)`:
   `KanbanTaskDetailDialog.creatingGuard.spec.ts:92,135,159,181` and
   `KanbanTaskDetailDialog.spec.ts:791`. The `▶` on the *run* button is safe
   (those assertions use `toContain` and the glyph is `aria-hidden`).
3. **`@mousedown="commitTagsDraftOnSaveMouseDown"` must stay on the `<button>`
   element** — `KanbanView.spec.ts:880-885` dispatches `mousedown` then `click`
   on the same node to commit a half-typed tag.
4. **There is no button component and no `.btn` CSS** in this codebase. The
   house pattern is a copy-pasted `class` + inline `style` literal. Do not
   introduce a `variant=` prop as part of this task.
5. **No `--color-danger` token exists.** (Not needed here — nothing destructive.)
6. Do not set `color-scheme: dark` on `:root` — `style.css:110-120` explicitly
   warns against it because it repaints UA focus rings near-white.

## 3. Decisions — 🟡 PROPOSED, need your sign-off

| # | Decision | Proposal | Rationale |
|---|---|---|---|
| **D1** | Layout | **Option A** — "promote the run" | Reorder only. No new primitive, zero test breaks. Option B (split button) and C (run-as-switch) both delete a `data-testid` and cost ~30 test sites; Option D is the zero-risk fallback if you disagree on D2. |
| **D2** | Which button is primary | **`▶ Create task & run agent`** | It is what <kbd>Enter</kbd> already does. Making "create only" the loud option fights the keyboard. |
| **D3** | Cancel styling (F4) | **Ghost** — drop the border, text `--semantic-text-dim #7a8382` | A border means "this is a choice you make". Cancel is the absence of one. This is the single change that stops Cancel looking identical to the run button, and it works in every option. |
| **D4** | Per-button pending label (F1) | **Yes** — pressed button spins and says `Creating…` / `Starting…`; the sibling keeps its real label; both stay `disabled` | Free, test-wise: `creatingGuard.spec.ts` mounts with `creating:true` and never clicks, so the `pendingAction === null` fallback preserves today's behaviour. One **new** spec added, none edited. |
| **D5** | Hover + focus ring (F2) | **Yes**, on all three | Three buttons with zero pointer affordance is the most obviously-broken thing on screen. House hover = `hover:opacity-80`; `focus-visible:ring-2` has exactly one precedent (`KanbanToolsPanel.vue:339`). |
| **D6** | `flex-wrap` (F3) | **Yes** | One class. The footer is `shrink-0` inside a `w-full` card with no `max-h`; the host owns the scroll. |
| **D7** | Subtitle copy `:1206-1212` | Flip to "Create a new task, or start an agent on it right away." | Required for coherence under D2. Confirmed: no spec asserts this string. |
| **D8** | Shorten to "Create & run"? | **No** | Saves ~95 px, costs 3 assertions, and the button stops naming its own object. Only if you tell me narrow panels are a real problem. |
| **D9** | Surface the <kbd>Enter</kbd> binding in the button `title` | **Yes** | It's existing hidden behaviour, currently undiscoverable. Free. |
| **D10** | Apply to the other three options too? | **No** | One component, one footer. |

## 4. Target result

```
create mode   [ Cancel ]        [ Create task ]        [ ▶ Create task & run agent ]
                ghost             outline                 gradient ← primary, rightmost
edit mode     [ Cancel ]        [ Save ]                [ ▶ Start agent ]
                ghost             outline                 gradient ← primary, rightmost
```

Ghost → outline → gradient is three distinct weights, ascending left to right.
The eye lands on the right edge, which is now the action <kbd>Enter</kbd> performs.

## 5. Implementation (only after approval)

Single file: `src/apps/desktop/src/components/kanban/KanbanTaskDetail.vue`.

1. **`:806` — add one local ref** next to `isCreating`:
   ```ts
   // Only the pressed commit button narrates the in-flight state; the sibling
   // keeps its label so two identical "Creating…" never appear side by side.
   const pendingAction = ref<'create' | 'create_and_run' | null>(null)
   ```
   Set in `handleSave` (`:857`) and `handleRunAgent` (`:953`) after their guards
   pass; clear on a watcher when `props.creating` returns to `false`.
   The `=== null` fallback keeps the current behaviour when the host raises
   `creating` through a path this dialog didn't initiate — that fallback is
   what makes D4 free.

2. **`:1813` — footer container**: add `flex-wrap wrap`.

3. **`:1816-1827` — Cancel**: drop `border`, set `color: var(--semantic-text-dim)`.

4. **All three buttons**: add `hover:opacity-80 focus:outline-none
   focus-visible:ring-2 focus-visible:ring-offset-2` (ring colour
   `--color-blue`). Suppress hover on disabled: `disabled:hover:opacity-50`.

5. **`:1829-1846` / `:1857-1871` — swap the two button blocks' order** and move
   the gradient from `-save` to `-create-and-run`. Keep both `data-testid`s on
   their own elements, keep `@mousedown` on the `-save` `<button>`.

6. **`:1845` / `:1870` — labels** become pending-aware, with the spinner in its
   own `<span aria-hidden="true">` so `toContain` assertions still pass.
   **No static glyph inside `-save`.**

7. **`:1206-1212` — subtitle copy** (D7).

8. **`:1867` — `title`** gains the <kbd>Enter</kbd> hint (D9).

9. **Strip the three `<!-- NEW (plan: …) -->` comments** at `:1841`, `:1848`,
   `:1872` and the stale ordering prose at `:1806-1811` and `:34`. Replace with
   plain "why" comments. Repo policy forbids `NEW (plan: …)` tags.

### Out of scope, flagged in the same PR
- `docs/SPEC.md:269` claims the Start-agent button sits "between Cancel and
  Save"; the code puts it after Save. Correct the doc alongside the reorder.
- Android (`CreateTaskUi.kt:308-329`) already has its primary rightmost and has
  no run-agent action — nothing to sync. But it labels dismiss **"Back"**, not
  "Cancel", with a written rationale at `:322-324`. Worth reading before
  keeping "Cancel" here.

## 6. Test plan

**Existing specs that must keep passing, untouched** (the reorder is invisible
to all of them — no test in the repo asserts DOM order or the footer class):

```
KanbanTaskDetailDialog.creatingGuard.spec.ts      (7 its, all touch the footer)
KanbanTaskDetailDialog.spec.ts                    (:176 cancel, :791 label, ~10 clicks)
KanbanTaskDetailDialog.runAgent.spec.ts
KanbanTaskDetailDialog.startAgent.spec.ts
KanbanTaskDetailDialog.createAttachments.spec.ts
KanbanTaskDetailDialog.useGitWorktree.spec.ts
KanbanTaskDetailDialog.profile.spec.ts
KanbanView.spec.ts                                (:779 cancel, :880-885 mousedown+click)
workspacesStoreRunAgent.spec.ts
workspacesStoreRunAgentImageUrls.spec.ts
tests/functional_ui/kanban_lifecycle_ui_test.py    (:285, :290 has-text fallback)
tests/functional_ui/kanban_profile_select_ui_test.py (:311, :412, :500)
```

**New spec** — `KanbanTaskDetailDialog.pendingLabel.spec.ts`, mirroring the
existing mount boilerplate (`attachTo: document.body` + `document.querySelector`
— the component `<Teleport>`s, so `wrapper.find` does not work):

1. press `-save` → `-save` shows a spinner and `Creating…`, `-create-and-run`
   keeps the full `Create task & run agent` label, and **both** are `disabled`.
2. press `-create-and-run` → that button shows a spinner and `Starting…`,
   `-save` keeps `Create task`, and both are `disabled`.
3. `pendingAction` stays `null` when the host raises `creating` without a click
   → both read `Creating…` (regression guard for the fallback that keeps the
   old spec green).
4. edit mode is unaffected: `-start-agent` is `disabled` when the injected
   `processingState` says a worker is running, `-save` is governed by `canSave`.

**Not a test change:** reordering, the Cancel restyle, hover/focus classes,
`flex-wrap`, and the subtitle copy. No snapshots exist in this repo and none
should be added — it asserts imperatively.

## 7. Wireframe

Open [`2026-09-29-kanban-task-detail-3-buttons-wireframe.html`](./2026-09-29-kanban-task-detail-3-buttons-wireframe.html).
Hover the drawn buttons in §3 and §7 to see the hover state the proposal adds —
on the "as shipped" row in §1, nothing happens, which is defect 4.
