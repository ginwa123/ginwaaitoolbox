/**
 * useNalarConfig — single source of truth for the Nalar settings UI.
 *
 * Owns the in-memory `NalarConfig` and a deep snapshot taken at load
 * time. `dirty` is a computed that re-runs whenever any tracked field
 * changes; `unsavedCount` is the number of leaf-level changes
 * (shallow count; exact field-level diffs are not required for the
 * dirty pill).
 *
 * `save()` PUTs the whole config to `/api/config/nalar`. On success
 * the snapshot is refreshed; on failure `dirty` stays true so the
 * save bar keeps showing.
 *
 * `reset()` restores the in-memory config from the snapshot.
 */
import { computed, ref } from 'vue'

import { getNalarConfig, saveNalarConfig, type NalarConfig } from '../api'

export function useNalarConfig() {
  const config = ref<NalarConfig | null>(null)
  const loaded = ref(false)
  // JSON.stringify of config at load time. Empty string means
  // "no snapshot yet" (i.e. dirty is always false before load).
  const snapshot = ref<string>('')
  const saving = ref(false)

  /**
   * Number of leaf-level field changes since load. Counts each
   * primitive change once. Used by NalarSaveBar to show
   * "● N unsaved changes".
   */
  const unsavedCount = computed(() => {
    if (!config.value) return 0
    if (!snapshot.value) return 0
    return countLeafDiffs(snapshot.value, JSON.stringify(config.value))
  })

  const dirty = computed(() => unsavedCount.value > 0)

  /** Re-snapshot the config so future edits compare against it. */
  function takeSnapshot() {
    snapshot.value = config.value ? JSON.stringify(config.value) : ''
  }

  async function load() {
    try {
      const data = await getNalarConfig()
      config.value = data ?? {}
    } catch {
      // localStorage fallback is handled by the orchestrator.
      // Here we just want to ensure config is non-null so
      // downstream refs can rely on it.
      config.value = {}
    }
    loaded.value = true
    takeSnapshot()
  }

  async function save() {
    if (!config.value) return
    saving.value = true
    try {
      await saveNalarConfig(config.value)
      takeSnapshot()
    } finally {
      saving.value = false
    }
  }

  function reset() {
    if (!snapshot.value) return
    try {
      config.value = JSON.parse(snapshot.value)
    } catch {
      // Snapshot was malformed; leave config as-is.
    }
  }

  return {
    config,
    loaded,
    dirty,
    unsavedCount,
    saving,
    load,
    save,
    reset,
  }
}

/**
 * Count primitive field differences between two JSON strings.
 * Used to drive the "N unsaved changes" pill in the save bar.
 *
 * Walks both trees in parallel; for each key present in either
 * object, recurses if both values are objects, else counts a leaf
 * mismatch (different value OR present-in-one-only). Arrays are
 * compared element-by-element. Returns the total count.
 */
function countLeafDiffs(aJson: string, bJson: string): number {
  let a: unknown
  let b: unknown
  try {
    a = JSON.parse(aJson)
    b = JSON.parse(bJson)
  } catch {
    return aJson === bJson ? 0 : 1
  }
  return countDiffs(a, b)
}

function countDiffs(a: unknown, b: unknown): number {
  if (a === b) return 0
  if (a == null || b == null) return 1
  if (typeof a !== 'object' || typeof b !== 'object') return 1
  if (Array.isArray(a) !== Array.isArray(b)) return 1
  if (Array.isArray(a) && Array.isArray(b)) {
    let n = Math.abs(a.length - b.length)
    const len = Math.min(a.length, b.length)
    for (let i = 0; i < len; i++) n += countDiffs(a[i], b[i])
    return n
  }
  const ao = a as Record<string, unknown>
  const bo = b as Record<string, unknown>
  const keys = new Set([...Object.keys(ao), ...Object.keys(bo)])
  let n = 0
  for (const k of keys) n += countDiffs(ao[k], bo[k])
  return n
}
