import { describe, it, expect } from 'vitest'
import {
  parseBackgroundCommandOutput,
  isBackgroundCommandOutput,
  backgroundToShellXml,
} from './isBackgroundCommandOutput'

describe('isBackgroundCommandOutput', () => {
  it('parses happy path pid/command/body', () => {
    const content =
      'This is an output from background command (pid 12345, command `sleep 10`):\n' +
      '"""""\n' +
      'hello world\n' +
      '"""""'
    expect(isBackgroundCommandOutput(content)).toBe(true)
    expect(parseBackgroundCommandOutput(content)).toEqual({
      pid: '12345',
      command: 'sleep 10',
      body: 'hello world',
    })
  })

  it('parses body with newlines', () => {
    const content =
      'This is an output from background command (pid 42, command `ls -la`):\n' +
      '"""""\n' +
      'line one\nline two\nline three\n' +
      '"""""'
    const parsed = parseBackgroundCommandOutput(content)
    expect(parsed).not.toBeNull()
    expect(parsed!.pid).toBe('42')
    expect(parsed!.command).toBe('ls -la')
    expect(parsed!.body).toBe('line one\nline two\nline three')
  })

  it('parses empty-output marker body', () => {
    const content =
      'This is an output from background command (pid 7, command `true`):\n' +
      '"""""\n' +
      '(empty output)\n' +
      '"""""'
    const parsed = parseBackgroundCommandOutput(content)
    expect(parsed).not.toBeNull()
    expect(parsed!.pid).toBe('7')
    expect(parsed!.command).toBe('true')
    expect(parsed!.body).toBe('(empty output)')
  })

  it('preserves a body that starts with an exit-like line verbatim', () => {
    const content =
      'This is an output from background command (pid 8, command `make`):\n' +
      '"""""\n' +
      '(exit 0, stdout tail)\nreal output\n' +
      '"""""'
    const parsed = parseBackgroundCommandOutput(content)
    expect(parsed).not.toBeNull()
    expect(parsed!.body).toBe('(exit 0, stdout tail)\nreal output')
  })

  it('returns null for ordinary user text', () => {
    const content = 'hey, can you help me with this bug?'
    expect(isBackgroundCommandOutput(content)).toBe(false)
    expect(parseBackgroundCommandOutput(content)).toBeNull()
  })

  it('returns null for foreground <command> XML', () => {
    const content =
      '<command>echo hi</command><stdout>hi</stdout><stderr></stderr>' +
      '<exit_code>0</exit_code><truncated>false</truncated><timeout>false</timeout>' +
      '<stdout_lines></stdout_lines><stderr_lines></stderr_lines><is_self>false</is_self>'
    expect(isBackgroundCommandOutput(content)).toBe(false)
    expect(parseBackgroundCommandOutput(content)).toBeNull()
  })

  it('returns null when the fence is missing', () => {
    const content =
      'This is an output from background command (pid 99, command `echo hi`): no fence here'
    expect(isBackgroundCommandOutput(content)).toBe(true)
    expect(parseBackgroundCommandOutput(content)).toBeNull()
  })

  it('backgroundToShellXml contains escaped command/stdout tags', () => {
    const xml = backgroundToShellXml({
      pid: '123',
      command: 'echo "a<b>&c"',
      body: "it's <done> & \"dusted\"",
    })
    expect(xml).toContain('<command>echo &quot;a&lt;b&gt;&amp;c&quot;</command>')
    expect(xml).toContain('<stdout>it&apos;s &lt;done&gt; &amp; &quot;dusted&quot;</stdout>')
    expect(xml).toContain('<stderr></stderr>')
    expect(xml).toContain('<truncated>false</truncated>')
    expect(xml).toContain('<is_self>false</is_self>')
  })
})
