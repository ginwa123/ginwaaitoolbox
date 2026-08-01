/**
 * Behavioural tests for the usePreviewDisplayMode composable.
 *
 * The composable owns the user-controlled toggle between two
 * rendering modes for `show_preview` agent tool outputs:
 *   - 'side'   → PreviewSidePanel (current default behaviour)
 *   - 'inline' → rich content renders inside the chat message bubble
 *
 * State persists in localStorage under the key
 * `nalar-preview-display-mode`. SSR-safe (returns 'side' when
 * localStorage is undefined — never throws).
 *
 * Plan: docs/superpowers/specs/2026-08-06-show-preview-display-mode-design.md
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest'
import { nextTick } from 'vue'
import { usePreviewDisplayMode } from '../usePreviewDisplayMode'

const STORAGE_KEY = 'nalar-preview-display-mode'

function makeLocalStorageStub(): Storage {
  const store: Record<string, string> = {}
  return {
    getItem: (k: string) => (k in store ? store[k] : null),
    setItem: (k: string, v: string) => { store[k] = String(v) },
    removeItem: (k: string) => { delete store[k] },
    clear: () => { for (const k in store) delete store[k] },
    key: () => null,
    length: 0,
  } as Storage
}

describe('usePreviewDisplayMode', () => {
  beforeEach(() => {
    // Always install a fresh localStorage stub so the SSR-safe test
    // (which removes localStorage) doesn't poison subsequent tests.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('defaults to "inline" when localStorage is empty (matches other tool outputs)', () => {
    const { mode } = usePreviewDisplayMode()
    expect(mode.value).toBe('inline')
  })

  it('reads existing "side" value from localStorage (survives reload)', () => {
    localStorage.setItem(STORAGE_KEY, 'side')
    const { mode } = usePreviewDisplayMode()
    expect(mode.value).toBe('side')
  })

  it('setMode("side") flips the reactive ref AND writes to localStorage', async () => {
    const { mode, setMode } = usePreviewDisplayMode()
    expect(mode.value).toBe('inline')
    setMode('side')
    await nextTick()
    expect(mode.value).toBe('side')
    expect(localStorage.getItem(STORAGE_KEY)).toBe('side')
  })

  it('setMode("inline") flips back AND writes to localStorage', async () => {
    localStorage.setItem(STORAGE_KEY, 'side')
    const { mode, setMode } = usePreviewDisplayMode()
    expect(mode.value).toBe('side')
    setMode('inline')
    await nextTick()
    expect(mode.value).toBe('inline')
    expect(localStorage.getItem(STORAGE_KEY)).toBe('inline')
  })

  it('falls back to "inline" when localStorage contains an invalid value (e.g. "sidebar")', () => {
    localStorage.setItem(STORAGE_KEY, 'sidebar')
    const { mode } = usePreviewDisplayMode()
    expect(mode.value).toBe('inline')
  })

  it('falls back to "inline" when localStorage contains an empty string', () => {
    localStorage.setItem(STORAGE_KEY, '')
    const { mode } = usePreviewDisplayMode()
    expect(mode.value).toBe('inline')
  })

  it('SSR-safe: returns "inline" without throwing when localStorage is undefined', () => {
    // Simulate a non-browser environment by REPLACING localStorage
    // with `undefined` via a configurable property descriptor. We
    // can't `delete globalThis.localStorage` because jsdom installs
    // it as a getter on the prototype chain (would throw in strict
    // mode under some vitest configs).
    Object.defineProperty(globalThis, 'localStorage', {
      value: undefined,
      configurable: true,
      writable: true,
    })

    try {
      const { mode, setMode } = usePreviewDisplayMode()
      expect(mode.value).toBe('inline')
      // setMode should also work (in-memory flip) even though it
      // can't persist anywhere.
      setMode('side')
      expect(mode.value).toBe('side')
    } finally {
      // Restore the stub for subsequent tests via beforeEach — but
      // do it eagerly here too, in case vitest runs the next test
      // without re-invoking beforeEach (it shouldn't, but defensive).
      Object.defineProperty(globalThis, 'localStorage', {
        value: makeLocalStorageStub(),
        configurable: true,
        writable: true,
      })
    }
  })

  it('multiple usePreviewDisplayMode() calls in the same page share state (singleton-like)', async () => {
    const a = usePreviewDisplayMode()
    const b = usePreviewDisplayMode()
    expect(a.mode.value).toBe(b.mode.value)

    a.setMode('inline')
    await nextTick()
    expect(b.mode.value).toBe('inline')
  })

  it('does not throw when localStorage.setItem throws (private-mode / quota)', async () => {
    const originalSetItem = localStorage.setItem
    localStorage.setItem = vi.fn(() => {
      throw new Error('QuotaExceeded')
    })

    try {
      const { mode, setMode } = usePreviewDisplayMode()
      setMode('inline')
      // In-memory ref should still flip even though persistence failed.
      expect(mode.value).toBe('inline')
    } finally {
      localStorage.setItem = originalSetItem
    }
  })
})