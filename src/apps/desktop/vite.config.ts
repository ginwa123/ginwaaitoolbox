import { fileURLToPath, URL } from 'node:url'

import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import vueDevTools from 'vite-plugin-vue-devtools'
import tailwindcss from '@tailwindcss/vite'

// https://vite.dev/config/
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
        target: 'http://localhost:8081',  // Point to Zig backend
        changeOrigin: true,
        // SSE requires streaming, disable buffering
        configure: (proxy) => {
          proxy.on('proxyRes', (proxyRes) => {
            if (proxyRes.headers['transfer-encoding'] === 'chunked') {
              proxyRes.headers['x-no-proxy-buffering'] = 'true';
            }
          });
        },
        // Increase timeouts for long-running SSE streams
        timeout: 300000, // 5 minute timeout
      },
    },
  },
})
