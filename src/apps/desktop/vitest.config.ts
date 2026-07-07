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
      //
      // Same treatment for `panzoom` (Chunk 4 of the design-fs-rewrite
      // plan): the package IS installed, but its module body attaches DOM
      // event handlers and reads `getBoundingClientRect()` patterns that
      // don't behave in jsdom. The DesignView is stubbed at mount-time in
      // behavioral tests; static-contract tests just read the source.
      alias: {
        'monaco-editor': fileURLToPath(
          new URL('./src/__tests__/stubs/monaco-editor.ts', import.meta.url),
        ),
        panzoom: fileURLToPath(
          new URL('./src/__tests__/stubs/panzoom.ts', import.meta.url),
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
