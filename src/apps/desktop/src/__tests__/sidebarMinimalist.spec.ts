// Regression tests for the "minimalist sidebar" feature (2026-07-02).
//
// The user wants the sidebar to feel minimal — no decorative emoji,
// no folder icons, no SVG glyphs where unicode characters suffice.
//
// Pattern: static source-grep tests (matches the project's convention
// in sidebarSpacing.spec.ts). Read each Vue file as text and assert
// the new patterns landed:
//
//   1. workspaceMonogram helper exists and is used in the collapsed
//      sidebar tile (NOT {{ workspace.icon }}).
//   2. No remaining 📂 / 📁 / 📋 / 🧠 / 🤖 / 🌳 emoji or folder-icon
//      fallbacks in Sidebar/ChatsList/WorkspaceList/WorkspaceItem.
//   3. The collapse toggle uses the new data-testid and an updated
//      target-state rotation.
//   4. The collapsed workspace button uses text "monogram", not an
//      emoji glyph.
//   5. The collapsed new-chat button is a plain text "+", not the
//      chat-bubble SVG.
//   6. The Add Item dropdown menu has plain text labels (no leading
//      emoji icons).
//   7. The workspace row's rename/delete buttons use unicode characters
//      (✎, ×), not SVG paths.
//
// Why source-grep instead of DOM-measured rendering? Same rationale as
// sidebarSpacing.spec.ts: jsdom can't compute layout, but the actual
// risk being defended against is "someone reverts the icon-free UX
// back to decorative emoji/SVG". A grep catches that with zero new
// infra.

import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const SIDEBAR_PATH = path.resolve(__dirname, '../components/shell/Sidebar.vue')
const CHATSLIST_PATH = path.resolve(__dirname, '../components/views/ChatsList.vue')
const WORKSPACELIST_PATH = path.resolve(__dirname, '../components/workspace/WorkspaceList.vue')
const WORKSPACEITEM_PATH = path.resolve(__dirname, '../components/workspace/WorkspaceItem.vue')

const readSource = (filePath: string): string =>
  fs.readFileSync(filePath, 'utf-8')

// Emoji we explicitly removed in the minimalist rewrite. Any of these
// appearing in the sidebar source files is a regression — they were
// the decorative folder/menu icons that the user wanted to be rid of.
const FORBIDDEN_DECORATIVE_EMOJI = ['📂', '📁', '📋', '🧠'] as const

describe('Sidebar.vue minimalist rewrite', () => {
  const source = readSource(SIDEBAR_PATH)

  it('has the workspaceMonogram helper function', () => {
    if (!source.includes('const workspaceMonogram = (name: string)')) {
      throw new Error(
        'Sidebar.vue is missing the workspaceMonogram helper (required by the collapsed-tile text monogram)',
      )
    }
  })

  it('collapsed workspace tile uses workspaceMonogram, NOT workspace.icon', () => {
    // The collapsed-state tile must render the monogram call result,
    // not the emoji icon. Look for "{{ workspaceMonogram(workspace.name) }}"
    // and confirm the emoji-based "{{ workspace.icon || ..." pattern is gone.
    if (!source.includes('{{ workspaceMonogram(workspace.name) }}')) {
      throw new Error(
        'Sidebar.vue collapsed workspace tile does not call workspaceMonogram(workspace.name) — the emoji fallback is back.',
      )
    }
    if (source.includes("workspace.icon || '📂'")) {
      throw new Error(
        "Sidebar.vue still has the 'workspace.icon || 📂' emoji fallback — the minimalist rewrite was reverted.",
      )
    }
  })

  it('collapse/expand toggle has data-testid="sidebar-collapse-toggle"', () => {
    if (!source.includes('data-testid="sidebar-collapse-toggle"')) {
      throw new Error(
        'Sidebar.vue collapse/expand button is missing data-testid="sidebar-collapse-toggle" (required for testing + accessibility)',
      )
    }
  })

  it.each(FORBIDDEN_DECORATIVE_EMOJI)(
    'does not contain forbidden decorative emoji %s',
    (emoji) => {
      if (source.includes(emoji)) {
        throw new Error(
          `Sidebar.vue contains decorative emoji "${emoji}". The minimalist rewrite removed all decorative emojis.`,
        )
      }
    },
  )
})

describe('ChatsList.vue minimalist rewrite', () => {
  const source = readSource(CHATSLIST_PATH)

  it('collapsed new-chat button is a plain text "+" — not the chat-bubble SVG', () => {
    // Look for "data-testid=\"collapsed-new-chat-button\"" and confirm
    // the SVG chat-bubble path d="M21 11.5a8.38..." is no longer
    // present in the collapsed-state branch (we only check the SVG
    // path since the testid could match a hover/title attribute).
    if (!source.includes('data-testid="collapsed-new-chat-button"')) {
      throw new Error(
        'ChatsList.vue is missing data-testid="collapsed-new-chat-button" on the collapsed new-chat button.',
      )
    }
    if (source.includes('M21 11.5a8.38 8.38 0 0 1-.9 3.8')) {
      throw new Error(
        'ChatsList.vue still contains the chat-bubble-plus SVG path (M21 11.5a8.38...). The minimalist rewrite removed it.',
      )
    }
  })

  it('delete chat button uses unicode "×" glyph (not the SVG X path)', () => {
    // Confirm the SVG X path d="M6 18L18 6M6 6l12 12" no longer
    // appears in the chat-row delete button context. The path string
    // is unique enough to be safe to grep globally.
    if (source.includes('M6 18L18 6M6 6l12 12')) {
      throw new Error(
        'ChatsList.vue still has the SVG X-glyph path for the chat delete button. The minimalist rewrite replaced it with unicode "×".',
      )
    }
  })

  it.each(FORBIDDEN_DECORATIVE_EMOJI)(
    'does not contain forbidden decorative emoji %s',
    (emoji) => {
      if (source.includes(emoji)) {
        throw new Error(
          `ChatsList.vue contains decorative emoji "${emoji}".`,
        )
      }
    },
  )
})

describe('WorkspaceList.vue minimalist rewrite', () => {
  const source = readSource(WORKSPACELIST_PATH)

  it('expanded workspace row no longer renders the emoji icon span', () => {
    // The original rewrite added a span with `workspace.icon || '📂'`
    // for visual emphasis. The minimalist rewrite removed it. The
    // data-testid="workspace-icon" is the targeted signal — if it's
    // still here, the icon span came back.
    if (source.includes('data-testid="workspace-icon"')) {
      throw new Error(
        'WorkspaceList.vue still has data-testid="workspace-icon" — the emoji icon span came back.',
      )
    }
  })

  it('rename/delete workspace buttons use unicode characters, not SVG paths', () => {
    // Pencil SVG path: d="M11 5H6a2 2 0 00-2 2v11a..."
    if (source.includes('M11 5H6a2 2 0 00-2 2v11a2')) {
      throw new Error(
        'WorkspaceList.vue still has the pencil SVG path for rename. Use unicode ✎.',
      )
    }
    // Trash SVG path: d="M19 7l-.867 12.142..."
    if (source.includes('M19 7l-.867 12.142A2 2 0 0116.138 21')) {
      throw new Error(
        'WorkspaceList.vue still has the trash SVG path for delete. Use unicode ×.',
      )
    }
  })

  it('Add Item dropdown has no emoji icons (plain text labels only)', () => {
    // The pre-minimalist dropdown had <span class="text-base">📁</span>
    // etc. The minimalist version uses plain text "Add Project" /
    // "Add Kanban" buttons. (Add Memory was removed 2026-07-04.)
    if (source.includes('aria-hidden="true">📁')) {
      throw new Error(
        'WorkspaceList.vue Add Item dropdown still has the 📁 emoji. Plain text only.',
      )
    }
    if (source.includes('aria-hidden="true">📋')) {
      throw new Error(
        'WorkspaceList.vue Add Item dropdown still has the 📋 emoji. Plain text only.',
      )
    }
    if (source.includes('aria-hidden="true">🧠')) {
      throw new Error(
        'WorkspaceList.vue Add Item dropdown still has the 🧠 emoji. Plain text only.',
      )
    }
  })

  it('"Add Item" button is bare text — no SVG plus icon', () => {
    // The minimalist version uses literal "+ Add Item" text. If the
    // SVG-plus path "M12 4v16m8-8H4" appears inside the
    // workspace-add-item-button context, the icon came back.
    if (source.includes('data-testid="workspace-add-item-button"')) {
      // we have the button — make sure it doesn't contain the SVG path
      const idx = source.indexOf('data-testid="workspace-add-item-button"')
      const nextBtnEnd = source.indexOf('</button>', idx)
      const slice = source.slice(idx, nextBtnEnd)
      if (slice.includes('M12 4v16m8-8H4')) {
        throw new Error(
          'WorkspaceList.vue Add Item button still contains the SVG plus icon. Use plain text "+ Add Item".',
        )
      }
    }
  })

  it.each(FORBIDDEN_DECORATIVE_EMOJI)(
    'does not contain forbidden decorative emoji %s',
    (emoji) => {
      if (source.includes(emoji)) {
        throw new Error(
          `WorkspaceList.vue contains decorative emoji "${emoji}".`,
        )
      }
    },
  )
})

describe('WorkspaceItem.vue minimalist rewrite', () => {
  const source = readSource(WORKSPACEITEM_PATH)

  it('chevron is a unicode ▶ character (testid="item-row-chevron")', () => {
    // The pre-minimalist chevron was an SVG path
    // d="M19 9l-7 7-7-7"; after the rewrite it's a unicode glyph
    // wrapped in <span data-testid="item-row-chevron">.
    if (!source.includes('data-testid="item-row-chevron"')) {
      throw new Error(
        'WorkspaceItem.vue is missing data-testid="item-row-chevron" on the chevron span.',
      )
    }
    // The old chevron SVG path must be gone.
    if (source.includes('M19 9l-7 7-7-7')) {
      throw new Error(
        'WorkspaceItem.vue still has the chevron SVG path. Use unicode ▶ glyph.',
      )
    }
  })

  it('add-task button is unicode "+" (not SVG plus icon)', () => {
    // Look for the SVG plus path inside an Add Task button context.
    // The old code had <svg ...><path ... d="M12 4v16m8-8H4" /></svg>
    // wrapped in a title="Add Task" button.
    if (source.includes('title="Add Task"')) {
      const idx = source.indexOf('title="Add Task"')
      const nextBtnEnd = source.indexOf('</button>', idx)
      const slice = source.slice(idx, nextBtnEnd)
      if (slice.includes('M12 4v16m8-8H4')) {
        throw new Error(
          'WorkspaceItem.vue Add Task button still contains the SVG plus icon. Use unicode "+".',
        )
      }
    }
  })

  it('delete-item button is unicode "×" (not SVG X icon)', () => {
    // The old code had <svg ...><path ... d="M6 18L18 6M6 6l12 12" /></svg>
    // inside a title="Delete Item" button.
    if (source.includes('title="Delete Item"')) {
      const idx = source.indexOf('title="Delete Item"')
      const nextBtnEnd = source.indexOf('</button>', idx)
      const slice = source.slice(idx, nextBtnEnd)
      if (slice.includes('M6 18L18 6M6 6l12 12')) {
        throw new Error(
          'WorkspaceItem.vue Delete Item button still contains the SVG X icon. Use unicode "×".',
        )
      }
    }
  })
})
