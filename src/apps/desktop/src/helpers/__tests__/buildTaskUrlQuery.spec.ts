/**
 * Behavioural tests for `buildTaskUrlQuery` and `pickBreadcrumbFromQuery`.
 *
 * Plan: docs/superpowers/plans/2026-08-06-add-workspace-id-params.md
 *
 * The user's report (task_1785774094183): task URLs were missing
 * `workspaceId`. The helper centralises URL building for `view=task`
 * navigation so every call site gets the same behaviour: workspaceId
 * included whenever a workspace item is actively selected.
 */
import { describe, expect, it } from 'vitest'
import {
  buildTaskUrlQuery,
  pickBreadcrumbFromQuery,
} from '../buildTaskUrlQuery'

describe('buildTaskUrlQuery — always emits workspaceId when store has it (task_1785774094183)', () => {
  it('includes workspaceId + itemId when active workspace + item are set', () => {
    const query = buildTaskUrlQuery({
      taskId: 'task_1',
      activeWorkspaceId: 'ws_a',
      activeWorkspaceItemId: 'item_kanban',
    })
    expect(query.view).toBe('task')
    expect(query.task).toBe('task_1')
    expect(query.workspaceId).toBe('ws_a')
    expect(query.itemId).toBe('item_kanban')
  })

  it('includes pageId only when active item is a design', () => {
    const design = buildTaskUrlQuery({
      taskId: 'task_1',
      activeWorkspaceId: 'ws_a',
      activeWorkspaceItemId: 'item_design',
      activeDesignPageId: 'page_xyz',
      activeItemType: 'design',
    })
    expect(design.pageId).toBe('page_xyz')

    const kanban = buildTaskUrlQuery({
      taskId: 'task_1',
      activeWorkspaceId: 'ws_a',
      activeWorkspaceItemId: 'item_kanban',
      activeDesignPageId: 'page_xyz', // stale from a prior design
      activeItemType: 'kanban',
    })
    expect(kanban.pageId).toBeUndefined()

    const folder = buildTaskUrlQuery({
      taskId: 'task_1',
      activeWorkspaceId: 'ws_a',
      activeWorkspaceItemId: 'item_folder',
      activeDesignPageId: 'page_xyz', // stale from a prior design
      activeItemType: 'folder',
    })
    expect(folder.pageId).toBeUndefined()
  })

  it('omits pageId when activeItemType is missing even if activeDesignPageId is set', () => {
    // Defensive: callers that don't pass activeItemType shouldn't
    // accidentally write pageId. The pageId leak fix relies on the
    // caller knowing the active item's type.
    const query = buildTaskUrlQuery({
      taskId: 'task_1',
      activeWorkspaceId: 'ws_a',
      activeWorkspaceItemId: 'item_kanban',
      activeDesignPageId: 'page_xyz',
      // activeItemType omitted
    })
    expect(query.pageId).toBeUndefined()
  })

  it('omits workspaceId + itemId when neither store nor URL has them (deep-link)', () => {
    const query = buildTaskUrlQuery({
      taskId: 'task_1',
    })
    expect(query.view).toBe('task')
    expect(query.task).toBe('task_1')
    expect(query.workspaceId).toBeUndefined()
    expect(query.itemId).toBeUndefined()
  })

  it('falls back to URL breadcrumb when store has no active workspace', () => {
    // The user landed on the task via a deep link with workspaceId
    // already in the URL. The new task URL must preserve that
    // breadcrumb so a refresh / share keeps the context.
    const query = buildTaskUrlQuery({
      taskId: 'task_1',
      currentQuery: {
        view: 'task',
        workspaceId: 'ws_a',
        itemId: 'item_kanban',
        sorts: 'col_a:name:asc',
      },
    })
    expect(query.workspaceId).toBe('ws_a')
    expect(query.itemId).toBe('item_kanban')
    expect(query.sorts).toBe('col_a:name:asc')
  })

  it('prefers active store state over URL breadcrumb when both exist', () => {
    // The store is the source of truth. If the user is actively on
    // ws_b/kanban_b but the URL still shows ws_a/kanban_a (stale
    // deep-link reload), the new task URL must use the active state.
    const query = buildTaskUrlQuery({
      taskId: 'task_1',
      activeWorkspaceId: 'ws_b',
      activeWorkspaceItemId: 'kanban_b',
      currentQuery: {
        view: 'task',
        workspaceId: 'ws_a',
        itemId: 'kanban_a',
      },
    })
    expect(query.workspaceId).toBe('ws_b')
    expect(query.itemId).toBe('kanban_b')
  })

  it('includes session when sessionId is passed (routine-run path)', () => {
    const query = buildTaskUrlQuery({
      taskId: 'task_1',
      sessionId: 'task_1',
      activeWorkspaceId: 'ws_a',
      activeWorkspaceItemId: 'item_kanban',
    })
    expect(query.task).toBe('task_1')
    expect(query.session).toBe('task_1')
    expect(query.workspaceId).toBe('ws_a')
  })

  it('omits session when sessionId is not passed', () => {
    const query = buildTaskUrlQuery({
      taskId: 'task_1',
      activeWorkspaceId: 'ws_a',
      activeWorkspaceItemId: 'item_kanban',
    })
    expect(query.session).toBeUndefined()
  })

  it('handles empty-string active ids as "no active context" (falls back to URL)', () => {
    // Defensive: Vue refs can be null OR empty string depending on
    // the watcher chain. Both should behave the same.
    const query = buildTaskUrlQuery({
      taskId: 'task_1',
      activeWorkspaceId: '',
      activeWorkspaceItemId: '',
      currentQuery: {
        workspaceId: 'ws_a',
        itemId: 'item_kanban',
      },
    })
    expect(query.workspaceId).toBe('ws_a')
    expect(query.itemId).toBe('item_kanban')
  })

  it('handles null active ids as "no active context" (falls back to URL)', () => {
    const query = buildTaskUrlQuery({
      taskId: 'task_1',
      activeWorkspaceId: null,
      activeWorkspaceItemId: null,
      currentQuery: {
        workspaceId: 'ws_a',
        itemId: 'item_kanban',
      },
    })
    expect(query.workspaceId).toBe('ws_a')
    expect(query.itemId).toBe('item_kanban')
  })

  it('trims whitespace from active ids (defensive)', () => {
    // Edge case: a stray whitespace string (e.g. " ws_a ") would
    // otherwise be written verbatim to the URL.
    const query = buildTaskUrlQuery({
      taskId: 'task_1',
      activeWorkspaceId: '  ws_a  ',
      activeWorkspaceItemId: '  item_kanban  ',
    })
    expect(query.workspaceId).toBe('ws_a')
    expect(query.itemId).toBe('item_kanban')
  })
})

describe('pickBreadcrumbFromQuery — extracts breadcrumb scalars', () => {
  it('picks workspaceId, itemId, pageId, sorts when all are strings', () => {
    const out = pickBreadcrumbFromQuery({
      workspaceId: 'ws_a',
      itemId: 'item_kanban',
      pageId: 'page_x',
      sorts: 'col_a:name:asc',
      view: 'task', // not breadcrumb — ignored
      session: 'task_1', // not breadcrumb — ignored
    })
    expect(out).toEqual({
      workspaceId: 'ws_a',
      itemId: 'item_kanban',
      pageId: 'page_x',
      sorts: 'col_a:name:asc',
    })
  })

  it('skips empty strings (does NOT coalesce empty to undefined)', () => {
    const out = pickBreadcrumbFromQuery({
      workspaceId: '',
      itemId: 'item_kanban',
    })
    expect(out.workspaceId).toBeUndefined()
    expect(out.itemId).toBe('item_kanban')
  })

  it('skips non-string values (null, arrays)', () => {
    const out = pickBreadcrumbFromQuery({
      workspaceId: null,
      itemId: ['item_a', 'item_b'] as unknown as string, // vue-router LocationQuery allows arrays
    })
    expect(out.workspaceId).toBeUndefined()
    expect(out.itemId).toBeUndefined()
  })

  it('returns empty object when no breadcrumb keys present', () => {
    const out = pickBreadcrumbFromQuery({
      view: 'chat',
      session: 'task_1',
    })
    expect(out).toEqual({})
  })
})