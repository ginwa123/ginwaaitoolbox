/**
 * usePreviewDisplayMode — single source of truth for the user-controlled
 * toggle that decides where `show_preview` agent tool outputs render:
 *
 *   - 'side'   → PreviewSidePanel (default — current behaviour)
 *   - 'inline' → rich content renders inside the chat message bubble
 *
 * The toggle lives in the PreviewSidePanel header (when panel is open)
 * and in a small floating "Open preview panel" button in ChatView
 * (when panel is dismissed). The choice persists in localStorage
 * under the key `nalar-preview-display-mode`.
 *
 * SSR-safe: when `localStorage` is undefined (e.g. jsdom test that
 * explicitly removes it, or a non-browser bundler target), the
 * composable falls back to an in-memory ref without throwing.
 *
 * Module-level state: the mode is a SHARED singleton — multiple
 * `usePreviewDisplayMode()` calls in the same page return refs bound
 * to the same backing ref + the same localStorage key. This lets
 * the side panel header and the ChatView restore button stay in
 * sync without prop-drilling.
 *
 * Plan: docs/superpowers/specs/2026-08-06-show-preview-display-mode-design.md
 */

import { computed, ref, type ComputedRef, type Ref } from 'vue'

export type PreviewDisplayMode = 'side' | 'inline'

export const PREVIEW_DISPLAY_MODE_STORAGE_KEY = 'nalar-preview-display-mode'

const VALID_MODES: ReadonlySet<PreviewDisplayMode> = new Set(['side', 'inline'])

function isPreviewDisplayMode(value: unknown): value is PreviewDisplayMode {
  return typeof value === 'string' && VALID_MODES.has(value as PreviewDisplayMode)
}

function loadInitial(): PreviewDisplayMode {
  if (typeof localStorage === 'undefined') return 'side'
  try {
    const raw = localStorage.getItem(PREVIEW_DISPLAY_MODE_STORAGE_KEY)
    if (!isPreviewDisplayMode(raw)) return 'side'
    return raw
  } catch {
    // localStorage may throw in some browsers (SecurityError in
    // cross-origin frames). Fall back to the safe default.
    return 'side'
  }
}

function persist(value: PreviewDisplayMode): void {
  if (typeof localStorage === 'undefined') return
  try {
    localStorage.setItem(PREVIEW_DISPLAY_MODE_STORAGE_KEY, value)
  } catch {
    // Private-mode / quota-exceeded — silently ignore. The in-memory
    // ref still flips, so the session keeps working; the change just
    // doesn't survive reload. Matches the pattern in
    // PreviewSidePanel.vue:39-43 (panel-width persistence).
  }
}

// Module-level singleton. Module state survives across composable
// invocations within the same page session, so every consumer sees
// the same value. Fresh on page reload — backed by localStorage.
const mode: Ref<PreviewDisplayMode> = ref(loadInitial())

export interface UsePreviewDisplayMode {
  /** Reactive current mode. Defaults to 'side' on first call. */
  mode: Ref<PreviewDisplayMode>
  /** Flip the mode (and persist to localStorage if available). */
  setMode: (next: PreviewDisplayMode) => void
  /** Convenience: is the current mode 'inline'? */
  isInline: ComputedRef<boolean>
  /** Convenience: is the current mode 'side'? */
  isSide: ComputedRef<boolean>
}

export function usePreviewDisplayMode(): UsePreviewDisplayMode {
  // Note: we don't return a new ref per call — module-level `mode`
  // is shared across all callers. This is intentional: PreviewSidePanel
  // header and ChatView's restore button both need to see the same
  // state without prop-drilling.
  //
  // Re-sync from localStorage on every call. This is fast (one
  // synchronous key read) and handles the test scenario where one
  // test sets localStorage before another test runs. In production,
  // this is idempotent — the ref is already in sync with the
  // localStorage value (because setMode persists on every flip).
  mode.value = loadInitial()
  return {
    mode,
    setMode,
    isInline: computed(() => mode.value === 'inline'),
    isSide: computed(() => mode.value === 'side'),
  }
}

function setMode(next: PreviewDisplayMode): void {
  if (!isPreviewDisplayMode(next)) return
  mode.value = next
  persist(next)
}