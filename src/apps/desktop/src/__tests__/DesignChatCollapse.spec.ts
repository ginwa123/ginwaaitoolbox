/**
 * DesignChatCollapse.spec.ts — static-contract regression tests for
 * the design+chat 3-column layout's collapse feature (2026-07-25).
 *
 * Two changes shipped together:
 *
 * 1. The design column got its OWN sizing constants + resize handler
 *    (`DESIGN_MIN_WIDTH=360`, `DESIGN_DEFAULT_WIDTH=65%`,
 *    `DESIGN_MAX_WIDTH=1100`, persisted as `design-column-width`).
 *    Before this, design shared the kanban constants (40% default,
 *    720px max), which squeezed the canvas into ~40% of the main
 *    area minus the 320px internal Layers+Properties sidebar — a
 *    visibly cramped layout (user feedback 2026-07-25).
 *
 * 2. A new `designChatCollapsed` ref + `toggleDesignChat` handler
 *    let the user collapse the chat column to a thin strip (just a
 *    💬 icon button) with one click, persisting across reloads via
 *    the `design-chat-collapsed` localStorage key.
 *
 * Static contract checks lock both wirings (constants, handler,
 * template testids, persisted keys) so any future regression that
 * re-uses the kanban handler / constants / strips the chat-collapse
 * buttons fails this file.
 */

import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const APP_LAYOUT = path.resolve(__dirname, '../components/AppLayout.vue')

function readSource(): string {
  return fs.readFileSync(APP_LAYOUT, 'utf-8')
}

describe('AppLayout — design column sizing (separate from kanban)', () => {
  const source = readSource()

  it('declares design-specific bounds (DESIGN_MIN_WIDTH=360)', () => {
    // The min-width must be higher than kanban's 0 floor so the
    // design canvas never collapses below usable width.
    expect(source).toMatch(/const\s+DESIGN_MIN_WIDTH\s*=\s*360/)
  })

  it('declares design-specific default width (65%, not the kanban 40%)', () => {
    // 65% default is the dominant fix for the cramped-canvas UX.
    expect(source).toMatch(/const\s+DESIGN_DEFAULT_WIDTH\s*=\s*65/)
    // And explicitly NOT 40 (kanban's default).
    expect(source).not.toMatch(/const\s+DESIGN_DEFAULT_WIDTH\s*=\s*40/)
  })

  it('declares design-specific MAX_WIDTH (1100px, not the kanban 720px)', () => {
    // A Figma-style page is 1440px wide; 1100px gives the canvas +
    // internal sidebar enough room without starving the chat panel.
    expect(source).toMatch(/const\s+DESIGN_MAX_WIDTH\s*=\s*1100/)
    expect(source).not.toMatch(/const\s+DESIGN_MAX_WIDTH\s*=\s*720/)
  })

  it('persists design width under a SEPARATE localStorage key', () => {
    // Sharing the kanban key would bleed prefs across modes —
    // resizing a kanban column would also resize a design column.
    expect(source).toMatch(/DESIGN_WIDTH_STORAGE_KEY\s*=\s*['"]design-column-width['"]/)
    // And the kanban key stays distinct.
    expect(source).toMatch(/KANBAN_WIDTH_STORAGE_KEY\s*=\s*['"]kanban-column-width['"]/)
  })

  it('loads the design width via loadDesignColumnWidth (not the kanban helper)', () => {
    expect(source).toContain('loadDesignColumnWidth')
    expect(source).toMatch(/designColumnWidth\s*=\s*ref<number\s*\|\s*null>\(loadDesignColumnWidth\(\)\)/)
  })

  it('exposes designColumnStyle computed with the new bounds', () => {
    expect(source).toContain('designColumnStyle')
    // The default-percent branch must reference the design default,
    // not the kanban default.
    const styleMatch = source.match(/const\s+designColumnStyle\s*=\s*computed\(\(\)\s*=>\s*\{[\s\S]*?flex:\s*`0 1 \$\{DESIGN_DEFAULT_WIDTH\}%`[\s\S]*?\}\)/)
    expect(styleMatch).not.toBeNull()
  })

  it('3-column design branch binds :style to designColumnStyle (NOT kanbanColumnStyle)', () => {
    // Find the design 3-column <div> (data-design-three-column) and
    // verify its first child uses designColumnStyle. We accept
    // whitespace variations in :style binding.
    const firstIdx = source.indexOf('data-design-three-column')
    expect(firstIdx).toBeGreaterThan(-1)
    const templateIdx = source.indexOf('data-design-three-column', firstIdx + 1)
    expect(templateIdx).toBeGreaterThan(-1)
    const slice = source.slice(
      templateIdx,
      Math.min(templateIdx + 1500, source.length),
    )
    expect(slice).toMatch(/:style\s*=\s*["']designColumnStyle["']/)
    expect(slice).not.toMatch(/:style\s*=\s*["']kanbanColumnStyle["']/)
  })

  it('3-column design branch uses startDesignResize (NOT startKanbanResize)', () => {
    const firstIdx = source.indexOf('data-design-three-column')
    const templateIdx = source.indexOf('data-design-three-column', firstIdx + 1)
    const slice = source.slice(
      templateIdx,
      Math.min(templateIdx + 2000, source.length),
    )
    expect(slice).toMatch(/@mousedown\s*=\s*["']startDesignResize["']/)
    expect(slice).toMatch(/:class\s*=\s*["']isDesignResizing\s*\?/)
  })

  it('measures drag start width via [data-design-three-column] selector (not kanban)', () => {
    // startDesignResize's percentage→px measurement must use the
    // design-specific selector — sharing the kanban selector would
    // measure the kanban column width when starting a drag from a
    // percentage-sized design column.
    expect(source).toMatch(/document\.querySelector\(\s*['"]\[data-design-three-column\]/);
  })
})

describe('AppLayout — design chat panel collapse', () => {
  const source = readSource()

  it('declares a design-chat-collapsed localStorage key', () => {
    expect(source).toMatch(/DESIGN_CHAT_COLLAPSED_KEY\s*=\s*['"]design-chat-collapsed['"]/)
  })

  it('initializes designChatCollapsed ref from loadDesignChatCollapsed()', () => {
    expect(source).toContain('loadDesignChatCollapsed')
    expect(source).toMatch(/designChatCollapsed\s*=\s*ref<boolean>\(loadDesignChatCollapsed\(\)\)/)
  })

  it('exposes a toggleDesignChat handler that persists state', () => {
    expect(source).toContain('const toggleDesignChat')
    // The handler must persist on every toggle so a reload preserves
    // the user's choice.
    expect(source).toMatch(
      /localStorage\.setItem\(\s*DESIGN_CHAT_COLLAPSED_KEY\s*,\s*designChatCollapsed\.value\s*\?\s*['"]1['"]\s*:\s*['"]0['"]\s*\)/,
    )
  })

  it('renders a collapse-button testid on the chat column', () => {
    // The "»" floating button in the chat column header has
    // data-testid="design-chat-collapse-button".
    const firstIdx = source.indexOf('data-design-three-column')
    const templateIdx = source.indexOf('data-design-three-column', firstIdx + 1)
    const slice = source.slice(
      templateIdx,
      Math.min(templateIdx + 5000, source.length),
    )
    expect(slice).toContain('design-chat-collapse-button')
  })

  it('renders an expand-button testid on the collapsed strip', () => {
    const firstIdx = source.indexOf('data-design-three-column')
    const templateIdx = source.indexOf('data-design-three-column', firstIdx + 1)
    const slice = source.slice(
      templateIdx,
      Math.min(templateIdx + 6000, source.length),
    )
    expect(slice).toContain('design-chat-expand-button')
    // And the collapsed-strip wrapper.
    expect(slice).toContain('data-design-chat-collapsed-strip')
    // And the open chat column wrapper.
    expect(slice).toContain('data-design-chat-column')
  })

  it('uses v-if/v-else to swap open vs collapsed chat', () => {
    const firstIdx = source.indexOf('data-design-three-column')
    const templateIdx = source.indexOf('data-design-three-column', firstIdx + 1)
    const slice = source.slice(
      templateIdx,
      Math.min(templateIdx + 6000, source.length),
    )
    // Both branches must exist within the design 3-column block.
    expect(slice).toMatch(/v-if\s*=\s*["']!designChatCollapsed["']/);
    expect(slice).toMatch(/v-else/);
  })
})
