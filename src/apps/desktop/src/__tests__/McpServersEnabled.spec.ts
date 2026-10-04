import { describe, expect, it } from 'vitest'

import { parseMcpServers, serializeMcpServers } from '../components/pabrik/mcpServers'

describe('MCP server enabled toggle — parse/serialize', () => {
  it('parse hydrates enabled:false on http entries', () => {
    const out = parseMcpServers({
      ctx7: { url: 'https://mcp.context7.com/mcp', enabled: false },
    })
    expect(out).toHaveLength(1)
    expect(out[0]!.enabled).toBe(false)
  })

  it('parse hydrates enabled:false on stdio entries', () => {
    const out = parseMcpServers({
      hello: { command: 'mcp-hello-world', enabled: false },
    })
    expect(out).toHaveLength(1)
    expect(out[0]!.enabled).toBe(false)
  })

  it('parse maps missing enabled to undefined (renders as enabled)', () => {
    const out = parseMcpServers({
      ctx7: { url: 'https://mcp.context7.com/mcp' },
      hello: { command: 'mcp-hello-world' },
    })
    expect(out).toHaveLength(2)
    for (const s of out) expect(s.enabled).toBeUndefined()
  })

  it('serialize omits enabled when true/undefined, emits false explicitly', () => {
    const wire = serializeMcpServers([
      { name: 'on-explicit', transport: 'http', url: 'https://x', headers: [], enabled: true },
      { name: 'on-missing', transport: 'http', url: 'https://y', headers: [] },
      { name: 'off-http', transport: 'http', url: 'https://z', headers: [], enabled: false },
      { name: 'off-stdio', transport: 'stdio', command: 'mcp-hello-world', args: [], env: [], cwd: '', enabled: false },
    ])
    expect(wire).toBeDefined()
    expect(wire!['on-explicit']).not.toHaveProperty('enabled')
    expect(wire!['on-missing']).not.toHaveProperty('enabled')
    expect(wire!['off-http']).toMatchObject({ enabled: false })
    expect(wire!['off-stdio']).toMatchObject({ enabled: false })
  })

  it('round-trips disabled entries symmetrically', () => {
    const wire = serializeMcpServers([
      { name: 'off', transport: 'stdio', command: 'mcp-hello-world', args: [], env: [], cwd: '', enabled: false },
    ])
    const back = parseMcpServers(wire)
    expect(back).toHaveLength(1)
    expect(back[0]!.enabled).toBe(false)
  })
})
