/**
 * Type-level tests for the `NalarConfig` interface. These compile-time
 * guards ensure new optional fields stay optional (matching the
 * project's existing convention) so callers that omit the field do
 * not break.
 */
import { describe, expect, it } from 'vitest'
import type { NalarConfig } from '../api'

describe('NalarConfig', () => {
  it('accepts retry_delay_ms as an optional number', () => {
    const cfg: NalarConfig = {
      active_profile: 'work',
      retry_delay_ms: 5000,
    }
    expect(cfg.retry_delay_ms).toBe(5000)
  })

  it('allows retry_delay_ms to be omitted (defaults undefined)', () => {
    const cfg: NalarConfig = { active_profile: 'work' }
    expect(cfg.retry_delay_ms).toBeUndefined()
  })
})