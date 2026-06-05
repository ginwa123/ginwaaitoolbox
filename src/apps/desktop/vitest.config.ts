import { fileURLToPath } from 'node:url'
import { mergeConfig, defineConfig, configDefaults } from 'vitest/config'
import viteConfig from './vite.config'

export default mergeConfig(
  viteConfig,
  defineConfig({
    resolve: {
      // AppLayout transitively imports CodeEditor.vue, which imports
      // `monaco-editor`. Although the package IS installed, evaluating its
      // top-level module body (worker setup via `self.MonacoEnvironment`,
      // `getWorker`, etc.) is unsafe in jsdom — the worker URL paths don't
      // resolve. Vite's import-analysis runs at file-transform time, before
      // vi.mock can intercept, so we alias the bare specifier to a tiny stub
      // for module resolution. The real CodeEditor is stubbed at mount-time
      // so the stub's contents do not matter.
      alias: {
        'monaco-editor': fileURLToPath(
          new URL('./src/__tests__/stubs/monaco-editor.ts', import.meta.url),
        ),
      },
    },
    test: {
      environment: 'jsdom',
      exclude: [...configDefaults.exclude, 'e2e/**'],
      root: fileURLToPath(new URL('./', import.meta.url)),
      setupFiles: ['./src/__tests__/setup.ts'],
    },
  }),
)
