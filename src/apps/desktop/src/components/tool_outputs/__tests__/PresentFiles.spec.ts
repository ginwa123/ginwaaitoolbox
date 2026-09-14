/**
 * Tests for PresentFiles.vue — the tool-output card component for the
 * `present_files` agent tool.
 *
 * Verifies (behavioural — mount + query, no static-contract):
 *  - renders the card with a data-testid
 *  - success path: header shows file count + ✓; expanded rows show
 *    label, size, mime; download anchors point at
 *    /api/files/download with disposition=attachment
 *  - image files render a thumbnail <img> with disposition=inline;
 *    non-images render a 📄 row with no <img>
 *  - error path: red border + ✗ + error message inline
 *  - expand/collapse: rows hidden until the header is toggled
 */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import PresentFiles from '../PresentFiles.vue'

// ─── Test helpers ──────────────────────────────────────────────────────────

const makeSuccessContent = () =>
  [
    '<present_files>',
    '<status>presented</status>',
    '<count>2</count>',
    '<files>',
    '<file path="/tmp/notes.txt" bytes="11" mime="text/plain; charset=utf-8" label="notes"/>',
    '<file path="/tmp/photo.jpg" bytes="48211" mime="image/jpeg" label="photo.jpg"/>',
    '</files>',
    '</present_files>',
  ].join('')

const makeErrorContent = (
  msg = 'present_files: file not found (or is a directory): "/tmp/nope.txt".',
) => `<present_files><error>${msg}</error></present_files>`

const mountCard = (content: string, sessionId = 'sess_123', expanded = true) =>
  mount(PresentFiles, { props: { content, sessionId, expanded } })

// ─── Tests ─────────────────────────────────────────────────────────────────

describe('PresentFiles', () => {
  it('renders the card with a data-testid', () => {
    const wrapper = mountCard(makeSuccessContent())
    expect(wrapper.find('[data-testid="present-files-card"]').exists()).toBe(true)
  })

  it('success path: header shows count + ✓', () => {
    const wrapper = mountCard(makeSuccessContent())
    expect(wrapper.text()).toContain('present_files')
    expect(wrapper.text()).toContain('2 files')
    expect(wrapper.text()).toContain('✓')
    expect(wrapper.text()).not.toContain('✗')
  })

  it('renders one row per file with label, size and mime', () => {
    const wrapper = mountCard(makeSuccessContent())
    expect(wrapper.find('[data-testid="present-files-row-0"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="present-files-row-1"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('notes')
    expect(wrapper.text()).toContain('photo.jpg')
    expect(wrapper.text()).toContain('11 B')
    expect(wrapper.text()).toContain('47.1 KB')
    expect(wrapper.text()).toContain('image/jpeg')
  })

  it('download anchors point at /api/files/download with disposition=attachment', () => {
    const wrapper = mountCard(makeSuccessContent())
    const dl = wrapper.find('[data-testid="present-files-download-0"]').attributes('href') ?? ''
    expect(dl).toContain('/api/files/download')
    expect(dl).toContain('session_id=sess_123')
    expect(dl).toContain(`path=${encodeURIComponent('/tmp/notes.txt')}`)
    expect(dl).toContain('disposition=attachment')
    const btn = wrapper.find('[data-testid="present-files-dlbtn-1"]').attributes('href') ?? ''
    expect(btn).toContain('disposition=attachment')
    expect(btn).toContain(`path=${encodeURIComponent('/tmp/photo.jpg')}`)
  })

  it('image files render an inline thumbnail; text files do not', () => {
    const wrapper = mountCard(makeSuccessContent())
    const thumb = wrapper.find('[data-testid="present-files-thumb-1"]')
    expect(thumb.exists()).toBe(true)
    expect(thumb.attributes('src') ?? '').toContain('disposition=inline')
    expect(thumb.attributes('src') ?? '').toContain(`path=${encodeURIComponent('/tmp/photo.jpg')}`)
    expect(wrapper.find('[data-testid="present-files-thumb-0"]').exists()).toBe(false)
  })

  it('error path: red border + ✗ + error message inline', () => {
    const wrapper = mountCard(makeErrorContent())
    expect(wrapper.find('[data-testid="present-files-card"]').classes()).toContain(
      'border-red-500/50',
    )
    expect(wrapper.text()).toContain('✗')
    expect(wrapper.text()).toContain('file not found')
  })

  it('rows are hidden until expanded', () => {
    const wrapper = mountCard(makeSuccessContent(), 'sess_123', false)
    expect(wrapper.find('[data-testid="present-files-row-0"]').exists()).toBe(false)
  })
})
