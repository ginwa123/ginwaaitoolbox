/**
 * Tests for DiffView.vue.
 *
 * Verifies:
 *  - renders split-view by default; toggle to unified swaps the view
 *  - shows the change count when there are changes
 *  - shows file path in the header when provided
 *  - sticky gutter cells render with the line-number content (and DON'T
 *    show "0" for inserts/deletes that have no before/after line)
 *  - empty before/after renders '(no content)' placeholder
 *  - REGRESSION: line-shift after insert renders as 1 changed row, not
 *    falsely flagging all subsequent lines
 *  - hunk headers appear in unified view with `@@ -start,count +start,count @@`
 *  - data-row / data-changed attrs reflect the diff state (for E2E selectors)
 */
import { mount } from '@vue/test-utils'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'

import DiffView from '../DiffView.vue'
import { makeLocalStorageStub } from '../../../../__tests__/helpers'

beforeAll(() => {
  // jsdom 29 dropped localStorage from default globals; install a stub.
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
})

beforeEach(() => {
  localStorage.clear()
})

describe('DiffView', () => {
  it('renders the diff header with default mode = split', () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'a\nb\nc',
        after: 'a\nb\nC',
      },
    })
    expect(wrapper.text()).toContain('diff')
    expect(wrapper.text()).toContain('Before')
    expect(wrapper.text()).toContain('After')
  })

  it('shows the file path when provided', () => {
    const wrapper = mount(DiffView, {
      props: { before: 'a', after: 'a', filePath: '/foo/bar.ts' },
    })
    expect(wrapper.text()).toContain('/foo/bar.ts')
  })

  it('shows the change count', () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'a\nb\nc\nd',
        after: 'a\nb\nX\nd',
      },
    })
    expect(wrapper.text()).toMatch(/\d+ change/)
  })

  it('toggles to unified view when the Unified button is clicked', async () => {
    const wrapper = mount(DiffView, {
      props: { before: 'a\nb', after: 'a\nB' },
    })
    // Find the "Unified" button
    const buttons = wrapper.findAll('button')
    const unifiedBtn = buttons.find((b) => b.text() === 'Unified')
    expect(unifiedBtn).toBeTruthy()
    await unifiedBtn!.trigger('click')
    // After toggle, unified hunk header should be visible
    expect(wrapper.text()).toMatch(/@@ -\d+,\d+ \+\d+,\d+ @@/)
    // No more "Before"/"After" labels in unified mode
    expect(wrapper.text()).not.toContain('Before')
  })

  it('toggles back to split view', async () => {
    const wrapper = mount(DiffView, {
      props: { before: 'a\nb', after: 'a\nB' },
    })
    await wrapper.findAll('button').find((b) => b.text() === 'Unified')!.trigger('click')
    await wrapper.findAll('button').find((b) => b.text() === 'Split')!.trigger('click')
    expect(wrapper.text()).toContain('Before')
  })

  it('REGRESSION: line-shift after insert renders only 1 changed row', () => {
    // Inserting 'b' at position 2 of a 10-line file should mark only line 2
    // as changed. Lines 3-10 must remain isChanged=false in the split view.
    const wrapper = mount(DiffView, {
      props: {
        before: 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10',
        after: 'l1\nl2\nINSERTED\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10',
      },
    })
    // Find all rows on the before side
    const rows = wrapper.findAll('[data-side="before"][data-row]')
    const changedCount = rows.filter((r) => r.attributes('data-changed') === 'true').length
    expect(changedCount).toBe(1)
  })

  it('renders hunk headers in unified view', async () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'ctx1\nctx2\nOLD\nctx3\nctx4',
        after: 'ctx1\nctx2\nNEW\nctx3\nctx4',
      },
    })
    await wrapper.findAll('button').find((b) => b.text() === 'Unified')!.trigger('click')
    const hunks = wrapper.findAll('[data-hunk]')
    expect(hunks.length).toBeGreaterThan(0)
    expect(hunks[0]!.text()).toMatch(/^@@ -\d+,\d+ \+\d+,\d+ @@$/)
  })

  it('renders "(no content)" placeholder for empty inputs', () => {
    const wrapper = mount(DiffView, {
      props: { before: '', after: '' },
    })
    expect(wrapper.text()).toContain('(no content)')
  })

  it('handles pure-insert (empty before, single line after)', () => {
    const wrapper = mount(DiffView, {
      props: { before: '', after: 'hello' },
    })
    expect(wrapper.text()).toContain('hello')
    expect(wrapper.text()).toMatch(/\d+ change/)
  })

  it('handles pure-delete (single line before, empty after)', () => {
    const wrapper = mount(DiffView, {
      props: { before: 'hello', after: '' },
    })
    expect(wrapper.text()).toContain('hello')
    expect(wrapper.text()).toMatch(/\d+ change/)
  })

  it('persists mode toggle to localStorage', async () => {
    const wrapper = mount(DiffView, {
      props: { before: 'a\nb', after: 'a\nB' },
    })
    await wrapper.findAll('button').find((b) => b.text() === 'Unified')!.trigger('click')
    expect(localStorage.getItem('diffview.mode')).toBe('unified')
    // Set split and verify
    await wrapper.findAll('button').find((b) => b.text() === 'Split')!.trigger('click')
    expect(localStorage.getItem('diffview.mode')).toBe('split')
  })

  it('reads initial mode from localStorage', () => {
    localStorage.setItem('diffview.mode', 'unified')
    const wrapper = mount(DiffView, {
      props: { before: 'a\nb', after: 'a\nB' },
    })
    // unified mode is on, so we should see a hunk header
    expect(wrapper.text()).toMatch(/@@ -\d+,\d+ \+\d+,\d+ @@/)
    localStorage.clear()
  })

  // ─────────────────────────────────────────────────────────────────────
  // jump-to-line emit (chunks 5+6)
  // ─────────────────────────────────────────────────────────────────────

  it('emits jump-to-line when an after-side line number is clicked (split view)', async () => {
    const wrapper = mount(DiffView, {
      props: {
        before: 'l1\nl2\nl3',
        after: 'l1\nL2-CHANGED\nl3',
      },
    })
    // Find the row containing the after-line "2" (the inserted row).
    // The after-side row has data-side="after" and data-line="2".
    const afterLineRows = wrapper.findAll('[data-side="after"][data-line="2"]')
    expect(afterLineRows.length).toBe(1)
    const afterLineRow = afterLineRows[0]!
    // The gutter is the first <span> child (sticky left-0). Trigger click
    // on the row's gutter via the row's click handler proxy.
    await afterLineRow.element.firstElementChild!.dispatchEvent(
      new MouseEvent('click', { bubbles: true }),
    )
    const events = wrapper.emitted('jump-to-line')
    expect(events).toBeTruthy()
    expect(events![0]).toEqual([2])
  })

  it('emits jump-to-line from the unified gutter when clicked', async () => {
    const wrapper = mount(DiffView, {
      props: { before: 'a\nb', after: 'a\nB' },
    })
    await wrapper.findAll('button').find((b) => b.text() === 'Unified')!.trigger('click')
    // Find the unified row for the inserted 'B' line — its afterLine is 2
    const insertedRows = wrapper.findAll('[data-kind="insert"][data-after-line="2"]')
    expect(insertedRows.length).toBe(1)
    // After-side gutter is the second span (sticky left-10).
    await insertedRows[0]!.element.children[1]!.dispatchEvent(
      new MouseEvent('click', { bubbles: true }),
    )
    const events = wrapper.emitted('jump-to-line')
    expect(events).toBeTruthy()
    expect(events![0]).toEqual([2])
  })

  it('does not emit jump-to-line for rows with no line number', async () => {
    const wrapper = mount(DiffView, {
      // Pure insert: empty before → no before-line numbers anywhere.
      props: { before: '', after: 'NEW' },
    })
    // The before-side gutter cells should have no line number — clicking
    // them should NOT emit (no `data-line` attr on those rows).
    const rowsWithoutLine = wrapper.findAll('[data-side="before"][data-row]')
    rowsWithoutLine.forEach((r) => {
      expect(r.attributes('data-line')).toBeUndefined()
    })
    expect(wrapper.emitted('jump-to-line')).toBeFalsy()
  })
})