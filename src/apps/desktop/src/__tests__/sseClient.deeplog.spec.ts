/**
 * Tests for the DEEP v2 logger in sseClient.ts.
 *
 * The "drops at 15s" bug surfaces as the SseClient transitioning to
 * 'reconnecting'. To diagnose it, the logger tracks:
 *   - per-message timing (sinceLastEventMs)
 *   - heartbeat count vs named-event count
 *   - stall detector (warn if no event in 7s while state=open)
 *   - rich error context (sinceLastEventMs, lastEventKind, readyStateLabel)
 *
 * These tests pin the behavior so a future refactor can't silently
 * remove the diagnostics.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { createSseClient } from '../helpers/sseClient'

// Minimal EventSource mock — captures every listener; `emit` fires them.
interface MockEventSource {
  url: string
  readyState: number
  close: () => void
  addEventListener: (t: string, l: EventListenerOrEventListenerObject) => void
  removeEventListener: (t: string, l: EventListenerOrEventListenerObject) => void
  emit: (t: string, data?: string) => void
  simulateOpen: (payload?: string) => void
}

function createMockCtor(): { ctor: typeof EventSource; instance: () => MockEventSource } {
  let captured: MockEventSource | null = null
  const ctor = function MockEventSource(this: unknown, url: string): MockEventSource {
    const listeners = new Map<string, Set<EventListenerOrEventListenerObject>>()
    const inst: MockEventSource = {
      url,
      readyState: 0,
      close() {
        // nothing
      },
      addEventListener(type, listener) {
        let set = listeners.get(type)
        if (!set) {
          set = new Set()
          listeners.set(type, set)
        }
        set.add(listener)
      },
      removeEventListener(type, listener) {
        const set = listeners.get(type)
        if (set) set.delete(listener)
      },
      emit(type, data) {
        const ev =
          data !== undefined
            ? new MessageEvent(type, { data })
            : new Event(type)
        const set = listeners.get(type)
        if (set) {
          for (const l of set) {
            if (typeof l === 'function') (l as (e: Event) => void)(ev)
            else (l as { handleEvent: (e: Event) => void }).handleEvent(ev)
          }
        }
      },
      simulateOpen(payload: string = '{"ok":true}') {
        inst.emit('connected', payload)
      },
    }
    captured = inst
    return inst
  } as unknown as typeof EventSource
  return { ctor, instance: () => captured! }
}

beforeEach(() => {
  ;(globalThis as { __sseDebug?: boolean }).__sseDebug = true
  ;(globalThis as { __sseStallDetector?: boolean }).__sseStallDetector = true
  Object.defineProperty(globalThis, 'navigator', {
    value: {
      connection: {
        effectiveType: '4g',
        downlink: 10,
        rtt: 50,
        saveData: false,
      },
    },
    configurable: true,
    writable: true,
  })
  vi.spyOn(console, 'log').mockImplementation(() => {})
})

afterEach(() => {
  vi.restoreAllMocks()
  delete (globalThis as { __sseDebug?: boolean }).__sseDebug
  delete (globalThis as { __sseStallDetector?: boolean }).__sseStallDetector
})

// Collects every log call into a searchable array. Strips the ISO
// prefix + t=... preamble because those vary run-to-run.
function parseLogCalls(): Array<{ msg: string; extra?: Record<string, unknown> }> {
  const out: Array<{ msg: string; extra?: Record<string, unknown> }> = []
  for (const c of (console.log as ReturnType<typeof vi.fn>).mock.calls) {
    const line = String(c[0])
    const m = line.match(/\] (\w[\w ]*?)(?: (\{.*\})|$)/)
    if (m) {
      // Group 1 is required by the regex pattern (the `m !== null` check
      // already proves group 1 matched a non-empty run); TypeScript's
      // RegExpMatchArray type still types captures as `string | undefined`,
      // so the `!` asserts what the regex guarantees.
      const msg = m[1]!
      const json = m[2]
      try {
        out.push({ msg, extra: json ? JSON.parse(json) : undefined })
      } catch {
        out.push({ msg })
      }
    }
  }
  return out
}

describe('SseClient deep v2 logger — per-message timing', () => {
  it('logs every heartbeat with sinceLastEventMs >= 5000', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
    })
    // Flush the setTimeout(start, 0) so the EventSource is constructed
    void vi.advanceTimersByTime(0)
    const es = mock.instance()

    es.simulateOpen('{"connected":true}')
    vi.advanceTimersByTime(5_000)
    es.emit('message', 'ping')
    vi.advanceTimersByTime(5_000)
    es.emit('message', 'ping')

    const calls = parseLogCalls()
    const heartbeats = calls.filter((c) => c.msg === 'heartbeat')
    expect(heartbeats.length).toBeGreaterThanOrEqual(2)
    // 2nd heartbeat reports ~5000ms since the 1st. The length check
    // above proves `heartbeats[1]` exists, so the `!` is safe.
    const second = heartbeats[1]!
    expect(second.extra?.sinceLastEventMs).toBeGreaterThanOrEqual(4_500)
    expect(second.extra?.sinceLastEventMs).toBeLessThan(6_000)
  })

  it('counts heartbeats and named events separately', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    const onEvent = vi.fn()
    createSseClient({
      url: '/x',
      onEvent,
      additionalEventTypes: ['custom_named'],
      EventSourceCtor: mock.ctor,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    es.emit('message', 'ping')
    es.emit('message', 'ping')
    es.emit('message', '{"hello":1}')

    // onEvent fires for: connected, 1 named message (NOT the 2 heartbeats)
    expect(onEvent).toHaveBeenCalledTimes(2)
    const calls = parseLogCalls()
    // heartbeatCount is in the heartbeat log payload — verify it advances
    const lastHeartbeat = calls.filter((c) => c.msg === 'heartbeat').at(-1)
    expect(lastHeartbeat?.extra?.heartbeatCount).toBe(2)
    // eventCount counts named events; connected incremented it to 1
    // before any heartbeat, so a heartbeat seen at this point shows 1
    expect(lastHeartbeat?.extra?.eventCount).toBe(1)
    const lastRealEvent = calls.filter((c) => c.msg === 'message').at(-1)
    expect(lastRealEvent?.extra?.eventCount).toBe(2)
  })
})

describe('SseClient deep v2 logger — stall detector', () => {
  it('fires STALL DETECTED if no event arrives in stallThresholdMs while state=open', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    // Don't fire any more events for 9s — stallThresholdMs is 7s in
    // production, we test with 9s so the assertion can be exactly 7s+
    // rather than timing-sensitive to the precision of vi.advanceTimersByTime.
    vi.advanceTimersByTime(9_000)

    const calls = parseLogCalls()
    const stallLine = calls.find((c) => c.msg === 'STALL DETECTED')
    expect(stallLine).toBeDefined()
    expect(stallLine?.extra?.sinceLastEventMs).toBeGreaterThanOrEqual(7_000)
    // The stall payload includes NetworkInformation API data
    expect(stallLine?.extra?.navConn).toBeDefined()
    expect((stallLine?.extra?.navConn as { effectiveType?: string })?.effectiveType).toBe('4g')
  })

  it('does NOT fire STALL DETECTED if events keep arriving every < stallThresholdMs', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    // Send one heartbeat every 5s for 30s — never let the stall
    // detector fire
    for (let i = 0; i < 6; i++) {
      vi.advanceTimersByTime(5_000)
      es.emit('message', 'ping')
    }
    const calls = parseLogCalls()
    const stallLine = calls.find((c) => c.msg === 'STALL DETECTED')
    expect(stallLine).toBeUndefined()
  })

  it('does NOT fire if state != open (e.g. during initial connecting)', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
    })
    void vi.advanceTimersByTime(0)
    // Don't fire connected — state is still 'connecting'.
    // After 8s, the stall detector must NOT fire because we're
    // not actually supposed to be receiving events yet.
    vi.advanceTimersByTime(8_000)
    const calls = parseLogCalls()
    expect(calls.find((c) => c.msg === 'STALL DETECTED')).toBeUndefined()
  })
})

describe('SseClient deep v2 logger — error event context', () => {
  it('error event captures sinceLastEventMs + lastEventKind in the log payload', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    es.emit('message', 'ping')
    // 12s of silence — simulate the user's symptom
    vi.advanceTimersByTime(12_000)
    es.emit('error')
    es.readyState = 0

    const calls = parseLogCalls()
    const errorLine = calls.find((c) => c.msg === 'EventSource raw error')
    expect(errorLine).toBeDefined()
    // 12s since last heartbeat, readyStateLabel=CONNECTING (per user trace)
    expect(errorLine?.extra?.sinceLastEventMs).toBeGreaterThanOrEqual(11_500)
    expect(errorLine?.extra?.lastEventKind).toBe('heartbeat')
    expect((errorLine?.extra?.heartbeatCount as number)).toBeGreaterThanOrEqual(1)
  })

  it('error event right after a message: sinceLastEventMs ~= 0ms', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    es.emit('message', '{"hello":1}')
    // No silence between message and error — connection died mid-stream
    es.emit('error')

    const calls = parseLogCalls()
    const errorLine = calls.find((c) => c.msg === 'EventSource raw error')
    expect(errorLine).toBeDefined()
    expect(errorLine?.extra?.sinceLastEventMs).toBeLessThan(100)
    expect(errorLine?.extra?.lastEventKind).toBe('message')
  })
})
