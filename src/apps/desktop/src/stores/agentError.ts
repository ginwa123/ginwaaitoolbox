/**
 * `useAgentErrorStore` — Pinia store backing the persistent per-session
 * "agent error" card slot.
 *
 * Owns the latest agentic-loop diagnostic (retry attempts, TooManyRetries
 * bails, raw upstream error envelopes, …) keyed by session_id, so the
 * error card survives navigation away from a chat and back. The store
 * replaces the previous single-session `agentError = ref<AgentErrorEntry |
 * null>(null)` slot that lived inline in ChatView.vue.
 *
 * Contract:
 *   - bySession: Record<sessionId, AgentErrorEntry | null>
 *                session_id → latest error (null = cleared/no error yet)
 *   - setError(sessionId, content, id?) — replaces `bySession.value`
 *                                         with a fresh object spread
 *                                         (NEVER mutate in place — Vue 3
 *                                         reactivity requires
 *                                         spread-then-assign so
 *                                         consumers re-render)
 *   - clearForSession(sessionId) — idempotent delete; only spreads when
 *                                  the key actually exists (no needless
 *                                  churn for sessions we've never
 *                                  errored on)
 *   - errorFor(sessionId) — returns `bySession.value[sessionId] ?? null`
 *                           (read-only; no spurious key insert)
 *
 * Default `id` fallback: `agent-error-${Date.now()}` matching the existing
 * ChatView.vue:2104 pattern (each new error gets a fresh id so the
 * card's `:key` rebinds and re-mounts cleanly).
 *
 * No backend round-trip — this is a UI-only store, mirroring the
 * `useNavigationStore` composition-API pattern.
 */
import { defineStore } from 'pinia'
import { ref } from 'vue'

export interface AgentErrorEntry {
  id: string
  content: string
}

export const useAgentErrorStore = defineStore('agentError', () => {
  // session_id → latest error entry. null = cleared/no error yet.
  const bySession = ref<Record<string, AgentErrorEntry | null>>({})

  function setError(sessionId: string, content: string, id?: string): void {
    const entry: AgentErrorEntry = {
      id: id ?? `agent-error-${Date.now()}`,
      content,
    }
    // Spread-then-assign (NEVER mutate in place) so Vue 3's reactive
    // proxy treats this as a new object reference and consumers
    // (ChatView's `store.bySession[sessionId]` watcher) re-render.
    bySession.value = { ...bySession.value, [sessionId]: entry }
  }

  function clearForSession(sessionId: string): void {
    // Idempotent: only spread when the key actually exists, so we don't
    // churn the reactive proxy for sessions we've never errored on.
    if (!(sessionId in bySession.value)) return
    const next = { ...bySession.value }
    delete next[sessionId]
    bySession.value = next
  }

  function errorFor(sessionId: string): AgentErrorEntry | null {
    return bySession.value[sessionId] ?? null
  }

  return {
    bySession,
    setError,
    clearForSession,
    errorFor,
  }
})
