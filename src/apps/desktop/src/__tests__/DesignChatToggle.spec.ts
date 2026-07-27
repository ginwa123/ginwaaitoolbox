/**
 * DesignChatToggle.spec.ts — static-contract regression tests for
 * the top-right chat toggle in DesignView + its handler in
 * AppLayout (2026-07-14 user feedback).
 *
 * The chat toggle has no behavioural test infra (no fake
 * workspacesStore + fake API + full DesignView harness). Static
 * contract checks are sufficient to lock in the wiring:
 *  - DesignView declares `openChat` in defineEmits
 *  - DesignView renders the button (data-testid + aria-label)
 *  - DesignView handleOpenChat emits the event
 *  - AppLayout's <DesignView> listener forwards open-chat
 *  - AppLayout's handleDesignOpenChat creates / reuses a chat
 *    task on the design item
 *  - AppLayout's template has a 3-column branch for design +
 *    activeTask (mirrors the existing kanban+chat branch)
 *  - The new branch mounts <ChatView> with the design task id
 *    as the chat-id
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

  it('declares openChat in defineEmits', () => {
    expect(source).toMatch(/openChat:\s*\[\s*\][^,}]*/)
  })

  it('renders the chat button with data-testid + aria-label', () => {
    expect(source).toContain('design-open-chat-button')
    expect(source).toContain('aria-label="Open design chat"')
  })

  it('uses the 💬 emoji (chat convention)', () => {
    expect(source).toContain('💬')
  })

  it('handleOpenChat emits openChat', () => {
    // The handler must call emit('openChat') so AppLayout's
    // @open-chat listener fires.
    expect(source).toMatch(/handleOpenChat\s*=\s*\([^)]*\)\s*:\s*void\s*=>\s*\{[^}]*emit\('openChat'\)/)
  })
})

describe('AppLayout design chat handler (handleDesignOpenChat)', () => {
  const source = readSource(APP_LAYOUT)

  it('forwards @open-chat to handleDesignOpenChat on <DesignView>', () => {
    // Find every <DesignView ...> tag and verify at least one
    // contains @open-chat="handleDesignOpenChat". The component
    // is mounted in two places (the new 3-col v-if branch AND
    // the single-col v-else-if branch); only one of them needs
    // the listener (the v-if branch is the one that renders when
    // chat is open, but the v-else-if is the "fall back to canvas
    // only" branch that ALSO receives the event for the case
    // where the user closes the chat and reopens it).
    const tagRegex = /<DesignView[\s\S]*?\/>/g
    const tags = source.match(tagRegex) ?? []
    expect(tags.length).toBeGreaterThan(0)
    const anyHasOpenChat = tags.some((tag) =>
      tag.includes('@open-chat="handleDesignOpenChat"'),
    )
    expect(anyHasOpenChat).toBe(true)
  })

  it('handleDesignOpenChat finds an existing "Design Chat" task', () => {
    // Look for the find-by-name branch: `t.name === 'Design Chat'`
    // OR `name === DESIGN_CHAT_TASK_NAME`. Either is acceptable.
    expect(source).toMatch(/name\s*===?\s*['"]Design Chat['"]|DESIGN_CHAT_TASK_NAME/)
  })

  it('handleDesignOpenChat creates a task via workspacesStore.addTask', () => {
    expect(source).toMatch(/workspacesStore\.addTask\(/)
  })

  it('handleDesignOpenChat sets activeTaskId via setActiveTask', () => {
    expect(source).toMatch(/workspacesStore\.setActiveTask\(/)
  })

  // 2026-07-26: regression test for the "Design Chat shows empty"
  // bug. The canonical-name lookup alone is broken when a user has
  // prior chats under a different-named task on the same design
  // item — the empty canonical always wins. The fix probes
  // `api.getChatHistory` to detect a real chat and falls back to
  // any other task on the design item that has messages.
  it('handleDesignOpenChat probes messages via api.getChatHistory', () => {
    // The handler must call into the chat history endpoint to
    // decide whether the canonical "Design Chat" task is empty
    // (and thus a side-effect of a prior broken click) versus a
    // real chat.
    expect(source).toMatch(/api\.getChatHistory\(/)
  })

  it('handleDesignOpenChat skips the canonical task when it is empty and falls back to a task with messages', () => {
    // Search for the canonical-find → fallback pattern. The
    // handler must NOT just call `setActiveTask(canonicalTask.id)`
    // right after the canonical lookup; it must check the
    // messages first and skip past the empty canonical when only
    // a sibling task has messages.
    //
    // The cheap structural check: the source must contain a
    // branch that continues past the canonical find when the
    // canonical is empty (the `if (hasMessages)` guards the
    // early return; the fallback loop iterates item.tasks).
    expect(source).toMatch(/if\s*\(hasMessages\)/)
    // The fallback loop scans NON-canonical tasks.
    expect(source).toMatch(/if\s*\(\s*t\.name\s*===\s*DESIGN_CHAT_TASK_NAME\s*\)\s*continue/)
  })

  it('declares the "Design Chat" task-name constant', () => {
    // Either a const declaration OR a literal in the handler body.
    expect(source).toMatch(/DESIGN_CHAT_TASK_NAME|['"]Design Chat['"]/)
  })
})

describe('AppLayout design+chat 3-column layout branch', () => {
  const source = readSource(APP_LAYOUT)

  it('renders a 3-column branch when design + activeTask', () => {
    // Look for the v-if / v-else-if combo that gates the new branch.
    // Pattern: `v-if="...activeWorkspaceItem.item_type === 'design'..."`
    // or `v-else-if="...item_type === 'design'..."` (inside a
    // v-else-if ladder). The branch must mention BOTH
    // 'design' AND `activeTask`.
    const designBranchRegex =
      /v-(?:if|else-if)="[^"]*item_type === 'design'[^"]*activeTask[^"]*"|v-(?:if|else-if)="[^"]*activeTask[^"]*item_type === 'design'[^"]*"/g
    const matches = source.match(designBranchRegex) ?? []
    expect(matches.length).toBeGreaterThan(0)
  })

  it('mounts <DesignView> AND <ChatView> inside the 3-column', () => {
    // The 3-column branch must contain BOTH components in
    // close proximity (within 4000 chars) — otherwise it's not
    // really a side-by-side layout. Find the SECOND occurrence of
    // `data-design-three-column` (the first match is a
    // `document.querySelector('[data-design-three-column] > :first-child')`
    // call in the startDesignResize handler — we want the
    // template attribute that marks the 3-column <div>).
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
    // The kanban 3-column branch binds @mousedown="startKanbanResize".
    // The design 3-column branch binds @mousedown="startDesignResize"
    // (NEW, 2026-07-25 — the design column needs different bounds,
    // 360-1100px instead of 0-720px, so it gets its own handler).
    const kanbanRegex = /data-kanban-resize-handle[^>]*@mousedown="startKanbanResize"/g
    const designRegex = /data-design-resize-handle[^>]*@mousedown="startDesignResize"/g
    expect((source.match(kanbanRegex) ?? []).length).toBeGreaterThanOrEqual(1)
    expect((source.match(designRegex) ?? []).length).toBeGreaterThanOrEqual(1)
  })
})