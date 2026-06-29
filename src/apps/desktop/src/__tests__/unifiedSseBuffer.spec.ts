/**
 * unifiedSseBuffer.spec.ts
 *
 * Regression test for Plan Reviewer finding #1 (in
 * docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md):
 *
 *   The unified factory's default-message handler MUST use a SINGLE
 *   shared buffer for the 3 default-`message` event families
 *   (workers, sessions, llm). Using one buffer per channel was
 *   tempting (symmetry) but would leak memory on the long-lived
 *   global SSE because every incoming event would be appended to
 *   ALL N buffers even though only 1 consumer matches the shape.
 *
 * What this test verifies
 * ────────────────────────
 * We cannot inspect the closure-private `defaultMessageBuf` directly.
 * Instead, we observe its EFFECT: after dispatching N events of one
 * shape, a subsequent event of a DIFFERENT shape must still parse +
 * dispatch correctly. If the buffer had leaked (buggy per-channel
 * buffers), each non-matching buffer would accumulate N events and
 * the parser would corrupt the next shape's parse — either dispatching
 * the wrong event, dispatching nothing, or throwing.
 *
 * Concretely:
 *   1. Fire 100 worker-shape events.   → workers cb fires 100 times.
 *   2. Fire 1 session-shape event.    → session cb fires exactly once.
 *   3. Fire 1 llm-shape event.        → llm cb fires exactly once.
 *
 * With the buggy 3-buffer design:
 *   - The "session buffer" would contain 100 worker events + 1
 *     session event. The parser's `indexOf('{')` finds the FIRST
 *     `{` and `lastIndexOf('}')` finds the LAST `}` — slicing
 *     produces a malformed multi-object string. JSON.parse throws,
 *     the catch-arm slices past `jsonStart+1` (1 byte), and the
 *     rest of the accumulated garbage stays in the buffer.
 *   - The "llm buffer" suffers the same corruption.
 *   - The session/llm callbacks would NEVER fire (parse throws
 *     before the dispatch).
 *
 * With the correct 1-buffer design:
 *   - After each worker dispatch, the buffer is sliced to empty
 *     (or to just a trailing '\n').
 *   - The next session event arrives with a clean buffer, parses
 *     correctly, dispatches exactly once.
 *   - The next llm event does the same.
 *
 * Why we spy on `createSseClient` (not the EventSource)
 * ──────────────────────────────────────────────────────
 * Spying on `createSseClient` lets us capture the `onEvent`
 * callback directly — no need for a mock EventSource, no fake
 * timers, no `setTimeout(start, 0)` deferral. We just call
 * `onEvent(rawString, 'message')` and assert behavior. This is
 * the most surgical test of the factory's INTERNAL logic.
 *
 * If a future refactor adds 3 per-channel buffers, this test
 * will fail with `expected session cb to fire 1 times, got 0`.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { createUnifiedSseConnection } from '../api'
import * as sseClient from '../helpers/sseClient'

describe('createUnifiedSseConnection: single-buffer design (regression for Plan Reviewer #1)', () => {
  // Mock the SseClient so we capture the onEvent callback without
  // needing a real EventSource. Returns a stub SseClient (we never
  // call .close() etc. in these tests).
  //
  // Spy lifecycle note: vi.spyOn() returns a live spy. We set the
  // mockImplementation once at describe-level (NOT in beforeEach,
  // because vi.spyOn() + vi.mockRestore() in afterEach would tear
  // the spy down and the next beforeEach's mockImplementation call
  // would be on a dead spy). Instead, we just reset capturedOnEvent
  // and the mockImplementation re-uses the closure-scoped variable
  // fresh each test by reassigning the implementation in beforeEach
  // WITHOUT calling mockRestore.
  const spy = vi.spyOn(sseClient, 'createSseClient')
  let capturedOnEvent: ((raw: string, eventType: string) => void) | null = null

  beforeEach(() => {
    capturedOnEvent = null
    spy.mockImplementation(((opts: sseClient.SseClientOptions) => {
      capturedOnEvent = opts.onEvent
      return {
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open' as const,
        onStateChange: () => () => {},
      }
    }) as unknown as typeof sseClient.createSseClient)
  })

  it('does not corrupt the buffer when 100 worker events are followed by 1 session event', () => {
    const workersCb = vi.fn()
    const sessionsCb = vi.fn()

    createUnifiedSseConnection({
      channels: {
        workers: workersCb,
        sessions: sessionsCb,
      },
    })

    // Sanity: the spy captured onEvent.
    expect(capturedOnEvent).not.toBeNull()

    // Fire 100 worker-shape events. Each MUST dispatch to workersCb.
    for (let i = 0; i < 100; i++) {
      const ev = JSON.stringify({
        action: 'updated',
        id: `worker-${i}`,
        session_id: `session-${i}`,
        working_directory: `/tmp/worker-${i}`,
        last_activity: 1700000000 + i,
        last_activity_description: `tick ${i}`,
        created_at: '2026-06-30T00:00:00Z',
      })
      capturedOnEvent!(ev, 'message')
    }

    // All 100 worker events dispatched.
    expect(workersCb).toHaveBeenCalledTimes(100)

    // Now fire 1 session-shape event. If the buffer were leaked (per-
    // channel buffers), this event would be appended to a "session
    // buffer" that already contains 100 worker events, and the parser
    // would produce malformed JSON → session cb fires 0 times.
    const sessionEvent = JSON.stringify({
      action: 'updated',
      id: 'session-final',
      name: 'Final Session',
      status: 'active',
      cwd: '/home/ginwa/project',
      created_at: '2026-06-30T00:00:00Z',
      updated_at: '2026-06-30T00:00:01Z',
    })
    capturedOnEvent!(sessionEvent, 'message')

    // With the correct (1-buffer) design: session cb fires exactly 1
    // time, and the dispatched object is the session event — not
    // garbage, not a worker event.
    expect(sessionsCb).toHaveBeenCalledTimes(1)
    const dispatchedSession = sessionsCb.mock.calls[0]![0] as { id: string; action: string; status: string }
    expect(dispatchedSession.id).toBe('session-final')
    expect(dispatchedSession.action).toBe('updated')
    expect(dispatchedSession.status).toBe('active')
  })

  it('does not corrupt the buffer when 100 worker events are followed by 1 llm event', () => {
    const workersCb = vi.fn()
    const llmCb = vi.fn()

    createUnifiedSseConnection({
      channels: {
        workers: workersCb,
        llm: { sessionId: 'sid-abc', onEvent: llmCb },
      },
    })

    expect(capturedOnEvent).not.toBeNull()

    for (let i = 0; i < 100; i++) {
      const ev = JSON.stringify({
        action: 'updated',
        id: `worker-${i}`,
        session_id: `session-${i}`,
        working_directory: `/tmp/worker-${i}`,
        last_activity: 1700000000 + i,
        last_activity_description: `tick ${i}`,
        created_at: '2026-06-30T00:00:00Z',
      })
      capturedOnEvent!(ev, 'message')
    }
    expect(workersCb).toHaveBeenCalledTimes(100)

    // Fire an llm chunk event. The llm discriminator requires
    // `type === 'chunk' | 'full'`. If the buffer were leaked, this
    // would never dispatch (parse throws on malformed multi-object
    // string).
    const llmChunk = JSON.stringify({
      type: 'chunk',
      content: 'hello world',
      session_id: 'sid-abc',
    })
    capturedOnEvent!(llmChunk, 'message')

    expect(llmCb).toHaveBeenCalledTimes(1)
    const dispatchedLlm = llmCb.mock.calls[0]![0] as { type: string; content: string; session_id: string }
    expect(dispatchedLlm.type).toBe('chunk')
    expect(dispatchedLlm.content).toBe('hello world')
    expect(dispatchedLlm.session_id).toBe('sid-abc')
  })

  it('dispatches interleaved workers + sessions events independently (single buffer is sliced per dispatch)', () => {
    const workersCb = vi.fn()
    const sessionsCb = vi.fn()
    const llmCb = vi.fn()

    createUnifiedSseConnection({
      channels: {
        workers: workersCb,
        sessions: sessionsCb,
        llm: { sessionId: 'sid-xyz', onEvent: llmCb },
      },
    })

    expect(capturedOnEvent).not.toBeNull()

    // 100 interleaved events — workers, sessions, llm, workers, sessions, llm, …
    for (let i = 0; i < 100; i++) {
      // 1/3 of events are worker-shape
      capturedOnEvent!(
        JSON.stringify({
          action: 'updated',
          id: `w-${i}`,
          session_id: `s-${i}`,
          working_directory: `/tmp/w-${i}`,
          last_activity: 1700000000 + i,
          last_activity_description: `tick ${i}`,
          created_at: '2026-06-30T00:00:00Z',
        }),
        'message',
      )
      // 1/3 are session-shape
      capturedOnEvent!(
        JSON.stringify({
          action: 'updated',
          id: `sess-${i}`,
          name: `S ${i}`,
          status: 'active',
          cwd: `/tmp/sess-${i}`,
          created_at: '2026-06-30T00:00:00Z',
          updated_at: '2026-06-30T00:00:01Z',
        }),
        'message',
      )
      // 1/3 are llm-shape
      capturedOnEvent!(
        JSON.stringify({ type: 'chunk', content: `chunk ${i}`, session_id: 'sid-xyz' }),
        'message',
      )
    }

    // Each channel cb fires exactly the expected number of times —
    // and only for events matching its shape.
    expect(workersCb).toHaveBeenCalledTimes(100)
    expect(sessionsCb).toHaveBeenCalledTimes(100)
    expect(llmCb).toHaveBeenCalledTimes(100)

    // Spot-check that each callback received the right kind of event.
    const firstWorker = workersCb.mock.calls[0]![0] as { id: string }
    expect(firstWorker.id).toBe('w-0')
    const firstSession = sessionsCb.mock.calls[0]![0] as { id: string }
    expect(firstSession.id).toBe('sess-0')
    const firstLlm = llmCb.mock.calls[0]![0] as { content: string }
    expect(firstLlm.content).toBe('chunk 0')
  })

  it('resets the buffer on a connected event (no leakage across reconnects)', () => {
    const workersCb = vi.fn()

    createUnifiedSseConnection({ channels: { workers: workersCb } })

    expect(capturedOnEvent).not.toBeNull()

    // Simulate the server sending a 'connected' event mid-stream
    // (e.g. reconnect). This MUST reset the buffer — leftover bytes
    // from a previous connection would corrupt the next parse.
    capturedOnEvent!('{"connected":true}', 'connected')

    // After connected, fire a worker event. Should dispatch.
    capturedOnEvent!(
      JSON.stringify({
        action: 'updated',
        id: 'w-after-reconnect',
        session_id: 's-1',
        working_directory: '/tmp/w-1',
        last_activity: 1700000000,
        last_activity_description: 'after reconnect',
        created_at: '2026-06-30T00:00:00Z',
      }),
      'message',
    )

    expect(workersCb).toHaveBeenCalledTimes(1)
    const dispatched = workersCb.mock.calls[0]![0] as { id: string }
    expect(dispatched.id).toBe('w-after-reconnect')
  })

  it('does not dispatch a worker event to the sessions channel (shape discrimination is correct)', () => {
    // Defense against the obvious footgun: an event with `action`
    // should NEVER be dispatched to sessions if it doesn't have
    // `status + cwd`. The discriminator checks all 3 fields.
    const sessionsCb = vi.fn()
    const workersCb = vi.fn()

    createUnifiedSseConnection({
      channels: { sessions: sessionsCb, workers: workersCb },
    })

    // Worker-shape event (has action + working_directory, no status/cwd).
    capturedOnEvent!(
      JSON.stringify({
        action: 'updated',
        id: 'w-1',
        session_id: 's-1',
        working_directory: '/tmp/w-1',
        last_activity: 1700000000,
        last_activity_description: 'tick',
        created_at: '2026-06-30T00:00:00Z',
      }),
      'message',
    )

    expect(workersCb).toHaveBeenCalledTimes(1)
    expect(sessionsCb).toHaveBeenCalledTimes(0)

    // Session-shape event (has action + status + cwd).
    capturedOnEvent!(
      JSON.stringify({
        action: 'updated',
        id: 'sess-1',
        name: 'S',
        status: 'active',
        cwd: '/tmp/sess-1',
        created_at: '2026-06-30T00:00:00Z',
        updated_at: '2026-06-30T00:00:01Z',
      }),
      'message',
    )

    expect(sessionsCb).toHaveBeenCalledTimes(1)
    // Worker cb was NOT called for the session event.
    expect(workersCb).toHaveBeenCalledTimes(1)
  })

  /**
   * Regression for Code Reviewer Critical Fix (2026-06-30):
   * when the caller's `channels` set does NOT include a consumer for
   * a default-message event shape the backend emits, the buffer
   * MUST still advance past the event. Otherwise the buffer grows
   * unboundedly on every dropped event.
   *
   * Setup: subscribe only to `kanban` (no workers/sessions/llm).
   * Action: fire 50 worker-shaped default-message events (which no
   * consumer will match), then fire 1 kanban named event.
   * Expectation: the kanban callback fires (buffer didn't get
   * corrupted). The buffer was advanced past every worker event
   * even though no consumer matched.
   *
   * Without the fix: the buffer accumulates 50 worker events, then
   * `indexOf('{')` and `lastIndexOf('}')` span ALL of them,
   * producing malformed JSON, which trips `JSON.parse`, which
   * slides 1 byte, and the buffer becomes a tangled mess — the
   * kanban event never reaches the consumer.
   */
  it('advances the buffer past default-message events with no matching consumer', () => {
    // Re-spy with a fresh mockImplementation (the describe-level
    // spy already exists; just update its impl to capture the new
    // onEvent arg from this test's createUnifiedSseConnection call).
    spy.mockImplementation(((opts: sseClient.SseClientOptions) => {
      capturedOnEvent = opts.onEvent
      return {
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open' as const,
        onStateChange: () => () => {},
      }
    }) as unknown as typeof sseClient.createSseClient)

    const kanbanCb = vi.fn()
    // Note: NO workers/sessions/llm consumer — only kanban.
    createUnifiedSseConnection({
      channels: { kanban: kanbanCb },
    })

    // Fire 50 worker-shaped default-message events. None should
    // dispatch (no workers consumer), but the buffer MUST advance.
    for (let i = 0; i < 50; i++) {
      capturedOnEvent!(
        JSON.stringify({
          action: 'updated',
          id: `w-${i}`,
          session_id: `task_${i}`,
          working_directory: '/tmp/w',
          last_activity: 0,
          last_activity_description: 'tick',
          created_at: '2026-06-30T00:00:00Z',
        }),
        'message',
      )
    }

    // Now fire a kanban named event — it MUST reach the consumer.
    // (If the buffer had been corrupted by accumulated bytes, the
    // JSON.parse for the next default-message event would have
    // failed silently and the kanban named-event branch would
    // still work since named events are dispatched independently.
    // To really catch the bug we need a default-message event AFTER
    // the dropped events — see below.)
    capturedOnEvent!(
      JSON.stringify({
        action: 'created',
        workspace_id: 'ws-1',
        item_id: 'item-1',
        column_id: 'col-1',
      }),
      'kanban_column',
    )

    expect(kanbanCb).toHaveBeenCalledTimes(1)
    // The bug doesn't fire the kanban cb with the right payload if
    // the buffer had been corrupted. Verify the payload is intact.
    expect(kanbanCb).toHaveBeenCalledWith(
      expect.objectContaining({ column_id: 'col-1', action: 'created' }),
    )

    // Follow up: fire a VALID default-message event AFTER the dropped
    // ones. If the buffer was tangled, this `indexOf('{')` would
    // land inside the LAST dropped event, `lastIndexOf('}')` would
    // land at the end of the kanban cb invocation's leftover
    // bytes, the slice would be malformed JSON, JSON.parse would
    // fail, and the cb would never fire. With the fix, the buffer
    // is clean and the dispatch works.
    const afterCb = vi.fn()
    const client2 = createUnifiedSseConnection({
      channels: {
        kanban: () => {},
        sessions: afterCb,
      },
    })
    void client2

    // Drop a worker event (no workers consumer — sessions-cb
    // shouldn't fire either since neither discriminator matches).
    capturedOnEvent!(
      JSON.stringify({
        action: 'updated',
        id: 'w-x',
        session_id: 'task_x',
        working_directory: '/tmp/w',
        last_activity: 0,
        last_activity_description: 'tick',
        created_at: '2026-06-30T00:00:00Z',
      }),
      'message',
    )

    // Now fire a session event — MUST dispatch cleanly.
    capturedOnEvent!(
      JSON.stringify({
        action: 'updated',
        id: 's-1',
        name: 'S',
        status: 'active',
        cwd: '/tmp/s',
        created_at: '2026-06-30T00:00:00Z',
        updated_at: '2026-06-30T00:00:01Z',
      }),
      'message',
    )

    expect(afterCb).toHaveBeenCalledTimes(1)
  })
})