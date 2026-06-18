// src/apps/desktop/src/__tests__/FileInput.mic.spec.ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import MicButton from '../components/MicButton.vue'

// ── Programmable MediaRecorder mock ───────────────────────────────────────

interface MockMediaRecorder {
  start: ReturnType<typeof vi.fn>
  stop: ReturnType<typeof vi.fn>
  pause: ReturnType<typeof vi.fn>
  resume: ReturnType<typeof vi.fn>
  state: 'inactive' | 'recording' | 'paused'
  emitDataAvailable: (blob: Blob) => void
  emitStop: () => void
  emitError: (message: string) => void
  dataavailableHandler: ((ev: { data: Blob }) => void) | null
  stopHandler: ((ev: Event) => void) | null
  errorHandler: ((ev: { error?: Error }) => void) | null
}

function createMockMediaRecorder(): MockMediaRecorder {
  const mr: MockMediaRecorder = {
    start: vi.fn(),
    stop: vi.fn(),
    pause: vi.fn(),
    resume: vi.fn(),
    state: 'inactive',
    dataavailableHandler: null,
    stopHandler: null,
    errorHandler: null,
    emitDataAvailable(blob: Blob) {
      mr.dataavailableHandler?.({ data: blob })
    },
    emitStop() {
      mr.stopHandler?.(new Event('stop'))
    },
    emitError(message: string) {
      mr.errorHandler?.({ error: new Error(message) })
    },
  }
  mr.start.mockImplementation(() => {
    mr.state = 'recording'
  })
  mr.stop.mockImplementation(() => {
    mr.state = 'inactive'
  })
  return mr
}

// Capture the MediaRecorder instance the component creates, so tests
// can drive its event handlers.
let lastRecorder: MockMediaRecorder | null = null

vi.stubGlobal(
  'MediaRecorder',
  class {
    constructor(_stream: MediaStream) {
      lastRecorder = createMockMediaRecorder()
      return lastRecorder as unknown as MediaRecorder
    }
    static readonly inactive = 'inactive'
    static readonly recording = 'recording'
    static readonly paused = 'paused'
    addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      // Wire up the captured handler refs so the test's emit*() helpers can fire them.
      const l = listener as (ev: unknown) => void
      if (type === 'dataavailable') {
        lastRecorder!.dataavailableHandler = l as MockMediaRecorder['dataavailableHandler']
      } else if (type === 'stop') {
        lastRecorder!.stopHandler = l as MockMediaRecorder['stopHandler']
      } else if (type === 'error') {
        lastRecorder!.errorHandler = l as MockMediaRecorder['errorHandler']
      }
    }
    removeEventListener() {}
    requestData() {}
  },
)

// Stub getUserMedia to return a fake MediaStream synchronously.
const getUserMediaMock = vi.fn(async () => ({
  getTracks: () => [{ kind: 'audio', stop: vi.fn() }],
  getAudioTracks: () => [{ kind: 'audio', stop: vi.fn() }],
}))
vi.stubGlobal('navigator', {
  mediaDevices: {
    getUserMedia: getUserMediaMock,
  },
})

// Stub apiTranscribe so we can control transcription responses.
vi.mock('../api/transcribe', () => ({
  apiTranscribe: vi.fn(),
}))
import { apiTranscribe } from '../api/transcribe'
const apiTranscribeMock = apiTranscribe as ReturnType<typeof vi.fn>

// ── Tests ──────────────────────────────────────────────────────────────────

describe('MicButton — toggle mode', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    lastRecorder = null
    apiTranscribeMock.mockReset()
    getUserMediaMock.mockReset()
    // Default: getUserMedia succeeds with a fake stream.
    getUserMediaMock.mockResolvedValue({
      getTracks: () => [{ kind: 'audio', stop: vi.fn() }],
      getAudioTracks: () => [{ kind: 'audio', stop: vi.fn() }],
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.clearAllMocks()
  })

  it('renders an idle mic button by default', () => {
    wrapper = mount(MicButton)
    expect(wrapper.find('[data-testid="mic-button"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('idle')
  })

  it('click toggles into recording state and starts MediaRecorder', async () => {
    wrapper = mount(MicButton)
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    expect(lastRecorder).not.toBeNull()
    expect(lastRecorder!.start).toHaveBeenCalledTimes(1)
    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('recording')
  })

  it('clicking again stops recording, transcribes, and emits the text', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'hello world' })

    wrapper = mount(MicButton)
    const btn = wrapper.find('[data-testid="mic-button"]')

    // First click → start recording
    await btn.trigger('click')
    await flushPromises()
    expect(lastRecorder).not.toBeNull()
    expect(lastRecorder!.start).toHaveBeenCalledTimes(1)

    // Second click → stop recording (toggle off)
    await btn.trigger('click')
    expect(lastRecorder!.stop).toHaveBeenCalledTimes(1)

    // Simulate browser firing dataavailable + stop on the MediaRecorder
    const audioBlob = new Blob(['fake-audio'], { type: 'audio/webm' })
    lastRecorder!.emitDataAvailable(audioBlob)
    lastRecorder!.emitStop()
    await flushPromises()

    // apiTranscribe was called with the blob
    expect(apiTranscribeMock).toHaveBeenCalledTimes(1)
    expect(apiTranscribeMock.mock.calls[0]?.[0]).toBe(audioBlob)

    // emitted with the transcribed text
    const emitted = wrapper.emitted('transcribed')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['hello world'])

    // returns to idle
    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('idle')
  })

  it('shows processing state while transcription is in flight', async () => {
    let resolveTranscribe: (v: { text: string }) => void
    apiTranscribeMock.mockImplementationOnce(
      () => new Promise((resolve) => { resolveTranscribe = resolve }),
    )

    wrapper = mount(MicButton)
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    // Now in 'processing' state
    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('processing')

    // Resolve transcription
    resolveTranscribe!({ text: 'done' })
    await flushPromises()
    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('idle')
  })
})

describe('MicButton — hold mode', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    lastRecorder = null
    apiTranscribeMock.mockReset()
    getUserMediaMock.mockReset()
    getUserMediaMock.mockResolvedValue({
      getTracks: () => [{ kind: 'audio', stop: vi.fn() }],
      getAudioTracks: () => [{ kind: 'audio', stop: vi.fn() }],
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.clearAllMocks()
  })

  it('mousedown starts recording, mouseup stops and transcribes', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'hold text' })

    wrapper = mount(MicButton)
    const btn = wrapper.find('[data-testid="mic-button"]')

    await btn.trigger('mousedown')
    await flushPromises()
    expect(lastRecorder!.start).toHaveBeenCalledTimes(1)
    expect(btn.attributes('data-state')).toBe('recording')

    await btn.trigger('mouseup')
    expect(lastRecorder!.stop).toHaveBeenCalledTimes(1)

    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    expect(apiTranscribeMock).toHaveBeenCalledTimes(1)
    const emitted = wrapper.emitted('transcribed')
    expect(emitted![0]).toEqual(['hold text'])
  })

  it('touchstart starts recording, touchend stops it', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'touch text' })

    wrapper = mount(MicButton)
    const btn = wrapper.find('[data-testid="mic-button"]')

    await btn.trigger('touchstart')
    await flushPromises()
    expect(lastRecorder!.start).toHaveBeenCalledTimes(1)

    await btn.trigger('touchend')
    expect(lastRecorder!.stop).toHaveBeenCalledTimes(1)
  })
})

describe('MicButton — error states', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    lastRecorder = null
    apiTranscribeMock.mockReset()
    getUserMediaMock.mockReset()
    getUserMediaMock.mockResolvedValue({
      getTracks: () => [{ kind: 'audio', stop: vi.fn() }],
      getAudioTracks: () => [{ kind: 'audio', stop: vi.fn() }],
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.clearAllMocks()
  })

  it('shows error state and emits error when getUserMedia is denied', async () => {
    // Override getUserMedia for this test
    getUserMediaMock.mockRejectedValueOnce(new Error('Permission denied'))

    wrapper = mount(MicButton)
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('error')
    const errEmitted = wrapper.emitted('error')
    expect(errEmitted).toBeTruthy()
    expect(String(errEmitted![0]?.[0])).toMatch(/Permission denied/)
  })

  it('shows error state when transcription API fails', async () => {
    apiTranscribeMock.mockRejectedValueOnce(new Error('Upstream 502'))

    wrapper = mount(MicButton)
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('error')
  })
})