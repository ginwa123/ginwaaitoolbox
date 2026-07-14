/**
 * Static source-grep tests for DesignView.vue (the top-level design
 * canvas component).
 *
 * DesignView is the host that ties DesignPageTabs + DesignElement +
 * LayersPanel + PropertiesPanel + AddDesignElementDialog together.
 * Static contract:
 *  - Renders the page tabs at the top, then the main split (canvas
 *    + right sidebar with Layers + Properties).
 *  - Two drag-resize handles (canvas↔sidebar, Layers↔Properties).
 *  - On mount fetches design pages; defaults activePageId to first page.
 *  - watch(activePageId) re-fetches elements for the new page.
 *  - Escape keypress clears selection; canvas background click clears selection.
 *  - 8 emits back to the parent (AppLayout wires them in Chunk 8).
 */
import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const SOURCE_PATH = path.resolve(__dirname, '../components/DesignView.vue')
const source = fs.readFileSync(SOURCE_PATH, 'utf-8')

describe('DesignView.vue static contract', () => {
  it('declares item, workspaceId, itemId props', () => {
    expect(source).toContain("item:")
    expect(source).toContain("workspaceId:")
    expect(source).toContain("itemId:")
  })

  it('emits all 8 parent events (selectPage, addPage, deletePage, selectElement, reorderElements, createElement, updateElement, deleteElement, htmlChanged)', () => {
    expect(source).toContain("selectPage:")
    expect(source).toContain("addPage:")
    expect(source).toContain("deletePage:")
    expect(source).toContain("selectElement:")
    expect(source).toContain("reorderElements:")
    expect(source).toContain("createElement:")
    expect(source).toContain("updateElement:")
    expect(source).toContain("deleteElement:")
    expect(source).toContain("htmlChanged:")
  })

  it('renders the page tabs, canvas, and right sidebar with Layers + Properties', () => {
    expect(source).toContain("<DesignPageTabs")
    expect(source).toContain("<DesignElement")
    expect(source).toContain("<LayersPanel")
    expect(source).toContain("<PropertiesPanel")
  })

  it('fetches design pages via listDesignPages on mount', () => {
    // The onMounted hook calls loadPages which uses the API directly
    // (the store doesn't yet have a listDesignPages action in this
    // chunk; the page state is local).
    expect(source).toContain("listDesignPages")
    expect(source).toContain("loadPages")
    expect(source).toContain("onMounted")
  })

  it('watches activePageId to refetch elements', () => {
    expect(source).toContain("watch(activePageId")
    expect(source).toContain("fetchDesignElements")
  })

  it('handles Escape keypress to clear selection', () => {
    expect(source).toContain("Escape")
    expect(source).toContain("keydown")
  })

  it('has the canvas + sidebar resize handles', () => {
    expect(source).toContain("design-sidebar-resize-handle")
    expect(source).toContain("design-layers-resize-handle")
    expect(source).toContain("startSidebarResize")
    expect(source).toContain("startLayersResize")
  })

  it('has the design-view and design-canvas data-testids', () => {
    expect(source).toContain('data-testid="design-view"')
    expect(source).toContain('data-testid="design-canvas"')
  })

  it('renders loading/error/empty states for the pages fetch', () => {
    expect(source).toContain("design-pages-loading")
    expect(source).toContain("design-pages-error")
    expect(source).toContain("design-pages-empty")
  })

  it('renders the + Element button + active page name + element count', () => {
    expect(source).toContain("design-add-element-button")
    expect(source).toContain("design-canvas-header")
  })

  it('persists sidebar width to localStorage', () => {
    // The drag-resize handle persists the sidebar width so the user's
    // preferred layout survives a page reload.
    expect(source).toContain("localStorage")
    expect(source).toContain("SIDEBAR_WIDTH_KEY")
  })

  // NEW (2026-07-14): top-right chat-toggle. The 💬 button in the
  // canvas header bar emits `openChat` upward; AppLayout's
  // handleDesignOpenChat handler finds or creates a "Design Chat"
  // task on the design item and switches to the 3-column
  // (DesignView | resize-handle | ChatView) layout. Without this
  // contract, a future refactor could silently drop the chat
  // toggle and the user would lose the primary way to interact
  // with the LLM about the design.
  it('declares openChat in defineEmits (top-right chat toggle)', () => {
    // Vue 3 typed-emits syntax allows either `openChat: []` or
    // `openChat: [] | null` — match either. The event must be
    // present in the defineEmits<{...}>() type literal.
    expect(source).toMatch(/openChat:\s*\[\s*\][^,}]*/)
  })

  it('renders the design-open-chat-button in the canvas header', () => {
    expect(source).toContain('design-open-chat-button')
    expect(source).toContain('aria-label="Open design chat"')
    // The 💬 glyph should appear in the button (visual cue for
    // chat — same convention used by folder chats in nalar).
    expect(source).toMatch(/💬/)
  })

  it('handleOpenChat emits the openChat event', () => {
    expect(source).toMatch(/handleOpenChat\s*=\s*\([^)]*\)\s*:\s*void\s*=>\s*\{[^}]*emit\('openChat'\)/)
  })
})