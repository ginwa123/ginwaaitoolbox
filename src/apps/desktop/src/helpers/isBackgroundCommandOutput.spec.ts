import { describe, it, expect } from 'vitest'
import {
  parseBackgroundCommandOutput,
  isBackgroundCommandOutput,
  backgroundToShellXml,
} from './isBackgroundCommandOutput'

const xmlEnvelope = (
  pid: string,
  command: string,
  stdout: string,
  truncated = false,
  extra = '',
) =>
  '<background_command>\n' +
  `<pid>${pid}</pid>\n` +
  `<command>${command}</command>\n` +
  `<stdout>${stdout}</stdout>\n` +
  `<truncated>${truncated}</truncated>\n` +
  extra +
  '</background_command>'

describe('isBackgroundCommandOutput', () => {
  it('parses XML happy path pid/command/body', () => {
    const content = xmlEnvelope('12345', 'sleep 10', 'hello world')
    expect(isBackgroundCommandOutput(content)).toBe(true)
    expect(parseBackgroundCommandOutput(content)).toEqual({
      pid: '12345',
      command: 'sleep 10',
      body: 'hello world',
      truncated: false,
      logPath: null,
    })
  })

  it('parses XML body with newlines and truncation fields', () => {
    const content = xmlEnvelope(
      '7',
      'make',
      'line one\nline two',
      true,
      '<total_bytes>99999</total_bytes>\n<log_path>/tmp/full.log</log_path>\n',
    )
    const parsed = parseBackgroundCommandOutput(content)
    expect(parsed).not.toBeNull()
    expect(parsed!.pid).toBe('7')
    expect(parsed!.body).toBe('line one\nline two')
    expect(parsed!.truncated).toBe(true)
    expect(parsed!.logPath).toBe('/tmp/full.log')
  })

  it('unescapes XML entities in command/body', () => {
    const content = xmlEnvelope(
      '9',
      'echo &lt;a&gt;&amp;',
      'it&apos;s &quot;done&quot;',
    )
    const parsed = parseBackgroundCommandOutput(content)
    expect(parsed).not.toBeNull()
    expect(parsed!.command).toBe('echo <a>&')
    expect(parsed!.body).toBe(`it's "done"`)
  })

  it('returns null for XML missing required tags', () => {
    const content = '<background_command>\n<pid>1</pid>\n</background_command>'
    expect(isBackgroundCommandOutput(content)).toBe(true)
    expect(parseBackgroundCommandOutput(content)).toBeNull()
  })

  it('parses legacy prose envelope as fallback', () => {
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
      truncated: false,
      logPath: null,
    })
  })

  it('preserves a legacy body that starts with an exit-like line verbatim', () => {
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

  it('backgroundToShellXml contains escaped command/stdout tags', () => {
    const xml = backgroundToShellXml({
      pid: '123',
      command: 'echo "a<b>&c"',
      body: "it's <done> & \"dusted\"",
      truncated: true,
      logPath: '/tmp/full.log',
    })
    expect(xml).toContain('<command>echo &quot;a&lt;b&gt;&amp;c&quot;</command>')
    expect(xml).toContain('<stdout>it&apos;s &lt;done&gt; &amp; &quot;dusted&quot;</stdout>')
    expect(xml).toContain('<stderr></stderr>')
    expect(xml).toContain('<truncated>true</truncated>')
    expect(xml).toContain('<is_self>false</is_self>')
  })
})
