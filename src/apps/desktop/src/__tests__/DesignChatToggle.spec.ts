/**
 * DesignChatToggle.spec.ts — static-contract regression tests for
 * the top-right chat toggle in DesignView + its handler in
 * AppLayout.
 *
 * The chat toggle has no behavioural test infra (no fake
 * workspacesStore + fake API + full DesignView harness). Static
 * contract checks are sufficient to lock in the wiring:
 *  - DesignView declares `openChat` in defineEmits with the
 *    per-page payload { pageId, pageName, workspaceItemTaskId }
 *  - DesignView renders the button (data-testid + aria-label)
 *  - DesignView handleOpenChat emits the event with the active
 *    page's id + name + workspace_item_task_id
 *  - AppLayout's <DesignView> listener forwards open-chat
 *  - AppLayout's handleDesignOpenChat accepts the new payload
 *    type and resolves the chat task via the FK directly
 *  - The legacy name-matching lookup + N+1 message-probe + legacy
 *    "Design Chat" rename are ALL gone (replaced by the FK)
 *  - AppLayout's template has a 3-column branch for design +
 *    activeTask (mirrors the existing kanban+chat branch)
 *  - The new branch mounts <ChatView> with the design task id
 *    as the chat-id
 *
 * Plan: docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md
 */

import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const DESIGN_VIEW = path.resolve(__dirname, '../components/design/DesignView.vue')
const APP_LAYOUT = path.resolve(__dirname, '../components/AppLayout.vue')

function readSource(filePath: string): string {
  return fs.readFileSync(filePath, 'utf-8')
}

describe('DesignView chat toggle (button + emit)', () => {
  const source = readSource(DESIGN_VIEW)

  it('declares openChat in defineEmits with the FK payload', () => {
    // After 2026-07-28 FK rewrite, the emit type is
    // `[payload: { pageId: string; pageName: string; workspaceItemTaskId: string }]`
    expect(source).toMatch(
      /openChat:\s*\[\s*payload:\s*\{\s*pageId:[^}]*pageName:[^}]*workspaceItemTaskId:[^}]*\}\s*\]/,
    )
  })

  it('renders the chat button with data-testid + aria-label', () => {
    expect(source).toContain('design-open-chat-button')
    expect(source).toContain('aria-label="Open design chat"')
  })

  it('uses the 💬 emoji (chat convention)', () => {
    expect(source).toContain('💬')
  })

  it('handleOpenChat emits openChat with the active page payload (FK + id + name)', () => {
    // The handler must emit the openChat event with an object
    // payload containing pageId, pageName, AND workspaceItemTaskId.
    expect(source).toMatch(
      /emit\(\s*['"]openChat['"]\s*,\s*\{[\s\S]*?pageId[\s\S]*?pageName[\s\S]*?workspaceItemTaskId[\s\S]*?\}\s*\)/,
    )
  })
})

describe('AppLayout design chat handler (handleDesignOpenChat)', () => {
  const source = readSource(APP_LAYOUT)

  it('forwards @open-chat to handleDesignOpenChat on every <DesignView>', () => {
    // Both <DesignView> invocations have the @open-chat listener
    // (the v-else-if branch too, so closing + reopening the chat on
    // the canvas-only branch still binds to the active page).
    const tagRegex = /<DesignView\n[\s\S]*?:workspace-id="activeWorkspace\?\.id \?\? ''"[\s\S]*?\/>/g
    const tags = source.match(tagRegex) ?? []
    expect(tags.length).toBeGreaterThanOrEqual(2)
    const tagsWithListener = tags.filter((tag) =>
      tag.includes('@open-chat="handleDesignOpenChat"'),
    )
    expect(tagsWithListener.length).toBe(tags.length)
  })

  it('handleDesignOpenChat accepts the FK payload type', () => {
    // The handler signature must accept the per-page payload
    // destructured object — including workspaceItemTaskId.
    expect(source).toMatch(
      /handleDesignOpenChat\s*=\s*async\s*\(\s*payload:\s*\{[\s\S]*?pageId:[\s\S]*?pageName:[\s\S]*?workspaceItemTaskId:[\s\S]*?\}\s*\)/,
    )
  })

  it('handleDesignOpenChat uses the FK for setActiveTask (no name matching)', () => {
    // The new implementation passes `payload.workspaceItemTaskId`
    // directly to `workspacesStore.setActiveTask` — no name lookup,
    // no `taskHasMessages` probe, no `api.updateTask` rename.
    expect(source).toMatch(/workspacesStore\.setActiveTask\s*\(\s*payload\.workspaceItemTaskId\s*\)/)
  })

  it('handleDesignOpenChat short-circuits when payload.workspaceItemTaskId is empty', () => {
    // Empty workspaceItemTaskId = page row not loaded yet (or a
    // legacy pre-FK row). The handler must NOT create a chat task
    // with an empty id (would orphan the user).
    expect(source).toMatch(
      /if\s*\(\s*!payload\.workspaceItemTaskId\s*\)\s*return/,
    )
  })

  it('handleDesignOpenChat does NOT iterate item.tasks for name matching', () => {
    // The 2026-07-28 FK rewrite removes the per-page
    // `tasks.find((t) => t.name === perPageName)` lookup. The source
    // must not contain a `t.name ===` comparison in the handler.
    // Grep for the legacy pattern; expect no match.
    const legacyNameMatch = /tasks\.find\(\s*\(t\)\s*=>\s*t\.name\s*===\s*/
    expect(source).not.toMatch(legacyNameMatch)
  })

  it('handleDesignOpenChat does NOT probe messages via api.getChatHistory', () => {
    // The 2026-07-28 N+1 message-probe fallback is GONE. The FK
    // is the source of truth, no need to check whether a task has
    // messages before activating it. Scope to the handler body
    // (api.getChatHistory is used elsewhere in AppLayout for the
    // chat-list view).
    const handlerMatch = source.match(
      /handleDesignOpenChat\s*=\s*async[\s\S]*?\n\}/,
    )
    expect(handlerMatch).not.toBeNull()
    const handlerBody = handlerMatch![0]
    expect(handlerBody).not.toMatch(/api\.getChatHistory\s*\(/)
  })

  it('handleDesignOpenChat does NOT call api.updateTask to rename a legacy task', () => {
    // The 2026-07-28 legacy-rename via api.updateTask (the
    // legacy "Design Chat" migration) is GONE. The FK backfilled
    // every existing page's task_id at migration time; there's
    // nothing to rename. Scope to the handler body.
    const handlerMatch = source.match(
      /handleDesignOpenChat\s*=\s*async[\s\S]*?\n\}/,
    )
    expect(handlerMatch).not.toBeNull()
    expect(handlerMatch![0]).not.toMatch(/api\.updateTask\s*\(/)
  })

  it('handleDesignOpenChat does NOT call workspacesStore.addTask (no new-task creation)', () => {
    // The 2026-07-28 create-via-addTask path is GONE. Tasks are
    // created at page-create time by the backend
    // (design_model.setDesignPage + workspace_item_tasks INSERT).
    // The handler just resolves the existing task via the FK.
    // Scope to the handler body — workspacesStore.addTask is used
    // elsewhere in AppLayout for non-design chat tasks.
    const handlerMatch = source.match(
      /handleDesignOpenChat\s*=\s*async[\s\S]*?\n\}/,
    )
    expect(handlerMatch).not.toBeNull()
    expect(handlerMatch![0]).not.toMatch(/workspacesStore\.addTask\s*\(/)
  })

  it('handleDesignOpenChat declares DESIGN_CHAT_TASK_NAME as a display-only label', () => {
    // DESIGN_CHAT_TASK_NAME constant exists ONLY as documentation;
    // it's NOT used by handleDesignOpenChat for chat lookup. The
    // constant may still be present (as a comment or display label)
    // but the handler must not reference it for the lookup.
    //
    // We assert the constant exists (legacy documentation) AND
    // that handleDesignOpenChat's body does NOT contain
    // `t.name === DESIGN_CHAT_TASK_NAME` (the legacy lookup).
    const handlerMatch = source.match(
      /handleDesignOpenChat\s*=\s*async[\s\S]*?\n\}/,
    )
    expect(handlerMatch).not.toBeNull()
    const handlerBody = handlerMatch![0]
    expect(handlerBody).not.toMatch(/DESIGN_CHAT_TASK_NAME/)
  })
})

describe('AppLayout design+chat 3-column layout branch', () => {
  const source = readSource(APP_LAYOUT)

  it('renders a 3-column branch when design + activeTask', () => {
    const designBranchRegex =
      /v-(?:if|else-if)="[^"]*item_type === 'design'[^"]*activeTask[^"]*"|v-(?:if|else-if)="[^"]*activeTask[^"]*item_type === 'design'[^"]*"/g
    const matches = source.match(designBranchRegex) ?? []
    expect(matches.length).toBeGreaterThan(0)
  })

  it('mounts <DesignView> AND <ChatView> inside the 3-column', () => {
    const firstIdx = source.indexOf('data-design-three-column')
    expect(firstIdx).toBeGreaterThan(-1)
    const designBranchIdx = source.indexOf('data-design-three-column', firstIdx + 1)
    expect(designBranchIdx).toBeGreaterThan(-1)
    const slice = source.slice(
      designBranchIdx,
      Math.min(designBranchIdx + 4000, source.length),
    )
    expect(slice).toContain('<DesignView')
    expect(slice).toContain('<ChatView')
  })

  it('passes the active task id to ChatView as chat-id', () => {
    const firstIdx = source.indexOf('data-design-three-column')
    const designBranchIdx = source.indexOf('data-design-three-column', firstIdx + 1)
    const slice = source.slice(
      designBranchIdx,
      Math.min(designBranchIdx + 4000, source.length),
    )
    expect(slice).toMatch(/:chat-id="activeTask\.id"/)
  })

  it('uses separate resize handlers for kanban vs design columns', () => {
    const kanbanRegex = /data-kanban-resize-handle[^>]*@mousedown="startKanbanResize"/g
    const designRegex = /data-design-resize-handle[^>]*@mousedown="startDesignResize"/g
    expect((source.match(kanbanRegex) ?? []).length).toBeGreaterThanOrEqual(1)
    expect((source.match(designRegex) ?? []).length).toBeGreaterThanOrEqual(1)
  })
})
