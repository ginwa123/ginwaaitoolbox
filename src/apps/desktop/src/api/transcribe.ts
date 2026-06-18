/**
 * Send a recorded audio Blob to the backend for transcription.
 *
 * The backend (POST /api/transcribe) accepts raw audio bytes (NOT
 * JSON, NOT multipart) — it forwards them to the user's configured
 * OpenAI-compatible Whisper endpoint and returns the transcribed
 * text verbatim. We deliberately call fetch() directly (not the
 * shared apiFetch() wrapper) because the wrapper stringifies JSON
 * bodies and adds Content-Type: application/json, both of which
 * would corrupt the raw audio payload.
 *
 * @param audioBlob - Audio recorded via MediaRecorder (audio/webm
 *   by default in Chromium browsers; audio/ogg in Firefox).
 * @returns The transcribed text on success.
 * @throws Error on non-2xx response (e.g. 501 if Whisper is not
 *   configured, 502 if the upstream call failed).
 */
export async function apiTranscribe(audioBlob: Blob): Promise<{ text: string }> {
  const response = await fetch('/api/transcribe', {
    method: 'POST',
    headers: {
      'Content-Type': audioBlob.type || 'audio/webm',
    },
    body: audioBlob,
  })

  if (!response.ok) {
    const body = await response.text().catch(() => '')
    throw new Error(
      `Transcription failed (${response.status}): ${body || response.statusText}`,
    )
  }

  const data = (await response.json()) as { text: string }
  return data
}