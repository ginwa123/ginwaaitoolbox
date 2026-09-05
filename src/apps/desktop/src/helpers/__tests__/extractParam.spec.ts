import { describe, it, expect } from 'vitest'
import { extractParam } from '../extractParam'

describe('extractParam', () => {
  it('extracts XML tag content', () => {
    expect(extractParam('<command>ls -la</command>', 'command')).toBe('ls -la')
  })

  it('falls back to JSON', () => {
    expect(extractParam('{"command":"ls -la"}', 'command')).toBe('ls -la')
  })

  it('returns null for empty input', () => {
    expect(extractParam('', 'command')).toBeNull()
    expect(extractParam(null, 'command')).toBeNull()
    expect(extractParam(undefined, 'command')).toBeNull()
    expect(extractParam('<command>   </command>', 'command')).toBeNull()
  })

  it('returns null for missing tag', () => {
    expect(extractParam('<command>ls</command>', 'cwd')).toBeNull()
    expect(extractParam('{"command":"ls"}', 'cwd')).toBeNull()
  })
})
