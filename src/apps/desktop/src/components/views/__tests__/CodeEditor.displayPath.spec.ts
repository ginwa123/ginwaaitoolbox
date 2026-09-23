/**
 * Regression test for the sidebar-right open-file doubled path
 * (task fix-open-file). The explorer passes an ABSOLUTE file.path
 * (backend listDirectory joins dir_path + name), and CodeEditor's
 * footer used to render `${cwd}/${filePath}` unconditionally:
 *   /home/u/work//home/u/work/migration/README.md
 * The footer must show the absolute path as-is and only join when
 * filePath is relative. Mounting CodeEditor pulls Monaco, so this
 * spec asserts the structural contract on source instead.
 */
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, it, expect } from 'vitest'

const codeEditorPath = resolve(__dirname, '..', '..', 'views', 'CodeEditor.vue')

function loadSource(): string {
  return readFileSync(codeEditorPath, 'utf-8')
}

describe('CodeEditor.vue — footer displayPath', () => {
  it('does not unconditionally join cwd + filePath', () => {
    const src = loadSource()
    expect(src).not.toMatch(/cwd \? `\$\{cwd\}\/\$\{filePath\}`/)
  })

  it('defines displayPath that guards absolute paths', () => {
    const src = loadSource()
    expect(src).toMatch(/displayPath/)
    expect(src).toMatch(/isAbsolutePath/)
    expect(src).toMatch(/startsWith\('\/'\)/)
  })

  it('footer binds title and text to displayPath', () => {
    const src = loadSource()
    expect(src).toMatch(/:title="displayPath"/)
    expect(src).toMatch(/\{\{\s*displayPath\s*\}\}/)
  })
})
