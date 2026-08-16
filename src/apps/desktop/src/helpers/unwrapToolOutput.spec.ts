import { describe, it, expect } from 'vitest'
import { unwrapToolOutput, tryUnwrapToolOutput } from './unwrapToolOutput'

describe('unwrapToolOutput', () => {
  it('parses a success envelope with inner data', () => {
    // Parameters are XML (converted from JSON on the backend), not a JSON string
    const wrapped =
      '<tool><name>read_file</name><parameters><path>/foo</path></parameters><success>true</success><data><path>/foo</path><content>hello</content></data></tool>'
    const result = unwrapToolOutput(wrapped)
    expect(result.name).toBe('read_file')
    expect(result.parameters).toBe('<path>/foo</path>') // un-escaped XML
    expect(result.success).toBe(true)
    expect(result.error).toBeNull()
    expect(result.data).toBe('<path>/foo</path><content>hello</content>') // un-escaped
  })

  it('parses an error envelope', () => {
    const wrapped =
      '<tool><name>read_file</name><parameters></parameters><success>false</success><error>File not found</error></tool>'
    const result = unwrapToolOutput(wrapped)
    expect(result.name).toBe('read_file')
    expect(result.success).toBe(false)
    expect(result.error).toBe('File not found')
    expect(result.data).toBeNull()
  })

  it('throws on malformed envelope', () => {
    expect(() => unwrapToolOutput('<error>something</error>')).toThrow('MalformedToolEnvelope')
    expect(() => unwrapToolOutput('not xml at all')).toThrow('MalformedToolEnvelope')
    expect(() => unwrapToolOutput('<tool><name>foo</name>')).toThrow('MalformedToolEnvelope')
  })

  it('tryUnwrapToolOutput returns null on malformed input', () => {
    expect(tryUnwrapToolOutput('garbage')).toBeNull()
    expect(
      tryUnwrapToolOutput(
        '<tool><name>read_file</name><parameters></parameters><success>true</success><data>ok</data></tool>',
      ),
    ).toEqual({
      name: 'read_file',
      parameters: '',
      success: true,
      error: null,
      data: 'ok',
    })
  })

  it('unescapes XML entities in parameters and data', () => {
    const wrapped =
      '<tool><name>bash</name><parameters><command>echo &lt;hi&gt;</command></parameters><success>true</success><data><stdout>&lt;hi&gt; &amp; &quot;world&quot;</stdout></data></tool>'
    const result = unwrapToolOutput(wrapped)
    expect(result.parameters).toBe('<command>echo <hi></command>')
    expect(result.data).toBe('<stdout><hi> & "world"</stdout>')
  })
})
