// src/apps/desktop/src/__tests__/stubs/mediaRecorder.ts
//
// Inert MediaRecorder stub for jsdom module-loading. The real
// MediaRecorder emits 'dataavailable' and 'stop' events; tests
// replace this class with a programmable version via
// `vi.stubGlobal('MediaRecorder', MockMediaRecorder)`.
//
// This stub satisfies vite's import-analysis so any component file
// that references `MediaRecorder` (e.g. `new MediaRecorder(stream)`)
// can be module-loaded without crashing. It is NOT used at runtime
// in tests — see the createMockMediaRecorder() helper in the
// FileInput.mic.spec.ts test file (Chunk 4) for the runtime shape.

export class MediaRecorder {
  static readonly inactive = 'inactive'
  static readonly recording = 'recording'
  static readonly paused = 'paused'

  readonly stream: MediaStream
  state: string = MediaRecorder.inactive
  ondataavailable: ((ev: BlobEvent) => void) | null = null
  onstop: ((ev: Event) => void) | null = null
  onerror: ((ev: Event) => void) | null = null
  onstart: ((ev: Event) => void) | null = null

  constructor(stream: MediaStream) {
    this.stream = stream
  }

  start(_timeslice?: number): void {
    this.state = MediaRecorder.recording
  }
  stop(): void {
    this.state = MediaRecorder.inactive
  }
  pause(): void {
    this.state = MediaRecorder.paused
  }
  resume(): void {
    this.state = MediaRecorder.recording
  }
  addEventListener(_type: string, _listener: EventListenerOrEventListenerObject): void {}
  removeEventListener(_type: string, _listener: EventListenerOrEventListenerObject): void {}
  requestData(): void {}
}

export default MediaRecorder
