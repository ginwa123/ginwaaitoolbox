// Static-contract regression test: when an active workspace item has
// `item_type === 'kanban'` or `'design'`, the workspace-memories view
// branch in AppLayout.vue must NOT render <WorkspaceItemMemoriesView>,
// even if the item has a `path` set. This locks in the fix for the
// duplicate-header / wrong-view bug where a kanban was showing the
// memories list instead of the kanban board (KanbanView branch should
// win in the v-else-if chain, but the defensive `item_type` guard
// prevents regressions if the chain order changes in the future).
//
// See plan: docs/superpowers/plans/2026-07-21-local-memories-workspace-item.md

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const APPLAYOUT_PATH = resolve(
  __dirname,
  '..',
  'components',
  'AppLayout.vue',
)

describe('AppLayout — workspace memories view guard', () => {
  const source = readFileSync(APPLAYOUT_PATH, 'utf-8')

  it('excludes kanban items from the memories view branch', () => {
    // The defensive gate must include item_type !== 'kanban'.
    expect(source).toContain("activeWorkspaceItem.item_type !== 'kanban'")
  })

  it('excludes design items from the memories view branch', () => {
    expect(source).toContain("activeWorkspaceItem.item_type !== 'design'")
  })

  it('does NOT render a redundant outer compact header card', () => {
    // Bug: the outer header duplicated WorkspaceItemMemoriesView's own
    // header. Verify the outer header markup is gone.
    expect(source).not.toContain('Compact header card (always shown when an item is active)')
  })

  it('keeps the no-path centered card fallback', () => {
    // The original "today's centered card" must remain when path is empty.
    expect(source).toContain('No-path fallback: keep today\'s centered card')
  })

  it('keeps the kanban branch BEFORE the workspace view branch', () => {
    const kanbanIdx = source.indexOf(
      "v-else-if=\"activeWorkspaceItem && activeWorkspaceItem.item_type === 'kanban'\"",
    )
    const workspaceIdx = source.indexOf("v-else-if=\"currentView === 'workspace'\"")
    expect(kanbanIdx).toBeGreaterThan(0)
    expect(workspaceIdx).toBeGreaterThan(0)
    expect(kanbanIdx).toBeLessThan(workspaceIdx)
  })
})