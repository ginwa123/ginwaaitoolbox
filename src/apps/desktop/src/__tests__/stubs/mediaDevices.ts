// src/apps/desktop/src/__tests__/stubs/mediaDevices.ts
//
// Inert navigator.mediaDevices stub for jsdom. The real
// `navigator.mediaDevices.getUserMedia(constraints)` returns a
// Promise<MediaStream>. Tests replace this with a programmable
// version via `vi.stubGlobal('navigator', { mediaDevices: ... })`.
//
// This stub exists for two reasons:
//  1. Documentation — shows the API surface that test code mocks.
//  2. A potential future bare-specifier alias target if a component
//     ever imports `mediaDevices` directly (none does today).

export interface MediaStream {
  getTracks(): MediaStreamTrack[]
  getAudioTracks(): MediaStreamTrack[]
}

export interface MediaStreamTrack {
  kind: string
  stop(): void
}

export const mediaDevices = {
  getUserMedia: async (_constraints: MediaStreamConstraints): Promise<MediaStream> => {
    return {
      getTracks: () => [],
      getAudioTracks: () => [],
    }
  },
  enumerateDevices: async (): Promise<MediaDeviceInfo[]> => [],
}

export default { mediaDevices }
