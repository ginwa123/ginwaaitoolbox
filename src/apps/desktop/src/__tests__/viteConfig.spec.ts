// Regression tests for the Vite dev proxy SSE buffering fix.
//
// Why static source-grep instead of importing vite.config.ts?
//   - vite.config.ts is a Vite root source file that pulls in the Vue
//     plugin, the vue-devtools plugin, and Tailwind. Pulling it into a
//     unit test would force the test to also evaluate those plugins,
//     which is unrelated work and brittle to plugin initialization order.
//   - The actual risk we are defending against is "someone reverts
//     selfHandleResponse back to the buffering default, or someone
//     re-introduces the `x-no-proxy-buffering` no-op header". Both are
//     pure source-level properties — they can be checked by reading the
//     file as text and grepping for the relevant strings.
//   - The same static-grep pattern is used by `sidebarSpacing.spec.ts`
//     for the same reason (jsdom doesn't compute layout; we don't need
//     to load the source under test).
//
// When a future task adds a behavioral test for the proxy (e.g. spinning
// up the dev server and asserting that an upstream SSE event reaches
// the downstream socket without buffering), these static checks can be
// supplemented but not replaced — the source-grep is the cheap, fast
// regression guard for the specific bug we just fixed.

import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const VITE_CONFIG_PATH = path.resolve(__dirname, '../../vite.config.ts')

const readSource = (filePath: string): string =>
  fs.readFileSync(filePath, 'utf-8')

describe('vite.config.ts — SSE proxy buffering fix', () => {
  const source = readSource(VITE_CONFIG_PATH)

  it('sets selfHandleResponse: true on the /api proxy entry', () => {
    // selfHandleResponse is the ONLY mechanism that actually disables
    // http-proxy's response buffering. Without it, http-proxy accumulates
    // the upstream body in memory and only flushes on close/timeout, which
    // produces ERR_INCOMPLETE_CHUNKED_ENCODING in the browser when the
    // backend restarts mid-stream.
    if (!/selfHandleResponse:\s*true/.test(source)) {
      throw new Error(
        'vite.config.ts is missing `selfHandleResponse: true` on the /api proxy. ' +
          'http-proxy will buffer the upstream SSE body, causing events to arrive ' +
          'in bursts and ERR_INCOMPLETE_CHUNKED_ENCODING on disconnect.',
      )
    }
  })

  it('registers a `configure` callback on the /api proxy entry', () => {
    // The configure callback is where we wire up the manual response
    // piping. The handler signature must be `(proxy, _req, res) => …` and
    // it must call `proxy.on('proxyRes', …)`.
    if (!/configure:\s*\(/.test(source)) {
      throw new Error(
        'vite.config.ts is missing the `configure` callback on the /api proxy. ' +
          'The manual response piping logic lives inside `configure` — without it, ' +
          'the proxy will fall back to http-proxy\'s default buffered pipe.',
      )
    }
    if (!/proxy\.on\(['"]proxyRes['"]/.test(source)) {
      throw new Error(
        'vite.config.ts configure callback is not subscribed to the `proxyRes` event. ' +
          'The upstream body is delivered through `proxyRes.on(\'data\', …)` — without ' +
          'that subscription, no events reach the downstream response.',
      )
    }
  })

  it('does NOT set the x-no-proxy-buffering header on the response (CloudFront-specific no-op)', () => {
    // The previous version set `x-no-proxy-buffering: true` on the
    // downstream response, believing (incorrectly) that this was the way
    // to disable http-proxy buffering. The header is a CloudFront
    // directive and is silently ignored by http-proxy. Its presence on
    // the response is a strong signal that someone has reverted the fix
    // and re-applied the no-op workaround.
    //
    // We match on the code-level assignment shape `setHeader('x-no-proxy-buffering', …)`
    // (or any equivalent property write) rather than a raw substring
    // search — the string `x-no-proxy-buffering` may legitimately appear
    // in comments that document what the fix replaces, but it must NEVER
    // appear as a code-level header set on the response.
    const codePatterns = [
      /setHeader\(['"]x-no-proxy-buffering['"]/,
      /headers\[['"]x-no-proxy-buffering['"]\]\s*=/,
      /headers\.x-no-proxy-buffering\s*=/,
    ]
    for (const re of codePatterns) {
      if (re.test(source)) {
        throw new Error(
          'vite.config.ts is setting the `x-no-proxy-buffering` header on ' +
            'the response via code (not just in a comment). This is a ' +
            'CloudFront-specific header that http-proxy ignores — it does ' +
            'NOT disable buffering. Remove it; `selfHandleResponse: true` ' +
            'plus the manual `proxyRes.on(\'data\', …)` pipe is the correct fix.',
        )
      }
    }
  })

  it('forwards proxyRes data events to the downstream response (manual pipe)', () => {
    // The whole point of the fix is that we manually copy each chunked-
    // encoding frame from the upstream to the downstream without letting
    // http-proxy buffer it. The handler must subscribe to `data` and
    // call `res.write(chunk)` so bytes flow through immediately.
    if (!/proxyRes\.on\(['"]data['"]/.test(source)) {
      throw new Error(
        'vite.config.ts is missing `proxyRes.on(\'data\', …)`. The fix ' +
          'relies on manually piping the upstream body to the downstream ' +
          'response; without this subscription, no bytes reach the browser.',
      )
    }
    if (!/res\.write\(/.test(source)) {
      throw new Error(
        'vite.config.ts is missing `res.write(…)` inside the data handler. ' +
          'Each chunked-encoded frame from the upstream must be forwarded ' +
          'to the downstream response as soon as it arrives.',
      )
    }
  })

  it('ends the downstream response on upstream end AND on upstream error', () => {
    // Both paths are required:
    //   - `end` for the normal close (server finished the stream).
    //   - `error` for the abnormal close (backend died mid-stream, the
    //     scenario that produced the original ERR_INCOMPLETE_CHUNKED_ENCODING
    //     bug). Without the `error` handler, the downstream socket stays
    //     half-open and the browser sees an incomplete chunked terminator.
    if (!/proxyRes\.on\(['"]end['"]/.test(source)) {
      throw new Error(
        'vite.config.ts is missing `proxyRes.on(\'end\', …)`. The downstream ' +
          'response must be ended when the upstream stream ends so the browser ' +
          'sees a valid chunked-encoding terminator (a zero-length chunk).',
      )
    }
    if (!/proxyRes\.on\(['"]error['"]/.test(source)) {
      throw new Error(
        'vite.config.ts is missing `proxyRes.on(\'error\', …)`. When the upstream ' +
          'dies (e.g. backend restart), the downstream response must be ended ' +
          'explicitly; otherwise the browser reports ERR_INCOMPLETE_CHUNKED_ENCODING.',
      )
    }
  })

  it('sets the X-Accel-Buffering: no header (downstream-intermediary hardening)', () => {
    // X-Accel-Buffering is the de-facto "don't buffer me" header for
    // intermediaries like nginx, AWS ALB, and Cloudflare. Even though
    // Vite's own dev server respects selfHandleResponse, production
    // reverse proxies in front of Vite may not — this header is the
    // belt-and-suspenders hardening that travels with the request.
    if (!/X-Accel-Buffering['"]?\s*,\s*['"]no['"]?/.test(source)) {
      throw new Error(
        'vite.config.ts is missing the `X-Accel-Buffering: no` response ' +
          'header. This header tells downstream intermediaries (nginx, ' +
          'ALB, Cloudflare) not to buffer the SSE response.',
      )
    }
  })

  it('skips RFC 9110 hop-by-hop headers when forwarding upstream response headers', () => {
    // RFC 9110 §7.6.1 lists Transfer-Encoding, Connection, Keep-Alive,
    // and Upgrade as hop-by-hop headers — they are scoped to a single
    // transport-level connection and must NOT be forwarded across proxy
    // hops. Forwarding Transfer-Encoding in particular would corrupt
    // the chunked-encoding framing the upstream carefully produced.
    const required = [
      'transfer-encoding',
      'connection',
      'keep-alive',
      'upgrade',
    ]
    for (const header of required) {
      const re = new RegExp(`['"]${header}['"]`)
      if (!re.test(source)) {
        throw new Error(
          `vite.config.ts proxy header forwarder is missing the hop-by-hop ` +
            `header "${header}" in its skip list (RFC 9110 §7.6.1). Forwarding ` +
            `this header would break chunked-encoding framing.`,
        )
      }
    }
  })
})

// Sanity: the source actually contains a working `defineConfig({...})`
// export. This is a defense against the file being accidentally truncated
// to an empty stub — every other assertion above is content-based, so a
// stub of just `export default defineConfig({})` would still pass them.
describe('vite.config.ts — file integrity', () => {
  it('exports a defineConfig call', () => {
    const source = readSource(VITE_CONFIG_PATH)
    expect(source).toMatch(/export\s+default\s+defineConfig\(/)
  })

  it('references the /api proxy path', () => {
    const source = readSource(VITE_CONFIG_PATH)
    expect(source).toContain("'/api'")
  })
})
