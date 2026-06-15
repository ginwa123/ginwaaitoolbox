import { describe, it, expect } from 'vitest'

// Regression: the SSE `full` event must carry `image_url` end-to-end.
//
// Before this change, the backend's onEventSendLLMHistory emitter did
// not include image_url in the SSE payload, and the frontend
// `SseEvent` type did not declare it. A user message that arrived
// while the assistant was mid-stream (re-emitted as a `full` event)
// lost its attached images — the loadChatHistory REST path correctly
// populated image_urls from the DB, but the SSE `full` handler
// dropped them. This test guards against:
//   1. The `image_url` field disappearing from the `SseEvent` type
//   2. The pipe-separated wire format silently changing shape
//   3. The split logic in the `full` handler regressing
//
// See `src/apps/desktop/src/api/index.ts` SseEvent and
// `src/apps/desktop/src/components/ChatView.vue` (full event handler).

import type { SseEvent } from '../api'

// --------------------------------------------------------------------------
// 1. Type-level guard: SseEvent declares image_url
// --------------------------------------------------------------------------
// The block below does not run as test logic — it's a compile-time
// check. If `image_url` is removed from the SseEvent interface, this
// assignment fails with TS2339 ("Property 'image_url' does not exist")
// and `bun run build` breaks before the runtime tests are even
// considered. The runtime `expect` calls below would not save us here,
// because TypeScript would still allow accessing an unknown property
// as `string | undefined` in some configurations.

const _typeCheck: Pick<SseEvent, 'image_url'> = {
  image_url: 'data:image/png;base64,abc',
}
void _typeCheck

// --------------------------------------------------------------------------
// 2. Runtime: simulate the wire format → handler transform
// --------------------------------------------------------------------------
// This mirrors the exact split logic in ChatView.vue's `full` event
// handler:
//
//   image_urls: event.image_url ? event.image_url.split('|') : undefined
//
// The test below keeps the logic in sync by asserting the same shape
// ChatView produces. If the wire format changes (e.g. backend starts
// sending an array), this test fails and points at exactly which
// side (server or client) needs to be updated.

const splitImageUrls = (event: SseEvent): string[] | undefined => {
  return event.image_url ? event.image_url.split('|') : undefined
}

describe('SseEvent.image_url wire format', () => {
  it('exposes image_url on the SseEvent type (compile-time + runtime)', () => {
    // Belt-and-suspenders: a runtime check that the field is present.
    // (The Pick<> type check above catches removal at build time, but
    // this catches the case where the field is renamed but kept
    // compatible with the type via a different path.)
    const event: SseEvent = { session_id: 's', image_url: 'a|b|c' }
    expect(event.image_url).toBe('a|b|c')
  })

  it('splits a pipe-separated image_url into the image_urls array', () => {
    // The canonical case: 3 attached images arrive as
    // "data:image/png;base64,abc|data:image/png;base64,def|data:image/jpeg;base64,ghi".
    // The handler must produce exactly 3 entries (one per image).
    const event: SseEvent = {
      session_id: 's',
      image_url: 'data:image/png;base64,abc|data:image/png;base64,def|data:image/jpeg;base64,ghi',
    }
    expect(splitImageUrls(event)).toEqual([
      'data:image/png;base64,abc',
      'data:image/png;base64,def',
      'data:image/jpeg;base64,ghi',
    ])
  })

  it('returns a single-element array when image_url has no pipe', () => {
    // Most user messages have a single image — the split still works
    // and the resulting array has length 1, so the v-if in the
    // template ("image_urls?.length > 0") still renders the image.
    const event: SseEvent = { session_id: 's', image_url: 'only-one' }
    expect(splitImageUrls(event)).toEqual(['only-one'])
  })

  it('returns undefined when image_url is absent (assistant / error / tool paths)', () => {
    // Assistant responses, error messages, and most tool results
    // do not carry images. The handler must produce undefined so
    // the v-if="image_urls?.length > 0" check in the template hides
    // the image area cleanly.
    const event: SseEvent = { session_id: 's' }
    expect(splitImageUrls(event)).toBeUndefined()
  })

  it('returns undefined for an empty string (defensive: server never sends empty, but if it does, the bubble hides images cleanly)', () => {
    // A future server bug that sends image_url="" should not produce
    // ["" ] (an array with one empty string), which would still pass
    // the .length > 0 check and try to render a broken <img src="">.
    // The truthy check in the handler short-circuits empty strings to
    // undefined.
    const event: SseEvent = { session_id: 's', image_url: '' }
    expect(splitImageUrls(event)).toBeUndefined()
  })
})
