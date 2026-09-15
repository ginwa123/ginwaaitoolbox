/**
 * Tests for PresentFiles.vue — the tool-output card component for the
 * `present_files` agent tool.
 *
 * Verifies (behavioural — mount + query, no static-contract):
 *  - renders the card with a data-testid
 *  - success path: header shows file count + ✓; expanded rows show
 *    label, size, mime; download anchors point at
 *    /api/files/download with disposition=attachment
 *  - image files render a thumbnail <img> with disposition=inline plus a
 *    full-width inline preview; html renders a sandboxed iframe;
 *    pdf/video/audio render native players; text-like files fetch source
 *    and render via PreviewContentRenderer; anything else renders a 📄
 *    row with no inline preview
 *  - error path: red border + ✗ + error message inline
 *  - expand/collapse: rows hidden until the header is toggled
 */
import { flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import PresentFiles from '../PresentFiles.vue'

// The text branch fetches source over same-origin `fetch` — stub it so no
// test performs a real network call and text previews resolve
// deterministically.
beforeEach(() => {
  vi.stubGlobal(
    'fetch',
    vi.fn(async () => ({ ok: true, status: 200, text: async () => '# Hello\n' }) as Response),
  )
})

afterEach(() => {
  vi.unstubAllGlobals()
})

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

  it('image files render a full-width inline preview (click → fullscreen)', () => {
    const wrapper = mountCard(makeSuccessContent())
    const inline = wrapper.find('[data-testid="present-files-inline-image-1"]')
    expect(inline.exists()).toBe(true)
    expect(inline.attributes('src') ?? '').toContain('disposition=inline')
    expect(inline.attributes('src') ?? '').toContain(`path=${encodeURIComponent('/tmp/photo.jpg')}`)
  })

  it('html files render a sandboxed inline iframe + open-in-new-tab', () => {
    const content = [
      '<present_files>',
      '<status>presented</status>',
      '<count>1</count>',
      '<files>',
      '<file path="/tmp/test-page.html" bytes="655" mime="text/html; charset=utf-8" label="test-page.html"/>',
      '</files>',
      '</present_files>',
    ].join('')
    const wrapper = mountCard(content)
    const frame = wrapper.find('[data-testid="present-files-inline-html-0"] iframe')
    expect(frame.exists()).toBe(true)
    expect(frame.attributes('src') ?? '').toContain('disposition=inline')
    expect(frame.attributes('sandbox') ?? '').toContain('allow-scripts')
    expect(frame.attributes('sandbox') ?? '').not.toContain('allow-same-origin')
    expect(wrapper.find('[data-testid="present-files-open-tab-0"]').exists()).toBe(true)
  })

  it('pdf / video / audio files render native inline players', () => {
    const content = [
      '<present_files>',
      '<status>presented</status>',
      '<count>3</count>',
      '<files>',
      '<file path="/tmp/doc.pdf" bytes="100" mime="application/pdf" label="doc.pdf"/>',
      '<file path="/tmp/clip.mp4" bytes="200" mime="video/mp4" label="clip.mp4"/>',
      '<file path="/tmp/song.mp3" bytes="300" mime="audio/mpeg" label="song.mp3"/>',
      '</files>',
      '</present_files>',
    ].join('')
    const wrapper = mountCard(content)
    const pdf = wrapper.find('[data-testid="present-files-inline-pdf-0"] iframe')
    expect(pdf.exists()).toBe(true)
    expect(pdf.attributes('src') ?? '').toContain('disposition=inline')
    const video = wrapper.find('[data-testid="present-files-inline-video-1"] video')
    expect(video.exists()).toBe(true)
    expect(video.attributes('src') ?? '').toContain('disposition=inline')
    const audio = wrapper.find('[data-testid="present-files-inline-audio-2"] audio')
    expect(audio.exists()).toBe(true)
    expect(audio.attributes('src') ?? '').toContain('disposition=inline')
  })

  it('markdown files render fetched source via the shared renderer', async () => {
    const content = [
      '<present_files>',
      '<status>presented</status>',
      '<count>1</count>',
      '<files>',
      '<file path="/tmp/readme.md" bytes="7" mime="text/markdown; charset=utf-8" label="readme.md"/>',
      '</files>',
      '</present_files>',
    ].join('')
    const wrapper = mountCard(content)
    await flushPromises()
    expect(wrapper.find('[data-testid="present-files-inline-text-0"]').exists()).toBe(true)
    // The stubbed fetch returns '# Hello' markdown → <h1> via marked().
    expect(wrapper.find('[data-testid="present-files-inline-text-0"]').html()).toContain('<h1')
  })
})
