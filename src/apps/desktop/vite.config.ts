import { fileURLToPath, URL } from 'node:url'
import type { Buffer } from 'node:buffer'

import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import vueDevTools from 'vite-plugin-vue-devtools'
import tailwindcss from '@tailwindcss/vite'

// https://vite.dev/config/
// Allow overriding the backend proxy target via VITE_API_PROXY_TARGET.
// Default is the dev nalar on :8081 (for `pnpm dev` / `bun run dev`).
// Tests set this to the harness's chosen port (e.g. 8080 or 8082) so the
// dev server points at a fixture against an isolated tmpdir HOME.
// See tests/functional_ui/README.md for the full test harness story.
const apiProxyTarget = process.env.VITE_API_PROXY_TARGET ?? 'http://localhost:8081'

export default defineConfig({
  plugins: [
    vue(),
    vueDevTools(),
    tailwindcss(),
  ],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url))
    },
  },
  optimizeDeps: {
    include: ['monaco-editor']
  },
  server: {
    proxy: {
      '/api': {
        target: apiProxyTarget, // Override-able via VITE_API_PROXY_TARGET env var
        changeOrigin: true,
        // We take over writing the downstream response ourselves so
        // http-proxy does not buffer the upstream SSE body. The
        // previous version set `x-no-proxy-buffering` (a CloudFront-
        // specific header) inside the `configure` callback, which
        // http-proxy ignores — that's why SSE events arrived in
        // bursts instead of real-time, and the browser DevTools
        // showed ERR_INCOMPLETE_CHUNKED_ENCODING on disconnect.
        selfHandleResponse: true,
        configure: (proxy) => {
          proxy.on('proxyRes', (proxyRes, _req, res) => {
            // Mirror upstream status / headers that matter for SSE.
            // Do NOT touch Transfer-Encoding: the upstream (Zig) now
            // sends chunked-encoded frames and we want to forward
            // those bytes verbatim.
            res.statusCode = proxyRes.statusCode ?? 200
            for (const [key, value] of Object.entries(proxyRes.headers)) {
              // Skip hop-by-hop headers (per RFC 9110 §7.6.1) — these
              // are managed by the HTTP stack, not forwarded.
              const lower = key.toLowerCase()
              if (
                lower === 'transfer-encoding' ||
                lower === 'connection' ||
                lower === 'keep-alive' ||
                lower === 'upgrade'
              ) {
                continue
              }
              res.setHeader(key, value as string | string[])
            }
            // Set the de-facto "don't buffer me" header for any
            // downstream intermediary that respects it (nginx, ALB,
            // Cloudflare). This is the standard SSE hardening header.
            res.setHeader('X-Accel-Buffering', 'no')

            // Pipe the upstream body to the downstream response
            // without buffering. Each 'data' event from proxyRes is
            // one chunked-encoded frame from the Zig backend; we
            // forward it as-is.
            proxyRes.on('data', (chunk: Buffer) => {
              // res.write returns false if the downstream buffer is
              // full; we do NOT pause proxyRes because http-proxy's
              // backpressure handling for SSE is unreliable. The
              // downstream socket will apply TCP backpressure itself.
              res.write(chunk)
            })
            proxyRes.on('end', () => {
              res.end()
            })
            proxyRes.on('error', (_err: Error) => {
              // Upstream died (e.g. backend restart). End the
              // downstream response so the browser sees a clean
              // chunked-encoding terminator instead of
              // ERR_INCOMPLETE_CHUNKED_ENCODING.
              if (!res.writableEnded) {
                res.end()
              }
            })
          })
        },
        // Increase timeouts for long-running SSE streams
        timeout: 300_000, // 5 minutes; matches the previous value
      },
    },
  },
})
