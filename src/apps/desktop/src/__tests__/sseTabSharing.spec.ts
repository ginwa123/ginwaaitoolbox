import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp } from 'vue'

import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import * as api from '../api'
import { FakeTabChannelHub, fakeForeignLeader, settle } from './fakes/fakeTabChannel'

const NAME = 'pabrik-sse-bus'

/** Fast coordinator timings for tests (production uses the defaults). */
const FAST = {
  channelName: NAME,
  heartbeatMs: 20,
  leaderTimeoutMs: 60,
  electionJitterMs: 5,
  hiddenTakeoverDelayMs: 40,
  isVisible: () => true,
}

function makeStubClient(initial: SseState = 'connecting'): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      stub.__stateListeners.push(cb)
      return () => {
        const i = stub.__stateListeners.indexOf(cb)
        if (i >= 0) stub.__stateListeners.splice(i, 1)
      }
    },
  }
  stub._state = initial
  stub.__stateListeners = [] as Array<(s: SseState, info: SseStateInfo) => void>
  return stub as SseClient
}

function emitStubState(c: SseClient, s: SseState): void {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const listeners = (c as any).__stateListeners as
    | Array<(s: SseState, info: SseStateInfo) => void>
    | undefined
  if (listeners) for (const cb of listeners) cb(s, {} as SseStateInfo)
}

describe('sseBus tab sharing — one SSE connection across every tab', () => {
  let hub: FakeTabChannelHub
  let spy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    __resetSseBus()
    hub = new FakeTabChannelHub()
    spy = vi.spyOn(api, 'createUnifiedSseConnection')
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it("sharing 'off' keeps the legacy behaviour: one client, no channel traffic", () => {
    spy.mockReturnValueOnce(makeStubClient())

    const bus = installSseBus(createApp({}), { tabSharing: 'off' })

    expect(spy).toHaveBeenCalledTimes(1)
    expect(bus.tabRole?.value).toBe('off')
    expect(hub.log).toHaveLength(0)
  })

  it("the default ('auto') stays solo under vitest so existing suites are untouched", () => {
    spy.mockReturnValueOnce(makeStubClient())

    const bus = installSseBus(createApp({}))

    expect(spy).toHaveBeenCalledTimes(1)
    expect(bus.tabRole?.value).toBe('off')
  })

  it("sharing 'on': this tab becomes the leader and opens exactly one client", async () => {
    spy.mockReturnValueOnce(makeStubClient('connecting'))

    const bus = installSseBus(createApp({}), {
      tabSharing: 'on',
      channelFactory: hub.create,
      tabChannelOptions: FAST,
    })
    await settle(40)

    expect(spy).toHaveBeenCalledTimes(1)
    expect(bus.tabRole?.value).toBe('leader')
  })

  it("sharing 'on' with another tab already leading: NO client is opened here", async () => {
    const foreign = fakeForeignLeader(hub, NAME)

    const bus = installSseBus(createApp({}), {
      tabSharing: 'on',
      channelFactory: hub.create,
      tabChannelOptions: FAST,
    })
    await settle(60)

    expect(spy).not.toHaveBeenCalled()
    expect(bus.tabRole?.value).toBe('follower')
    foreign.stop()
  })

  it('a follower receives the leader-forwarded events on the same channels', async () => {
    const foreign = fakeForeignLeader(hub, NAME)
    const bus = installSseBus(createApp({}), {
      tabSharing: 'on',
      channelFactory: hub.create,
      tabChannelOptions: FAST,
    })
    await settle(60)

    const seen: unknown[] = []
    bus.on('session', (e) => seen.push(e))
    const leaderChannel = foreign.channel
    leaderChannel.postMessage({
      k: 'event',
      tabId: 'foreign_leader',
      channel: 'session',
      payload: { id: 's_42', action: 'created' },
    })
    await settle(10)

    expect(seen).toEqual([{ id: 's_42', action: 'created' }])
    foreign.stop()
  })

  it("the follower's badge mirrors the leader's connection state", async () => {
    const foreign = fakeForeignLeader(hub, NAME)
    const bus = installSseBus(createApp({}), {
      tabSharing: 'on',
      channelFactory: hub.create,
      tabChannelOptions: FAST,
    })
    await settle(60)
    expect(bus.state.value).toBe('connecting')

    foreign.channel.postMessage({ k: 'state', tabId: 'foreign_leader', state: 'open' })
    await settle(10)
    expect(bus.state.value).toBe('open')

    foreign.channel.postMessage({ k: 'state', tabId: 'foreign_leader', state: 'reconnecting' })
    await settle(10)
    expect(bus.state.value).toBe('reconnecting')
    foreign.stop()
  })

  it('a follower\'s "Retry" reaches the leader instead of calling a local client', async () => {
    const foreign = fakeForeignLeader(hub, NAME)
    const bus = installSseBus(createApp({}), {
      tabSharing: 'on',
      channelFactory: hub.create,
      tabChannelOptions: FAST,
    })
    await settle(60)
    hub.log.length = 0

    bus.reconnectGlobal()
    await settle(10)

    const reconnectMsgs = hub.ofKind('reconnect')
    expect(reconnectMsgs).toHaveLength(1)
    // It must be addressed to the leader, not acted on locally (no client here).
    expect(spy).not.toHaveBeenCalled()
    foreign.stop()
  })

  it('the leader forwards its own clients events to the other tabs', async () => {
    const client = makeStubClient('connecting')
    spy.mockReturnValueOnce(client)

    installSseBus(createApp({}), {
      tabSharing: 'on',
      channelFactory: hub.create,
      tabChannelOptions: FAST,
    })
    await settle(40)

    // The bus passed channel callbacks to the client; fire one like the wire would.
    const opts = spy.mock.calls[0]![0] as unknown as {
      channels: { sessions: (e: unknown) => void }
    }
    hub.log.length = 0
    opts.channels.sessions({ id: 's_7', action: 'updated' })
    await settle(10)

    const forwarded = hub.ofKind('event')
    expect(forwarded).toHaveLength(1)
    expect((forwarded[0]!.msg as { channel: string }).channel).toBe('session')
  })

  it('the leader publishes its connection state to the followers', async () => {
    const client = makeStubClient('connecting')
    spy.mockReturnValueOnce(client)

    installSseBus(createApp({}), {
      tabSharing: 'on',
      channelFactory: hub.create,
      tabChannelOptions: FAST,
    })
    await settle(40)
    hub.log.length = 0

    emitStubState(client, 'open')
    await settle(10)

    const states = hub.ofKind('state')
    expect(states.length).toBeGreaterThanOrEqual(1)
    expect((states[0]!.msg as { state: string }).state).toBe('open')
  })

  it('a follower takes over when the leader closes its tab (bus.close + fresh install)', async () => {
    const foreign = fakeForeignLeader(hub, NAME)
    const bus = installSseBus(createApp({}), {
      tabSharing: 'on',
      channelFactory: hub.create,
      tabChannelOptions: FAST,
    })
    await settle(60)
    expect(bus.tabRole?.value).toBe('follower')

    // The leading tab disappears; this tab must claim the connection.
    foreign.stop()
    await settle(FAST.leaderTimeoutMs + 60)

    expect(spy).toHaveBeenCalledTimes(1)
    expect(bus.tabRole?.value).toBe('leader')
  })

  it('__setSseBusGlobalClient still swaps the client (test seam intact)', () => {
    spy.mockReturnValueOnce(makeStubClient('connecting'))
    const bus = installSseBus(createApp({}), { tabSharing: 'off' })

    const swapped = makeStubClient('open')
    __setSseBusGlobalClient(swapped)

    expect(bus.state.value).toBe('open')
  })
})
