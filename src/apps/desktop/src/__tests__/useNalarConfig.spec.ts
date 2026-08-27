/**
 * Unit tests for the `useNalarConfig` composable. Mocks the
 * `getNalarConfig` and `saveNalarConfig` API functions (NOT
 * `global.fetch`) so we can assert the composable's load / save /
 * reset / dirty behavior in isolation.
 */
import { nextTick } from 'vue'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import * as api from '../api'
import { useNalarConfig } from '../composables/useNalarConfig'

// Mock the whole `../api` module so we control the return values
// without hitting the network.
vi.mock('../api', () => ({
  getNalarConfig: vi.fn(),
  saveNalarConfig: vi.fn(),
  deleteProfile: vi.fn(),
}))

const mockGet = api.getNalarConfig as unknown as ReturnType<typeof vi.fn>
const mockSave = api.saveNalarConfig as unknown as ReturnType<typeof vi.fn>

describe('useNalarConfig', () => {
  beforeEach(() => {
    mockGet.mockReset()
    mockSave.mockReset()
  })

  it('starts with dirty=false and a null config', () => {
    const { config, dirty, loaded } = useNalarConfig()
    expect(config.value).toBeNull()
    expect(dirty.value).toBe(false)
    expect(loaded.value).toBe(false)
  })

  it('loads from the API and sets loaded=true', async () => {
    mockGet.mockResolvedValueOnce({
      active_profile: 'work',
      profiles: { work: { model: 'gpt-4o-mini' } },
    })
    const { config, dirty, loaded, load } = useNalarConfig()
    await load()
    expect(loaded.value).toBe(true)
    expect(config.value?.active_profile).toBe('work')
    expect(dirty.value).toBe(false)
  })

  it('flips dirty=true when a field is edited after load', async () => {
    mockGet.mockResolvedValueOnce({ active_profile: 'work' })
    const { config, dirty, load } = useNalarConfig()
    await load()
    expect(dirty.value).toBe(false)
    if (config.value) config.value.active_profile = 'home'
    await nextTick()
    expect(dirty.value).toBe(true)
  })

  it('counts unsaved field changes in unsavedCount', async () => {
    mockGet.mockResolvedValueOnce({
      active_profile: 'work',
      retry_delay_ms: 0,
    })
    const { config, unsavedCount, load } = useNalarConfig()
    await load()
    if (config.value) {
      config.value.active_profile = 'home' // 1 change
      config.value.retry_delay_ms = 5000   // 2 changes
    }
    await nextTick()
    expect(unsavedCount.value).toBeGreaterThanOrEqual(2)
  })

  it('save() calls saveNalarConfig and clears dirty on success', async () => {
    mockGet.mockResolvedValueOnce({ active_profile: 'work' })
    mockSave.mockResolvedValueOnce({ success: true })
    const { config, dirty, load, save } = useNalarConfig()
    await load()
    if (config.value) config.value.active_profile = 'home'
    await nextTick()
    expect(dirty.value).toBe(true)
    await save()
    expect(mockSave).toHaveBeenCalledWith(expect.objectContaining({ active_profile: 'home' }))
    expect(dirty.value).toBe(false)
  })

  it('save() throws and keeps dirty=true on API failure', async () => {
    mockGet.mockResolvedValueOnce({ active_profile: 'work' })
    mockSave.mockRejectedValueOnce(new Error('HTTP 500'))
    const { config, dirty, load, save } = useNalarConfig()
    await load()
    if (config.value) config.value.active_profile = 'home'
    await nextTick()
    await expect(save()).rejects.toThrow('HTTP 500')
    expect(dirty.value).toBe(true)
  })

  it('reset() restores the snapshot and clears dirty', async () => {
    mockGet.mockResolvedValueOnce({ active_profile: 'work' })
    const { config, dirty, load, reset } = useNalarConfig()
    await load()
    if (config.value) config.value.active_profile = 'home'
    await nextTick()
    expect(dirty.value).toBe(true)
    reset()
    expect(config.value?.active_profile).toBe('work')
    expect(dirty.value).toBe(false)
  })
})
