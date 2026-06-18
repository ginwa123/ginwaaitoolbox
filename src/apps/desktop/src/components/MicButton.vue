<!-- src/apps/desktop/src/components/MicButton.vue -->
<script setup lang="ts">
import { ref } from 'vue'
import { apiTranscribe } from '../api/transcribe'

type MicState = 'idle' | 'recording' | 'processing' | 'error'

const emit = defineEmits<{
  transcribed: [text: string]
  error: [message: string]
}>()

defineProps<{
  disabled?: boolean
}>()

const state = ref<MicState>('idle')
const errorMessage = ref<string>('')
let mediaRecorder: MediaRecorder | null = null
let mediaStream: MediaStream | null = null
let recordedChunks: Blob[] = []

async function ensurePermissions(): Promise<MediaStream> {
  if (!navigator.mediaDevices?.getUserMedia) {
    throw new Error('Microphone API not available in this browser')
  }
  return await navigator.mediaDevices.getUserMedia({ audio: true })
}

async function startRecording() {
  try {
    recordedChunks = []
    errorMessage.value = ''
    mediaStream = await ensurePermissions()
    mediaRecorder = new MediaRecorder(mediaStream)

    mediaRecorder.addEventListener('dataavailable', (ev: Event) => {
      const blob = (ev as BlobEvent).data
      if (blob && blob.size > 0) recordedChunks.push(blob)
    })
    mediaRecorder.addEventListener('stop', () => {
      void finalizeRecording()
    })
    mediaRecorder.addEventListener('error', (ev: Event) => {
      const errEvent = ev as { error?: Error }
      state.value = 'error'
      errorMessage.value = errEvent.error?.message ?? 'Recording error'
      emit('error', errorMessage.value)
      cleanupStream()
    })

    mediaRecorder.start()
    state.value = 'recording'
  } catch (err) {
    state.value = 'error'
    errorMessage.value = err instanceof Error ? err.message : String(err)
    emit('error', errorMessage.value)
    cleanupStream()
  }
}

function stopRecording() {
  if (mediaRecorder && mediaRecorder.state !== 'inactive') {
    mediaRecorder.stop()
  }
}

async function finalizeRecording() {
  // 'stop' fired → transcribe
  state.value = 'processing'
  try {
    const mimeType = mediaRecorder?.mimeType || 'audio/webm'
    const blob = new Blob(recordedChunks, { type: mimeType })
    if (blob.size === 0) {
      throw new Error('No audio recorded')
    }
    const result = await apiTranscribe(blob)
    emit('transcribed', result.text)
    state.value = 'idle'
  } catch (err) {
    state.value = 'error'
    errorMessage.value = err instanceof Error ? err.message : String(err)
    emit('error', errorMessage.value)
  } finally {
    cleanupStream()
  }
}

function cleanupStream() {
  if (mediaStream) {
    mediaStream.getTracks().forEach((t) => t.stop())
    mediaStream = null
  }
  mediaRecorder = null
  recordedChunks = []
}

// ── Gesture handlers (toggle vs hold) ────────────────────────────────────
//
// Two parallel gesture paths are supported on the same button:
//   1. CLICK toggle — a single click on the button (mouse OR touch) starts
//      recording; clicking again stops and transcribes. Used for users who
//      prefer "click once to start, click again to stop".
//   2. HOLD push-to-talk — mousedown/touchstart starts recording, the
//      matching mouseup/touchend stops it and transcribes. Used for users
//      who prefer "press and hold".
//
// `e.preventDefault()` on mousedown suppresses the BROWSER's default
// action (e.g. text selection on a drag) but does NOT prevent the
// synthetic 'click' event that fires after mouseup. The 'click'
// handler still runs; the reason this is safe is the state-machine
// guard at the top of `onClick` and `onMouseDown` — after mousedown
// fired, state is 'recording' and the click is a no-op (the
// `if (state.value === 'idle')` branch doesn't match). `onClick`
// additionally ignores 'processing' and 'error' states. Net effect:
// the synthetic click is absorbed by the state machine, not by
// preventDefault.

function onClick(e: MouseEvent) {
  // The browser still fires a synthetic 'click' after mousedown+mouseup
  // even though we call e.preventDefault() in onMouseDown (which only
  // suppresses the default browser action, not the event itself). The
  // state machine has already advanced past 'idle' by the time this
  // runs, so the guard below makes the click a no-op rather than
  // re-triggering start. This no-op is the second line of defense
  // against any double-trigger logic the browser might add.
  e.preventDefault()
  if (state.value === 'idle') {
    void startRecording()
  } else if (state.value === 'recording') {
    stopRecording()
  }
  // 'processing' and 'error' states ignore clicks — wait for the current
  // operation to finish or for the user to start a new gesture.
}

function onMouseDown(e: MouseEvent) {
  // e.preventDefault() here suppresses the BROWSER's default action
  // (e.g. text selection on a drag) but does NOT prevent the synthetic
  // 'click' event that fires after mouseup. The 'click' handler is a
  // no-op once state has advanced past 'idle' (see onClick), and
  // onMouseUp handles the actual stop transition. So the state
  // machine absorbs the double-trigger, not preventDefault.
  e.preventDefault()
  if (state.value !== 'idle') return
  void startRecording()
}

function onMouseUp(e: MouseEvent) {
  e.preventDefault()
  if (state.value !== 'recording') return
  stopRecording()
}

function onMouseLeave(_e: MouseEvent) {
  // If the user drags out of the button while holding (mousedown held
  // but mouse left the element), treat as mouseup — otherwise the
  // recording would hang until the next click on the document.
  if (state.value === 'recording') {
    stopRecording()
  }
}

function onTouchStart(e: TouchEvent) {
  e.preventDefault()
  if (state.value !== 'idle') return
  void startRecording()
}

function onTouchEnd(e: TouchEvent) {
  e.preventDefault()
  if (state.value !== 'recording') return
  stopRecording()
}
</script>

<template>
  <button
    type="button"
    data-testid="mic-button"
    :data-state="state"
    :disabled="disabled"
    :title="state === 'error' ? errorMessage
      : state === 'recording' ? 'Recording... (release to stop, click again to cancel)'
      : state === 'processing' ? 'Transcribing...'
      : 'Click to talk or hold to record'"
    class="px-3 py-3 rounded-xl text-sm transition-all duration-200 border flex items-center gap-1 relative"
    :style="state === 'recording'
      ? 'background-color: var(--color-orange); border-color: var(--color-orange); color: var(--color-bg); animation: mic-pulse 1.2s ease-in-out infinite;'
      : state === 'processing'
      ? 'background-color: var(--color-violet); border-color: var(--color-violet); color: var(--color-bg);'
      : state === 'error'
      ? 'background-color: var(--semantic-card-bg); border-color: var(--color-orange); color: var(--color-orange);'
      : 'background-color: var(--semantic-card-bg); border-color: var(--color-border); color: var(--semantic-text);'"
    :class="disabled ? 'cursor-not-allowed opacity-50' : 'hover:opacity-90 active:scale-95'"
    @click="onClick"
    @mousedown="onMouseDown"
    @mouseup="onMouseUp"
    @mouseleave="onMouseLeave"
    @touchstart="onTouchStart"
    @touchend="onTouchEnd"
  >
    <!-- Recording: pulsing filled mic -->
    <svg
      v-if="state === 'recording'"
      class="w-5 h-5"
      fill="currentColor"
      viewBox="0 0 24 24"
    >
      <path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.91-3c0 3.24-2.72 5.83-6 5.91V19h2c.55 0 1 .45 1 1s-.45 1-1 1h-4c-.55 0-1-.45-1-1s.45-1 1-1h2v-2.09c-3.28-.08-6-2.67-6-5.91 0-.55.45-1 1-1s1 .45 1 1c0 2.21 1.79 4 4 4s4-1.79 4-4c0-.55.45-1 1-1s.99.45.99 1z" />
    </svg>

    <!-- Processing: spinner -->
    <div
      v-else-if="state === 'processing'"
      class="w-5 h-5 border-2 rounded-full animate-spin"
      style="border-color: var(--color-bg); border-top-color: transparent;"
    ></div>

    <!-- Error: warning triangle -->
    <svg
      v-else-if="state === 'error'"
      class="w-5 h-5"
      fill="currentColor"
      viewBox="0 0 24 24"
    >
      <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z" />
    </svg>

    <!-- Idle: outline mic -->
    <svg
      v-else
      class="w-5 h-5"
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M19 10v2a7 7 0 01-14 0v-2M12 18.5v3.5m-4 0h8M12 1a3 3 0 00-3 3v8a3 3 0 006 0V4a3 3 0 00-3-3z"
      />
    </svg>

    <span v-if="state === 'error'" class="text-xs ml-1 max-w-[120px] truncate">
      {{ errorMessage }}
    </span>
  </button>
</template>

<style scoped>
@keyframes mic-pulse {
  0%, 100% { transform: scale(1); opacity: 1; }
  50% { transform: scale(1.08); opacity: 0.85; }
}
</style>