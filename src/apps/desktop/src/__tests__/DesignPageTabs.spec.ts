/**
 * Static source-grep tests for DesignPageTabs.vue (Chunk 7 of
 * design-mode-redesign plan).
 *
 * Pattern mirrors sidebarMinimalist.spec.ts — read the source file
 * as text and assert the structural contracts (emits, data-testid,
 * key bindings) so a future refactor can't silently regress the
 * parent contract (DesignView emits the same `selectPage`, `addPage`,
 * `deletePage` events back to AppLayout in Chunk 8).
 *
 * Why static-grep instead of behavioral tests? The component is
 * purely presentational — the parent owns all state. Behavioral
 * tests would mount the component with a fixture and exercise the
 * click handlers, but the static contract is what Chunk 8 actually
 * depends on (the emit names + the data-testid selectors used by
 * Playwright/E2E tests).
 */
import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const SOURCE_PATH = path.resolve(__dirname, '../components/DesignPageTabs.vue')
const source = fs.readFileSync(SOURCE_PATH, 'utf-8')

describe('DesignPageTabs.vue static contract', () => {
  it('emits selectPage, addPage, deletePage', () => {
    // The defineEmits block must declare all three emit names.
    expect(source).toContain("selectPage")
    expect(source).toContain("addPage")
    expect(source).toContain("deletePage")
  })

  it('declares the required props (pages, activePageId, workspaceId, itemId)', () => {
    // The defineProps block must include all four prop names so the
    // parent (DesignView) can wire the data through.
    expect(source).toContain("pages:")
    expect(source).toContain("activePageId:")
    expect(source).toContain("workspaceId:")
    expect(source).toContain("itemId:")
  })

  it('renders one tab per page with the data-testid selector', () => {
    // data-testid is the contract for E2E tests; the per-page id is
    // interpolated so each tab has a unique selector.
    expect(source).toContain("design-page-tab-${page.id}")
  })

  it('renders the + Page button with the design-add-page testid', () => {
    // The + Page button must be there for users to add new pages.
    expect(source).toContain("design-add-page")
    expect(source).toContain("+ Page")
  })

  it('highlights the active page with the violet bottom border', () => {
    // Active tab styling is the key visual cue; we assert the css
    // var is referenced (not the literal hex color).
    expect(source).toContain("--color-violet")
  })
})