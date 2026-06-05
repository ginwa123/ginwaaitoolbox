import { fileURLToPath } from 'node:url'
import { mergeConfig, defineConfig, configDefaults } from 'vitest/config'
import viteConfig from './vite.config'

export default mergeConfig(
  viteConfig,
  defineConfig({
    resolve: {
      // AppLayout transitively imports CodeEditor.vue, which imports
      // `monaco-editor`. The package is not installed in the test env
      // and is never rendered (it is stubbed at mount-time), so we
      // alias the bare specifier to a tiny stub for module resolution.
      // `vi.mock` runs at the loader level (after import-analysis) and
      // cannot satisfy a bare specifier that vite's resolver has
      // already failed on.
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
