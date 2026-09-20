import { describe, expect, it } from 'vitest'

import {
  CHAT_HTML_FRAME_RESIZE_SOURCE,
  FRAME_NO_SCROLLBAR_STYLE,
  MAX_FRAME_HEIGHT,
  MIN_FRAME_HEIGHT,
  PREVIEW_AUTO_RESIZE_SCRIPT,
  PREVIEW_AUTO_RESIZE_SOURCE,
  autoResizeScript,
  clampFrameHeight,
  findSenderFrame,
  growFrameToContent,
  readAutoResizeHeight,
} from '@/helpers/iframeAutoResize'

/** Minimal MessageEvent stand-in — the helpers only read `data`/`source`. */
const msg = (data: unknown, source: unknown = null): MessageEvent =>
  ({ data, source }) as unknown as MessageEvent

describe('clampFrameHeight', () => {
  it('keeps an in-range height', () => {
    expect(clampFrameHeight(640)).toBe(640)
  })

  it('clamps below the minimum (an empty/short frame must not collapse)', () => {
    expect(clampFrameHeight(12)).toBe(MIN_FRAME_HEIGHT)
  })

  it('clamps above the maximum (runaway content stays scrollable)', () => {
    expect(clampFrameHeight(99999)).toBe(MAX_FRAME_HEIGHT)
  })

  it('falls back to the minimum for a non-finite height', () => {
    expect(clampFrameHeight(Number.NaN)).toBe(MIN_FRAME_HEIGHT)
    expect(clampFrameHeight(Number.POSITIVE_INFINITY)).toBe(MAX_FRAME_HEIGHT)
  })

  it('honours explicit bounds (the preview HTML iframe uses 200..2000)', () => {
    expect(clampFrameHeight(10, 200, 2000)).toBe(200)
    expect(clampFrameHeight(5000, 200, 2000)).toBe(2000)
  })
})

describe('readAutoResizeHeight', () => {
  it('reads the height reported by its own source tag', () => {
    expect(
      readAutoResizeHeight(
        msg({ source: CHAT_HTML_FRAME_RESIZE_SOURCE, height: 812 }),
        CHAT_HTML_FRAME_RESIZE_SOURCE,
      ),
    ).toBe(812)
  })

  it("ignores another consumer's frames (preview vs chat tags)", () => {
    expect(
      readAutoResizeHeight(
        msg({ source: PREVIEW_AUTO_RESIZE_SOURCE, height: 812 }),
        CHAT_HTML_FRAME_RESIZE_SOURCE,
      ),
    ).toBeNull()
  })

  it('ignores foreign / malformed messages', () => {
    expect(readAutoResizeHeight(msg(null), CHAT_HTML_FRAME_RESIZE_SOURCE)).toBeNull()
    expect(readAutoResizeHeight(msg('hello'), CHAT_HTML_FRAME_RESIZE_SOURCE)).toBeNull()
    expect(readAutoResizeHeight(msg({}), CHAT_HTML_FRAME_RESIZE_SOURCE)).toBeNull()
    expect(
      readAutoResizeHeight(
        msg({ source: CHAT_HTML_FRAME_RESIZE_SOURCE }),
        CHAT_HTML_FRAME_RESIZE_SOURCE,
      ),
    ).toBeNull()
    expect(
      readAutoResizeHeight(
        msg({ source: CHAT_HTML_FRAME_RESIZE_SOURCE, height: 'tall' }),
        CHAT_HTML_FRAME_RESIZE_SOURCE,
      ),
    ).toBeNull()
    expect(
      readAutoResizeHeight(
        msg({ source: CHAT_HTML_FRAME_RESIZE_SOURCE, height: 0 }),
        CHAT_HTML_FRAME_RESIZE_SOURCE,
      ),
    ).toBeNull()
  })
})

describe('findSenderFrame', () => {
  it('returns the frame whose contentWindow sent the message', () => {
    document.body.innerHTML =
      '<iframe class="chat-html-frame" id="a"></iframe>' +
      '<iframe class="chat-html-frame" id="b"></iframe>'
    const frames = document.querySelectorAll<HTMLIFrameElement>('.chat-html-frame')
    const target = frames[1]
    expect(target?.contentWindow).toBeTruthy()

    const found = findSenderFrame(document, msg({}, target?.contentWindow), '.chat-html-frame')
    expect(found).toBe(target)
  })

  it('returns null for a sender that is not one of our frames', () => {
    document.body.innerHTML = '<iframe class="chat-html-frame" id="a"></iframe>'
    const frames = document.querySelectorAll<HTMLIFrameElement>('.chat-html-frame')
    expect(
      findSenderFrame(document, msg({}, frames[0]?.contentWindow), 'iframe.chat-preview-frame'),
    ).toBeNull()
    expect(findSenderFrame(document, msg({}, window), 'iframe.chat-html-frame')).toBeNull()
    expect(findSenderFrame(document, msg({}, null), 'iframe.chat-html-frame')).toBeNull()
  })
})

describe('autoResizeScript', () => {
  it("tags the report with the caller's source and posts it to the parent", () => {
    const script = autoResizeScript(CHAT_HTML_FRAME_RESIZE_SOURCE)
    expect(script).toContain(JSON.stringify(CHAT_HTML_FRAME_RESIZE_SOURCE))
    expect(script).toContain('parent.postMessage')
    expect(script).toContain('scrollHeight')
    // Emitted as a real script element (the helper splits the tag so the
    // literal can live in a TS source file without closing it early).
    expect(script.startsWith('<script>')).toBe(true)
    expect(script.endsWith('</script>')).toBe(true)
    // The script itself must not close a surrounding <script> block early:
    // only the final tag exists.
    expect(script.split('</script>').length - 1).toBe(1)
  })

  it('pre-tags the preview HTML iframe with its own source', () => {
    expect(PREVIEW_AUTO_RESIZE_SCRIPT).toContain(JSON.stringify(PREVIEW_AUTO_RESIZE_SOURCE))
  })
})

describe('growFrameToContent (no inner scrollbar)', () => {
  it('grows past the old 2000px cap instead of clipping behind a scrollbar', () => {
    expect(growFrameToContent(5000)).toBe(5000)
    expect(growFrameToContent(99999)).toBe(99999)
  })

  it('keeps the minimum floor for empty/short frames', () => {
    expect(growFrameToContent(12)).toBe(MIN_FRAME_HEIGHT)
    expect(growFrameToContent(0)).toBe(MIN_FRAME_HEIGHT)
    expect(growFrameToContent(Number.NaN)).toBe(MIN_FRAME_HEIGHT)
  })

  it('hides page-level scrollbars without touching inner pre scrolling', () => {
    expect(FRAME_NO_SCROLLBAR_STYLE).toContain('overflow:hidden')
    expect(FRAME_NO_SCROLLBAR_STYLE).toContain('scrollbar-width:none')
    expect(FRAME_NO_SCROLLBAR_STYLE).toContain('::-webkit-scrollbar')
  })
})
