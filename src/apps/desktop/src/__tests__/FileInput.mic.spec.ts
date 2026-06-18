// src/apps/desktop/src/__tests__/FileInput.mic.spec.ts
import { afterEach, beforeEach, describe, expect, it, vi, type MockedFunction } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import MicButton from '../components/MicButton.vue'

// ── Programmable MediaRecorder mock ───────────────────────────────────────

interface MockMediaRecorder {
  start: MockedFunction<() => void>
  stop: MockedFunction<() => void>
  pause: MockedFunction<() => void>
  resume: MockedFunction<() => void>
  state: 'inactive' | 'recording' | 'paused'
  emitDataAvailable: (blob: Blob) => void
  emitStop: () => void
  emitError: (message: string) => void
  dataavailableHandler: ((ev: { data: Blob }) => void) | null
  stopHandler: ((ev: Event) => void) | null
  errorHandler: ((ev: { error?: Error }) => void) | null
}

// Capture the MediaRecorder instance the component creates, so tests
// can drive its event handlers.
let lastRecorder: MockMediaRecorder | null = null

// The class IS the recorder (constructor returns `this` via normal
// `new` semantics) — that way the class's `addEventListener`/`start`/
// `stop`/`state` are accessible on the instance the component holds.
// `lastRecorder` exposes a back-channel for the test's emit*() helpers.
class StubMediaRecorder {
  static readonly inactive = 'inactive'
  static readonly recording = 'recording'
  static readonly paused = 'paused'
  state: 'inactive' | 'recording' | 'paused' = 'inactive'
  private dataavailableHandler: ((ev: { data: Blob }) => void) | null = null
  private stopHandler: ((ev: Event) => void) | null = null
  private errorHandler: ((ev: { error?: Error }) => void) | null = null

  constructor(_stream: MediaStream) {
    const ref: MockMediaRecorder = {
      start: vi.fn(),
      stop: vi.fn(),
      pause: vi.fn(),
      resume: vi.fn(),
      state: 'inactive',
      dataavailableHandler: null,
      stopHandler: null,
      errorHandler: null,
      emitDataAvailable: (blob: Blob) => ref.dataavailableHandler?.({ data: blob }),
      emitStop: () => ref.stopHandler?.(new Event('stop')),
      emitError: (message: string) => ref.errorHandler?.({ error: new Error(message) }),
    }
    ref.start.mockImplementation(() => {
      this.state = 'recording'
    })
    ref.stop.mockImplementation(() => {
      this.state = 'inactive'
    })
    lastRecorder = ref
  }

  start(): void {
    // The mock fn on `lastRecorder` updates `this.state` via the
    // implementation installed in the constructor; calling it here
    // gives the test an assertion surface (`toHaveBeenCalledTimes(1)`)
    // AND keeps the instance's `state` field in sync.
    lastRecorder!.start()
  }
  stop(): void {
    lastRecorder!.stop()
  }
  pause(): void {
    lastRecorder!.pause()
  }
  resume(): void {
    lastRecorder!.resume()
  }
  addEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    const l = listener as (ev: unknown) => void
    if (type === 'dataavailable') {
      lastRecorder!.dataavailableHandler = l as MockMediaRecorder['dataavailableHandler']
    } else if (type === 'stop') {
      lastRecorder!.stopHandler = l as MockMediaRecorder['stopHandler']
    } else if (type === 'error') {
      lastRecorder!.errorHandler = l as MockMediaRecorder['errorHandler']
    }
  }
  removeEventListener(): void {}
  requestData(): void {}
}

vi.stubGlobal('MediaRecorder', StubMediaRecorder as unknown as typeof MediaRecorder)

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
    const passedBlob = apiTranscribeMock.mock.calls[0]?.[0] as Blob
    expect(passedBlob).toBeInstanceOf(Blob)
    expect(passedBlob.size).toBe(audioBlob.size)
    expect(passedBlob.type).toBe(audioBlob.type)

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

// ── FileInput + MicButton integration ─────────────────────────────────────

import FileInput from '../components/FileInput.vue'

describe('FileInput — MicButton integration', () => {
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

  it('renders the MicButton in the input form', () => {
    wrapper = mount(FileInput, { props: { cwd: '/tmp' } })
    expect(wrapper.find('[data-testid="mic-button"]').exists()).toBe(true)
  })

  it('inserts transcribed text at the cursor (cursor at end of existing text)', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'added by mic' })

    wrapper = mount(FileInput, { props: { cwd: '/tmp' } })

    // Type something into the textarea first
    const textarea = wrapper.find('textarea')
    await textarea.setValue('Hello')
    // Place cursor at end (after "Hello")
    const ta = textarea.element as HTMLTextAreaElement
    ta.selectionStart = ta.selectionEnd = 5

    // Trigger full toggle cycle
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    // Text was inserted with a leading space because "Hello" is non-empty.
    // No trailing space because `after` is empty (cursor was at end of text).
    expect((wrapper.vm as unknown as { inputText: string }).inputText).toBe('Hello added by mic')
  })

  it('inserts transcribed text without leading space when textarea is empty', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'first words' })

    wrapper = mount(FileInput, { props: { cwd: '/tmp' } })
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    expect((wrapper.vm as unknown as { inputText: string }).inputText).toBe('first words')
  })

  it('disables the MicButton while LLM is processing', () => {
    wrapper = mount(FileInput, {
      props: { cwd: '/tmp', isLLMProcessing: true },
    })
    const btn = wrapper.find('[data-testid="mic-button"]')
    expect(btn.attributes('disabled')).toBeDefined()
  })

  it('disables the MicButton while isLoading is true', () => {
    wrapper = mount(FileInput, {
      props: { cwd: '/tmp', isLoading: true },
    })
    const btn = wrapper.find('[data-testid="mic-button"]')
    expect(btn.attributes('disabled')).toBeDefined()
  })

  it('works in review mode', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'review note' })

    wrapper = mount(FileInput, {
      props: { cwd: '/tmp', reviewMode: true },
    })

    // MicButton should still be present in review mode
    expect(wrapper.find('[data-testid="mic-button"]').exists()).toBe(true)

    // Toggle + transcribe cycle still works
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    expect((wrapper.vm as unknown as { inputText: string }).inputText).toBe('review note')
  })
})