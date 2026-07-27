/**
 * DesignChatToggle.spec.ts — static-contract regression tests for
 * the top-right chat toggle in DesignView + its handler in
 * AppLayout.
 *
 * The chat toggle has no behavioural test infra (no fake
 * workspacesStore + fake API + full DesignView harness). Static
 * contract checks are sufficient to lock in the wiring:
 *  - DesignView declares `openChat` in defineEmits with the
 *    per-page { pageId, pageName } payload
 *  - DesignView renders the button (data-testid + aria-label)
 *  - DesignView handleOpenChat emits the event with the active
 *    page's id + name (NOT a bare emit)
 *  - AppLayout's <DesignView> listener forwards open-chat
 *  - AppLayout's handleDesignOpenChat accepts (pageId, pageName)
 *    and looks up the per-page task by name "Design Chat: <page>"
 *  - When a legacy "Design Chat" task exists with messages, the
 *    handler renames it via api.updateTask (NOT a fresh create)
 *  - When no per-page task exists, the handler creates one via
 *    workspacesStore.addTask with name "Design Chat: <page>"
 *  - The N+1 message-probe fallback loop is GONE (replaced by the
 *    deterministic per-page lookup)
 *  - AppLayout's template has a 3-column branch for design +
 *    activeTask (mirrors the existing kanban+chat branch)
 *  - The new branch mounts <ChatView> with the design task id
 *    as the chat-id
 *
 * Plan: docs/superpowers/plans/2026-07-28-design-per-page-chat-sessions.md
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

  it('declares openChat in defineEmits with the per-page payload', () => {
    // After 2026-07-28, the emit type is `[payload: { pageId: string; pageName: string }]`
    // (NOT the old bare `[]` — that's the single-canonical shape).
    expect(source).toMatch(/openChat:\s*\[\s*payload:\s*\{\s*pageId:[^}]*pageName:[^}]*\}\s*\]/)
  })

  it('renders the chat button with data-testid + aria-label', () => {
    expect(source).toContain('design-open-chat-button')
    expect(source).toContain('aria-label="Open design chat"')
  })

  it('uses the 💬 emoji (chat convention)', () => {
    expect(source).toContain('💬')
  })

  it('handleOpenChat emits openChat with the active page payload', () => {
    // The handler must call emit('openChat', { pageId, pageName })
    // — NOT a bare emit('openChat'). Verify both the literal
    // emit-name AND the object-shaped payload appear on the same
    // emit call.
    expect(source).toMatch(/emit\(\s*['"]openChat['"]\s*,\s*\{[\s\S]*?pageId[\s\S]*?pageName[\s\S]*?\}\s*\)/)
  })
})

describe('AppLayout design chat handler (handleDesignOpenChat)', () => {
  const source = readSource(APP_LAYOUT)

  it('forwards @open-chat to handleDesignOpenChat on every <DesignView>', () => {
    // 2026-07-28: both <DesignView> invocations now have the
    // @open-chat listener (the v-else-if branch too, so closing +
    // reopening the chat on the canvas-only branch still binds to
    // the active page).
    //
    // Match real Vue self-closing tags by requiring a `\n` right
    // after `<DesignView` (real tags open on their own line) AND
    // a `:workspace-id=` binding (only real tags carry this).
    // The previous regex accidentally captured `// <DesignView>`
    // comments, which don't have real attributes.
    const tagRegex = /<DesignView\n[\s\S]*?:workspace-id="activeWorkspace\?\.id \?\? ''"[\s\S]*?\/>/g
    const tags = source.match(tagRegex) ?? []
    expect(tags.length).toBeGreaterThanOrEqual(2)
    const tagsWithListener = tags.filter((tag) =>
      tag.includes('@open-chat="handleDesignOpenChat"'),
    )
    expect(tagsWithListener.length).toBe(tags.length)
  })

  it('handleDesignOpenChat accepts a (pageId, pageName) payload', () => {
    // The handler signature must accept the per-page payload
    // destructured object — NOT zero args (the pre-2026-07-28
    // shape) or a single string id (a different mistake).
    expect(source).toMatch(
      /handleDesignOpenChat\s*=\s*async\s*\(\s*payload:\s*\{\s*pageId:[^}]*pageName:[^}]*\}\s*\)/,
    )
  })

  it('handleDesignOpenChat looks up the per-page canonical "Design Chat: <pageName>"', () => {
    // Look for the per-page name construction. The current handler
    // builds it via a PER_PAGE_CHAT_PREFIX constant + template
    // literal: `${PER_PAGE_CHAT_PREFIX}${payload.pageName}`. Match
    // EITHER that constant-prefix form OR the direct template
    // literal form (`Design Chat: ${payload.pageName}` /
    // 'Design Chat: ' + payload.pageName). What is NOT acceptable
    // is a bare `Design Chat` constant used as the task lookup
    // name (the pre-fix single-canonical shape).
    const perPageConstantForm =
      /\$\{PER_PAGE_CHAT_PREFIX\}\$\{payload\.pageName\}/
    const perPageTemplateLiteral =
      /[`'"]Design Chat: [`'"][^`'"]*\$\{payload\.pageName\}/
    const perPageConcat =
      /[`'"]Design Chat: [`'"]\s*\+\s*payload\.pageName/
    const perPageNameAssigned =
      /const\s+perPageName\s*=\s*[`'"][^`'"]*payload\.pageName/
    expect(
      perPageConstantForm.test(source) ||
        perPageTemplateLiteral.test(source) ||
        perPageConcat.test(source) ||
        perPageNameAssigned.test(source),
    ).toBe(true)
  })

  it('handleDesignOpenChat retains DESIGN_CHAT_TASK_NAME constant for legacy migration', () => {
    // The legacy constant must still exist — it's used by Step 2
    // (legacy rename) to find the pre-fix "Design Chat" canonical.
    expect(source).toMatch(/DESIGN_CHAT_TASK_NAME\s*=\s*['"]Design Chat['"]/)
  })

  it('handleDesignOpenChat renames the legacy task via api.updateTask', () => {
    // The migration path calls api.updateTask with the legacy
    // task's id and a `name: perPageName` patch. This preserves
    // the task id (and llm_history rows keyed on it) — only the
    // name changes.
    expect(source).toMatch(/api\.updateTask\([^)]*name:\s*perPageName/m)
  })

  it('handleDesignOpenChat does NOT iterate all item.tasks for the message-probe fallback', () => {
    // The 2026-07-26 N+1 message-probe fallback loop is GONE.
    // The per-page lookup is deterministic; no need to scan all
    // tasks. A regex-negative: the source must not contain
    // `for (const t of item.tasks)` inside the handler.
    // We check the global source minus the constant declaration
    // for the legacy-migration loop (which is intentional and
    // doesn't probe messages).
    //
    // Note: a `for...of item.tasks` inside `item.tasks?.find(...)`
    // calls or `for await` loops is fine; only the
    //   `for (const t of item.tasks) { ... taskHasMessages ... }`
    // shape is forbidden.
    const messageProbeLoop =
      /for\s*\(\s*const\s+t\s+of\s+item\.tasks\s*\)\s*\{[^}]*taskHasMessages/
    expect(source).not.toMatch(messageProbeLoop)
  })

  it('handleDesignOpenChat creates a per-page task via workspacesStore.addTask', () => {
    // When no per-page task exists and no legacy-to-migrate, the
    // handler creates a fresh task via the existing addTask path
    // with the per-page name (NOT the legacy "Design Chat" name).
    expect(source).toMatch(/workspacesStore\.addTask\([^)]*name:\s*perPageName/m)
  })

  it('handleDesignOpenChat sets activeTaskId via setActiveTask', () => {
    expect(source).toMatch(/workspacesStore\.setActiveTask\(/)
  })

  it('handleDesignOpenChat probes legacy task messages via api.getChatHistory', () => {
    // The migration path still uses the cheap `getChatHistory`
    // probe (via the `taskHasMessages` helper) to decide whether
    // the legacy "Design Chat" task has messages (and is thus
    // worth migrating) vs. is empty (a prior-broken-click
    // artifact to skip).
    //
    // We accept EITHER a direct `api.getChatHistory(legacyTask.id)`
    // call OR the indirect `taskHasMessages(legacyTask.id)` call
    // (which calls `api.getChatHistory` internally).
    const direct = /api\.getChatHistory\([^)]*legacyTask\.id/
    const indirect = /taskHasMessages\(\s*legacyTask\.id\s*\)/
    expect(direct.test(source) || indirect.test(source)).toBe(true)
  })

  it('handleDesignOpenChat short-circuits when payload.pageId or payload.pageName is empty', () => {
    // DesignView emits empty values when the active page isn't
    // loaded yet; the handler must NOT create a chat task with an
    // empty name (would orphan future migrations).
    expect(source).toMatch(/if\s*\(\s*!payload\.pageId\s*\|\|\s*!payload\.pageName\s*\)\s*return/)
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
