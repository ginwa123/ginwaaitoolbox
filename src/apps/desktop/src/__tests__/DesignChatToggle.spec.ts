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
    // close proximity (within 3000 chars) — otherwise it's not
    // really a side-by-side layout.
    const designBranchIdx = source.indexOf("data-design-three-column")
    expect(designBranchIdx).toBeGreaterThan(-1)
    const slice = source.slice(
      designBranchIdx,
      Math.min(designBranchIdx + 4000, source.length),
    )
    expect(slice).toContain('<DesignView')
    expect(slice).toContain('<ChatView')
  })

  it('passes the active task id to ChatView as chat-id', () => {
    const slice = source.slice(
      source.indexOf('data-design-three-column'),
      Math.min(source.indexOf('data-design-three-column') + 4000, source.length),
    )
    expect(slice).toMatch(/:chat-id="activeTask\.id"/)
  })

  it('shares the resize handle component pattern with the kanban branch', () => {
    // Same data-testid prefix? Actually the kanban one is
    // 'kanban-resize-handle' and the design one is
    // 'design-resize-handle' (different ids to avoid selector
    // collisions in E2E tests). What we DO want: both branches
    // use the same SVG dot pattern + the same @mousedown handler.
    const handleRegex = /data-(?:kanban|design)-resize-handle[^>]*@mousedown="startKanbanResize"/g
    const matches = source.match(handleRegex) ?? []
    // At least 2 hits (one for kanban, one for design).
    expect(matches.length).toBeGreaterThanOrEqual(2)
  })
})