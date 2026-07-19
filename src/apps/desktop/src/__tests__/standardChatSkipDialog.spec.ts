// Regression tests for the "Standard Chat — skip the New Task dialog" feature
// (2026-07-26, plan: docs/plans/2026-07-26-standard-chat-skip-dialog.md).
//
// The user wanted the Standard Chat path on the Add Task picker to be
// one-click: click "Standard Chat" → task created + ChatView opens. No
// follow-up "Enter task name… + Add a description…" dialog. Routine and
// Memory tasks still go through their own dialogs (they need schedule /
// .md content).
//
// Why source-grep instead of DOM tests? Same rationale as
// sidebarMinimalist.spec.ts: the regression we want to defend against is
// "someone re-adds the AddTaskDialog step back into the standard-chat
// flow". A source-grep on Sidebar.vue's import list + template catches
// that with zero test infrastructure. AddTaskPickerDialog.vue's comment
// grep catches "someone reverts the picker comment that documents the
// auto-create behaviour".

import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const SIDEBAR_PATH = path.resolve(__dirname, '../components/shell/Sidebar.vue')
const PICKER_PATH = path.resolve(__dirname, '../components/dialogs/AddTaskPickerDialog.vue')

const readSource = (filePath: string): string =>
  fs.readFileSync(filePath, 'utf-8')

describe('Sidebar.vue — Standard Chat skips the New Task dialog', () => {
  const source = readSource(SIDEBAR_PATH)

  it('does not import AddTaskDialog from the dialogs directory', () => {
    // The previous flow opened AddTaskDialog.vue as the second step of
    // the standard chat path. After the feature, that component is not
    // referenced by Sidebar.vue at all (the standard path auto-creates
    // the task). A grep catches accidental re-introduction.
    if (/import\s+AddTaskDialog\s+from\s+['"]\.\.\/dialogs\/AddTaskDialog\.vue['"]/.test(source)) {
      throw new Error(
        'Sidebar.vue still imports AddTaskDialog.vue. The standard-chat ' +
          'flow should auto-create the task and navigate to ChatView, not ' +
          'open a name+description dialog.',
      )
    }
  })

  it('does not render <AddTaskDialog> in its template', () => {
    // Defensive double-check: even if a future refactor adds the import
    // back as dead code, the <AddTaskDialog> template element must not
    // be present. A re-introduction here is the user-visible regression
    // we are guarding against.
    if (/<AddTaskDialog[\s>]/.test(source)) {
      throw new Error(
        'Sidebar.vue template still renders <AddTaskDialog>. The standard ' +
          'chat flow should auto-create the task and open ChatView without ' +
          'a follow-up dialog.',
      )
    }
  })

  it('does not define showAddTaskDialog ref or its companion handlers', () => {
    // The ref + the handleAddTaskCreated / handleCloseAddTaskDialog
    // trio were removed in the same commit. If any of them come back,
    // it is a strong signal someone is re-introducing the dialog path.
    if (/const\s+showAddTaskDialog\s*=/.test(source)) {
      throw new Error(
        'Sidebar.vue still declares `const showAddTaskDialog = ...`. The ' +
          'standard chat flow no longer opens AddTaskDialog.',
      )
    }
    if (/function\s+handleAddTaskCreated\s*\(/.test(source) ||
        /const\s+handleAddTaskCreated\s*=/.test(source)) {
      throw new Error(
        'Sidebar.vue still defines `handleAddTaskCreated`. The standard ' +
          'chat flow no longer calls a dialog create callback.',
      )
    }
  })

  it('handleAddTaskPick is async and creates the standard task directly via workspacesStore.addTask', () => {
    // The function must be `async` (it awaits addTask + does router.replace)
    // and must call addTask inside the `taskType === 'standard'` branch.
    // We assert the shape rather than the full body to stay focused on
    // the contract.
    const asyncMatch = source.match(/const\s+handleAddTaskPick\s*=\s*async\s*\(/)
    if (!asyncMatch) {
      throw new Error(
        'Sidebar.vue `handleAddTaskPick` is not declared async. The standard ' +
          'chat flow must await workspacesStore.addTask before router.replace.',
      )
    }

    // The `if (taskType === 'standard')` branch must call workspacesStore.addTask
    // — not set showAddTaskDialog.value = true (which is the old flow).
    // We look for the branch with the workspacesStore.addTask call sitting
    // INSIDE the standard branch by extracting the function body and
    // scanning for "standard" then "addTask" within a reasonable window.
    const bodyMatch = source.match(
      /const\s+handleAddTaskPick\s*=\s*async\s*\([^)]*\)\s*=>\s*\{([\s\S]*?)\n\}/,
    )
    if (!bodyMatch || !bodyMatch[1]) {
      throw new Error('handleAddTaskPick body not found in Sidebar.vue')
    }
    const body = bodyMatch[1]

    if (!/taskType\s*===\s*['"]standard['"]/.test(body)) {
      throw new Error(
        'handleAddTaskPick no longer checks for taskType === "standard".',
      )
    }
    // Order matters: addTask call must come AFTER the standard check.
    const standardIdx = body.search(/taskType\s*===\s*['"]standard['"]/)
    const addTaskIdx = body.indexOf('workspacesStore.addTask')
    if (addTaskIdx < 0 || addTaskIdx < standardIdx) {
      throw new Error(
        'handleAddTaskPick does not call workspacesStore.addTask inside the ' +
          'standard branch. The standard chat must auto-create the task.',
      )
    }

    // The old flow set showAddTaskDialog.value = true. That pattern must
    // be gone from handleAddTaskPick specifically. (We allow the comment
    // line "showAddTaskDialog" elsewhere in the file — the dialog component
    // is referenced in design-mode / kanban comments — so we anchor to the
    // function body.)
    if (/showAddTaskDialog\.value\s*=\s*true/.test(body)) {
      throw new Error(
        'handleAddTaskPick still sets `showAddTaskDialog.value = true`. ' +
          'The standard chat flow should not open AddTaskDialog.',
      )
    }
  })

  it('uses the DEFAULT_NEW_CHAT_NAME constant for the auto-created task', () => {
    // Pin the constant: future refactors that hard-code "New Chat"
    // (or a different name) should fail this test.
    if (!/const\s+DEFAULT_NEW_CHAT_NAME\s*=\s*['"]New Chat['"]/.test(source)) {
      throw new Error(
        'Sidebar.vue does not declare `const DEFAULT_NEW_CHAT_NAME = "New Chat"`. ' +
          'The auto-created standard chat must be named via this constant.',
      )
    }
    if (!/name:\s*DEFAULT_NEW_CHAT_NAME/.test(source)) {
      throw new Error(
        'Sidebar.vue does not pass `name: DEFAULT_NEW_CHAT_NAME` to ' +
          'workspacesStore.addTask in the standard flow.',
      )
    }
  })
})

describe('AddTaskPickerDialog.vue — comment documents the no-dialog standard path', () => {
  const source = readSource(PICKER_PATH)

  it('handleStandard emits both `pick` and `close` so the picker self-closes', () => {
    // The picker is a chooser: it must self-close on every pick so the
    // picked dialog isn't stacked on top of it. For standard there is no
    // follow-up dialog at all (the parent auto-creates the task), so the
    // self-close is the ONLY dialog-state change for that path. We
    // assert the shape rather than the full body — handleStandard is a
    // 3-line arrow function (emit pick → handleClose which emits close)
    // and the existing AddTaskPickerDialog.spec.ts already covers the
    // user-visible behavior in DOM. This grep is the static-regression
    // guard against a future refactor that drops one of the two emits.
    const handleStandardMatch = source.match(
      /const\s+handleStandard\s*=\s*\(\)\s*=>\s*\{([\s\S]*?)\n\}/,
    )
    if (!handleStandardMatch || !handleStandardMatch[1]) {
      throw new Error('handleStandard not found in AddTaskPickerDialog.vue')
    }
    const body = handleStandardMatch[1]
    if (!/emit\(\s*['"]pick['"]/.test(body)) {
      throw new Error(
        'AddTaskPickerDialog.vue handleStandard no longer emits `pick`.',
      )
    }
    if (!/emit\(\s*['"]close['"]/.test(body) && !/handleClose\(/.test(body)) {
      throw new Error(
        'AddTaskPickerDialog.vue handleStandard no longer triggers a close ' +
          '(either directly or via handleClose).',
      )
    }
  })
})
