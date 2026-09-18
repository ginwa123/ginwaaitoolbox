import { describe, it, expect } from 'vitest'
import { unwrapToolOutput, tryUnwrapToolOutput } from './unwrapToolOutput'

const successEnvelope = JSON.stringify({
  tool: 'read_file',
  parameters: { path: '/foo' },
  success: true,
  data: { path: '/foo', content: 'hello' },
  error: null,
  v: 1,
})

const errorEnvelope = JSON.stringify({
  tool: 'read_file',
  parameters: { path: '/missing' },
  success: false,
  data: null,
  error: 'File not found',
  v: 1,
})

describe('unwrapToolOutput', () => {
  it('parses a success envelope with object data', () => {
    const result = unwrapToolOutput(successEnvelope)
    expect(result.name).toBe('read_file')
    expect(result.success).toBe(true)
    expect(result.error).toBeNull()
    expect(result.data).toEqual({ path: '/foo', content: 'hello' })
  })

  it('re-stringifies object parameters so ToolParameters keeps working', () => {
    const result = unwrapToolOutput(successEnvelope)
    expect(JSON.parse(result.parameters)).toEqual({ path: '/foo' })
  })

  it('parses an error envelope with null data and string error', () => {
    const result = unwrapToolOutput(errorEnvelope)
    expect(result.name).toBe('read_file')
    expect(result.success).toBe(false)
    expect(result.data).toBeNull()
    expect(result.error).toBe('File not found')
  })

  it('throws MalformedToolEnvelope on non-JSON input', () => {
    expect(() => unwrapToolOutput('<tool><name>foo</name></tool>')).toThrow('MalformedToolEnvelope')
    expect(() => unwrapToolOutput('not json at all')).toThrow('MalformedToolEnvelope')
    expect(() => unwrapToolOutput('[1,2,3]')).toThrow('MalformedToolEnvelope')
  })

  it('throws MalformedToolEnvelope when required fields are missing', () => {
    expect(() => unwrapToolOutput('{}')).toThrow('MalformedToolEnvelope')
    expect(() => unwrapToolOutput(JSON.stringify({ tool: 'x' }))).toThrow('MalformedToolEnvelope')
    expect(() =>
      unwrapToolOutput(JSON.stringify({ tool: 'x', parameters: {}, success: 'yes' })),
    ).toThrow('MalformedToolEnvelope')
  })

  it('tryUnwrapToolOutput returns null on malformed input', () => {
    expect(tryUnwrapToolOutput('garbage')).toBeNull()
    expect(
      tryUnwrapToolOutput(
        '<tool><name>foo</name><parameters></parameters><success>true</success></tool>',
      ),
    ).toBeNull()
  })

  it('preserves <>& characters inside data without entity decoding', () => {
    const raw = JSON.stringify({
      tool: 'bash',
      parameters: {},
      success: true,
      data: { stdout: '<hi> & "world"' },
      error: null,
      v: 1,
    })
    const result = unwrapToolOutput(raw)
    expect((result.data as { stdout: string }).stdout).toBe('<hi> & "world"')
  })
})
