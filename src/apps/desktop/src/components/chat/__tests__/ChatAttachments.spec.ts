/**
 * ChatAttachments — a user turn with MORE THAN ONE attached image must render
 * exactly N thumbnails, and none may carry an empty `src`.
 *
 * ## The bug this pins
 *
 * `llm_history.image_url` stores N base64 data URLs joined with `||` (see
 * `insert_llm_histories.zig`, "Join multiple image URLs with || delimiter",
 * and the wire docs on `http_response.zig`). The transcript used to decode that
 * field with a bare `image_url.split('|')`.
 *
 * `||` is TWO characters, so splitting on one `|` yields an empty element in
 * every gap: `"A||B"` → `["A", "", "B"]`. Each element was bound to `:src`, so
 * the empty one became `<img src="">` — which a browser draws as a
 * broken-image icon showing its `alt` text. Two attachments rendered as three
 * thumbnails: image, literal "Attached image" placeholder, image.
 *
 * A single image was unaffected (no delimiter → no empty element), which is
 * why the bug only ever showed up on multi-image turns.
 *
 * ## Why the fixtures are `||` and not what the client sent
 *
 * The desktop used to POST a single-`|`-joined string, which is why the old
 * `sseImageUrls.spec.ts` could get away with a hand-written `'a|b|c'` fixture
 * and pass forever: it tested its own mirror, never the encoder. These tests
 * feed the value the BACKEND actually produces, which is what a live SSE
 * `llm_full` frame and `GET /api/llm/session/:id/messages` both carry.
 *
 * ## Why this mounts the child, not ChatView
 *
 * ChatView's transcript cannot render in jsdom — VirtualScroller needs real
 * layout measurements, so `wrapper.html()` is chrome only (verified: a marker
 * string in a mocked `getChatHistory` row never appears). That is precisely why
 * the empty-`src` binding had no reachable test for years. The attachment strip
 * is now its own component so the binding is assertable, and ChatView keeps the
 * same `v-if` gate and the same `openImagePreview` handler.
 */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'

import ChatAttachments from '../ChatAttachments.vue'
import { splitMediaUrlsWire } from '../../../helpers/mediaUrls'

const PNG_A = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB'
const PNG_B = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAC'
const JPEG_C = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD'
const MP4_D = 'data:video/mp4;base64,AAAAIGZ0eXBhdmlm'

/** Mount exactly as ChatView does: the decoded arrays, never a raw wire string. */
const mountAttachments = (imageUrl?: string, videoUrl?: string) =>
  mount(ChatAttachments, {
    props: {
      imageUrls: splitMediaUrlsWire(imageUrl),
      videoUrls: splitMediaUrlsWire(videoUrl),
    },
  })

const imgSrcs = (w: ReturnType<typeof mountAttachments>): string[] =>
  w.findAll('img.chat-attached-image-img').map((el) => el.attributes('src') ?? '')

const videoSrcs = (w: ReturnType<typeof mountAttachments>): string[] =>
  w.findAll('video.chat-attached-image-img').map((el) => el.attributes('src') ?? '')

describe('ChatAttachments — images', () => {
  it('renders exactly two thumbnails for a ||-joined two-image turn', () => {
    // THE regression. Pre-fix this mounted three <img> elements; the middle one
    // had src="" and the browser drew the "Attached image" alt text.
    expect(imgSrcs(mountAttachments(`${PNG_A}||${PNG_B}`))).toEqual([PNG_A, PNG_B])
  })

  it('renders three thumbnails for a ||-joined three-image turn', () => {
    expect(imgSrcs(mountAttachments(`${PNG_A}||${PNG_B}||${JPEG_C}`))).toEqual([
      PNG_A,
      PNG_B,
      JPEG_C,
    ])
  })

  it('never binds an empty src to a thumbnail', () => {
    const srcs = imgSrcs(mountAttachments(`${PNG_A}||${PNG_B}||${JPEG_C}`))
    expect(srcs).toHaveLength(3)
    expect(srcs.filter((s) => s.length === 0)).toHaveLength(0)
  })

  it('renders one thumbnail for a single-image turn (unchanged behaviour)', () => {
    expect(imgSrcs(mountAttachments(PNG_A))).toEqual([PNG_A])
  })

  it('decodes a legacy single-pipe value from an older queued client', () => {
    // `queue_queued` re-emits session_queue_messages.image_url verbatim, which
    // an older desktop build wrote single-pipe. Same two thumbnails.
    expect(imgSrcs(mountAttachments(`${PNG_A}|${PNG_B}`))).toEqual([PNG_A, PNG_B])
  })

  it('renders nothing when the turn carries no attachments', () => {
    const w = mountAttachments()
    expect(imgSrcs(w)).toEqual([])
    expect(videoSrcs(w)).toEqual([])
  })
})

describe('ChatAttachments — videos', () => {
  it('renders exactly two players for a ||-joined two-clip turn', () => {
    const MP4_E = 'data:video/mp4;base64,BBBBIGZ0eXBhdmlt'
    expect(videoSrcs(mountAttachments(undefined, `${MP4_D}||${MP4_E}`))).toEqual([MP4_D, MP4_E])
  })

  it('drops a blank clip rather than binding an empty src to <video>', () => {
    expect(videoSrcs(mountAttachments(undefined, `${MP4_D}||`))).toEqual([MP4_D])
  })
})

describe('ChatAttachments — mixed media and stray blanks', () => {
  it('renders both media kinds without cross-contaminating the lists', () => {
    const w = mountAttachments(`${PNG_A}||${PNG_B}`, MP4_D)
    expect(imgSrcs(w)).toEqual([PNG_A, PNG_B])
    expect(videoSrcs(w)).toEqual([MP4_D])
  })

  it('drops blanks from a list that did not come from the wire splitter', () => {
    // The renderer guard. A message can reach the template from a path the
    // splitter does not own — a persisted SSE row replayed from the local chat
    // cache, a future field — and `v-for` over a blank binds :src="".
    const w = mount(ChatAttachments, { props: { imageUrls: [PNG_A, '', '   ', PNG_B] } })
    expect(imgSrcs(w)).toEqual([PNG_A, PNG_B])
  })

  it('tolerates undefined arrays', () => {
    const w = mount(ChatAttachments, { props: {} })
    expect(imgSrcs(w)).toEqual([])
    expect(videoSrcs(w)).toEqual([])
  })
})

describe('ChatAttachments — lightbox', () => {
  it('emits the clicked URL so ChatView can open the preview', async () => {
    const w = mountAttachments(`${PNG_A}||${PNG_B}`)
    const thumbs = w.findAll('.chat-attached-image-thumb')
    expect(thumbs).toHaveLength(2)
    await thumbs[1]!.trigger('click')
    expect(w.emitted('open-image')).toEqual([[PNG_B]])
  })
})
