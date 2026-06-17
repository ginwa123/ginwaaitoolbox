// Regression tests for the sidebar "overlapping text" fix.
//
// These tests are static source-grep (not behavioral): they read each
// Vue file as text and assert the new Tailwind classes that were
// added to fix the spacing problem landed in the right place.
//
// Why source-grep instead of DOM-measured spacing?
//   - jsdom does not compute layout, so getBoundingClientRect() returns
//     { top: 0, bottom: 0, width: 0, height: 0 } for every element.
//   - The project's Vitest setup is jsdom-only; switching to a real
//     browser harness (Playwright / @vitest/browser) is a separate
//     effort outside the scope of this fix.
//   - The actual risk being defended against is "someone reverts
//     py-2.5 back to py-2 in a future refactor" — source-grep catches
//     that with zero new infrastructure.
//
// When a future task adds a browser-harness Vitest environment, flip
// these tests to measure real pixel gaps and assert >= N px.

import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const CHATSLIST_PATH = path.resolve(__dirname, '../components/ChatsList.vue')
const WORKSPACELIST_PATH = path.resolve(__dirname, '../components/WorkspaceList.vue')
const WORKSPACEITEM_PATH = path.resolve(__dirname, '../components/WorkspaceItem.vue')
const VIRTUALSCROLLER_PATH = path.resolve(__dirname, '../helpers/VirtualScroller.vue')

const readSource = (filePath: string): string =>
  fs.readFileSync(filePath, 'utf-8')

describe('ChatsList.vue spacing', () => {
  const source = readSource(CHATSLIST_PATH)

  it('uses py-2.5 (10 px) on the header button for more breathing room', () => {
    if (
      !source.includes(
        'class="px-3 py-2.5 flex items-center gap-2 w-full text-left hover:opacity-70 transition-opacity shrink-0 border-b border-[--color-border]/40"',
      )
    ) {
      throw new Error(
        'ChatsList header button is missing py-2.5 padding (should be 10 px, not 8 px)',
      )
    }
  })

  it('has a border-b separator on the header button', () => {
    // Sanity check independent of the full class string above — protects
    // against a future refactor that renames the class but drops the
    // border-b suffix.
    if (!source.includes('border-b border-[--color-border]/40')) {
      throw new Error(
        'ChatsList header button is missing the border-b separator (section → first chat row gap is too tight)',
      )
    }
  })

  it('chat item row has a transparent border-t baseline (no layout shift on active toggle)', () => {
    if (!source.includes('border-t border-transparent')) {
      throw new Error(
        'ChatsList chat item row is missing the border-t border-transparent baseline (active ↔ inactive would shift by 1 px)',
      )
    }
  })

  it('active chat row gets a visible top border via :class', () => {
    // Pattern: `:class="item.active ? 'border-[--color-border]/60' : ''"`
    if (!source.includes("item.active ? 'border-[--color-border]/60'")) {
      throw new Error(
        'ChatsList active chat row is missing the active-state top border (active row blends into the header above)',
      )
    }
  })

  it('chat list wrapper has overflow-hidden (defense against VirtualScroller overflow)', () => {
    // If a future change to VirtualScroller reintroduces a min-height,
    // this overflow-hidden on the wrapper ensures the overflow is clipped
    // at the chat list boundary instead of bleeding into the WORKSPACES
    // section header below.
    if (
      !source.includes('class="flex-1 min-h-0 flex flex-col overflow-hidden"')
    ) {
      throw new Error(
        'ChatsList chat list wrapper is missing overflow-hidden (overflow from VirtualScroller would bleed into WORKSPACES)',
      )
    }
  })

  it('resize handle has a visible background tint (so the CHATS↔WORKSPACES boundary is always visible)', () => {
    // Old: just a 2px transparent gradient line — invisible on dark theme.
    // New: subtle bg-[--color-border]/20 background + solid line — always visible.
    if (!source.includes("'bg-[--color-border]/20 hover:bg-[--color-border]/40 transition-colors'")) {
      throw new Error(
        'ChatsList resize handle is missing the visible background tint (boundary between CHATS and WORKSPACES is invisible)',
      )
    }
  })
})

describe('WorkspaceList.vue spacing', () => {
  const source = readSource(WORKSPACELIST_PATH)

  it('workspace header div has a border-b separator', () => {
    if (
      !/class="flex items-center group\/workspace rounded-lg transition-all duration-150 border-b border-\[--color-border\]\/40/.test(
        source,
      )
    ) {
      throw new Error(
        'WorkspaceList workspace header div is missing the border-b separator (header → first item gap is too tight)',
      )
    }
  })

  it('WorkspaceItemComponent root has first:mt-1.5 class binding', () => {
    // The class must appear within 400 chars after the WorkspaceItemComponent
    // opening tag. The `:is-item-drag-over` line is the last prop before
    // the class, so this regex anchors the class to the right component.
    if (!/WorkspaceItemComponent[\s\S]{0,400}class="first:mt-1.5"/.test(source)) {
      throw new Error(
        'WorkspaceList is missing first:mt-1.5 binding on WorkspaceItemComponent (first workspace item sits flush against the header above)',
      )
    }
  })
})

describe('WorkspaceItem.vue spacing', () => {
  const source = readSource(WORKSPACEITEM_PATH)

  it('item row button uses py-2 (8 px) for consistency with chat row height', () => {
    if (
      !source.includes(
        'class="flex-1 flex items-center gap-2 px-3 py-2 rounded-md text-sm transition-all duration-200"',
      )
    ) {
      throw new Error(
        'WorkspaceItem main row button is missing py-2 (should match chat row height of 8 px)',
      )
    }
  })

  it('tasks div uses mt-1.5 (6 px) for a clearer gap from the item row', () => {
    if (
      !source.includes('class="ml-8 mt-1.5 space-y-0.5 pl-2 border-l border-[--color-border]/30"')
    ) {
      throw new Error(
        'WorkspaceItem tasks div is missing mt-1.5 (should be 6 px, not 4 px) or missing the pl-2 + border-l nesting separator',
      )
    }
  })
})

describe('VirtualScroller.vue layout (the actual overflow bug)', () => {
  const source = readSource(VIRTUALSCROLLER_PATH)

  it('does NOT have a hard min-height: 100px floor on the scroller', () => {
    // The previous `min-height: 100px` made the scroller 100 px tall even
    // when its parent was smaller, causing the last visible chat row to
    // overflow into the WORKSPACES section. The `min-h-0` Tailwind class
    // on the parent provides the correct "shrink to 0" behavior.
    //
    // Match only CSS declarations (which end in `;`) so we don't false-
    // positive on the explanatory comment that mentions the old value.
    if (/min-height:\s*100px\s*;/.test(source)) {
      throw new Error(
        'VirtualScroller still has min-height: 100px as a CSS rule — this is the root cause of the CHATS↔WORKSPACES overflow. Remove it; the parent\'s `min-h-0` is sufficient.',
      )
    }
  })

  it('keeps the flex: 1 1 0 and min-height: 0 contract for the parent flex column', () => {
    if (!/flex:\s*1 1 0/.test(source)) {
      throw new Error(
        'VirtualScroller is missing `flex: 1 1 0` (required for the scroller to participate in the parent flex column)',
      )
    }
    if (!/min-height:\s*0/.test(source)) {
      throw new Error(
        'VirtualScroller is missing `min-height: 0` (required for the scroller to shrink below its content size in a flex column)',
      )
    }
  })
})

