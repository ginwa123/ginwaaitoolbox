/**
 * AddDesignDialog.spec.ts — static-contract regression tests
 *
 * The "Add Design" flow has no behavioural test infra (no full
 * component harness with Pinia + a fake /api/workspaces/:wsId/items/design
 * endpoint + a fake FilePickerDialog). It is plumbed end-to-end via
 * 4 files:
 *
 *   1. components/AddDesignDialog.vue
 *      — modal with name input + folder picker → emits `create(name, path)`
 *   2. components/WorkspaceList.vue
 *      — "+ Add Item" dropdown offers "Add Design" (3rd option)
 *   3. components/Sidebar.vue
 *      — handleAddItem routes the 'design' itemType to AddDesignDialog
 *      — handleCreateDesign calls workspacesStore.addDesignItem(...)
 *      — <AddDesignDialog> is mounted with show + handlers
 *   4. stores/workspaces.ts
 *      — addDesignItem action is exported from the `return {}` block
 *      — addDesignItem POSTs to /api/workspaces/:wsId/items/design
 *
 * These tests assert the structural contract — grep each file for
 * the required substring. A failure here means a future refactor
 * silently broke the wiring (the type-check would catch most of
 * these via Pinia's Store<...> typing, but type-check cannot catch
 * a missing dropdown option or a removed event handler).
 */

import { describe, test, expect } from 'vitest'
import * as fs from 'node:fs'

const SIDEBAR = 'src/components/shell/Sidebar.vue'
const WORKSPACE_LIST = 'src/components/workspace/WorkspaceList.vue'
const DIALOG = 'src/components/design/AddDesignDialog.vue'
const STORE = 'src/stores/workspaces.ts'

function readSource(relPath: string): string {
  return fs.readFileSync(relPath, 'utf-8')
}

describe('AddDesignDialog component exists with required structure', () => {
  test('renders a name input', () => {
    const src = readSource(DIALOG)
    expect(src).toMatch(/data-testid="add-design-name"/)
    expect(src).toMatch(/placeholder="Design System"/)
  })

  test('renders a folder picker trigger', () => {
    const src = readSource(DIALOG)
    expect(src).toMatch(/data-testid="add-design-choose-folder"/)
  })

  test('renders Cancel + Add actions, Add disabled until valid', () => {
    const src = readSource(DIALOG)
    expect(src).toMatch(/data-testid="add-design-cancel"/)
    expect(src).toMatch(/data-testid="add-design-submit"/)
    expect(src).toMatch(/:disabled="!name\.trim\(\) \|\| !selectedPath"/)
  })

  test('emits create(name, path) on submit', () => {
    const src = readSource(DIALOG)
    // The `create` emit type definition — Vue 3's `defineEmits<{...}>()`
    // syntax uses `create: [name: string, path: string]`.
    expect(src).toMatch(
      /create:\s*\[name:\s*string,\s*path:\s*string\]/,
    )
    // And the actual emit call passes both args.
    expect(src).toMatch(/emit\('create',\s*trimmedName,\s*selectedPath\.value\)/)
  })

  test('uses FilePickerDialog in folder mode', () => {
    const src = readSource(DIALOG)
    expect(src).toMatch(/<FilePickerDialog/)
    expect(src).toMatch(/mode="folder"/)
  })
})

describe('WorkspaceList dropdown offers Add Design', () => {
  test('Add Design button has the design itemType', () => {
    const src = readSource(WORKSPACE_LIST)
    expect(src).toMatch(
      /@click="handleAddItem\(workspace\.id, 'design'\)"/,
    )
  })

  test('Add Design button is visible as a dropdown option', () => {
    const src = readSource(WORKSPACE_LIST)
    expect(src).toMatch(/data-testid="workspace-add-design-option"/)
    expect(src).toMatch(/>\s*Add Design\s*</)
  })
})

describe('Sidebar routes design itemType to AddDesignDialog', () => {
  test("handleAddItem has a 'design' branch that opens AddDesignDialog", () => {
    const src = readSource(SIDEBAR)
    expect(src).toMatch(/itemType === 'design'/)
    expect(src).toMatch(/showAddDesignDialog\.value = true/)
  })

  test('imports AddDesignDialog', () => {
    const src = readSource(SIDEBAR)
    expect(src).toMatch(/import AddDesignDialog from '\.\.\/design\/AddDesignDialog\.vue'/)
  })

  test('mounts <AddDesignDialog> with show + close + create handlers', () => {
    const src = readSource(SIDEBAR)
    expect(src).toMatch(
      /<AddDesignDialog\s+:show="showAddDesignDialog"/,
    )
    expect(src).toMatch(/@close="handleCloseAddDesignDialog"/)
    expect(src).toMatch(/@create="handleCreateDesign"/)
  })

  test('handleCreateDesign calls workspacesStore.addDesignItem', () => {
    const src = readSource(SIDEBAR)
    expect(src).toMatch(/workspacesStore\.addDesignItem\(/)
  })
})

describe('workspacesStore exports addDesignItem', () => {
  test('addDesignItem function is defined', () => {
    const src = readSource(STORE)
    expect(src).toMatch(/async function addDesignItem\(/)
  })

  test('addDesignItem is exported via the Pinia return block', () => {
    const src = readSource(STORE)
    expect(src).toMatch(/addDesignItem,?\s*\n\s*addKanbanColumn/)
  })

  test('addDesignItem POSTs to /api/workspaces/.../items/design via api.createDesign', () => {
    const src = readSource(STORE)
    expect(src).toMatch(/api\.createDesign\(/)
  })
})