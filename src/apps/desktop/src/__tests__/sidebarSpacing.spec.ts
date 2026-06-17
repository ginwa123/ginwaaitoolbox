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
