/**
 * Regression test for the Linux 99% CPU bug (task_1787683960703_0,
 * 2026-08-25). Static `import * as monaco from 'monaco-editor'` at the
 * top of CodeEditor.vue was forcing Vite to pre-bundle all 30+ Monaco
 * language worker bundles (~96 MB across 64 cached blobs) into the
 * main chunk. On Linux+WebKitGTK those cached blobs were re-parsed on
 * every app start, pinning one CPU core at 80–100% until the parse
 * finished (~10–30 s). macOS+WKWebView uses memory-mapped cache and a
 * faster JS engine, so the same workload was invisible.
 *
 * The fix is structural: the monaco-editor module MUST be loaded via
 * `import()` inside `onMounted` (i.e. only when a CodeEditor instance
 * is actually mounted), and MUST NOT appear as a top-level `import`
 * statement in CodeEditor.vue. This way:
 *
 *   - Vite's optimizer cannot pre-bundle monaco-editor into the entry.
 *   - Until a user opens a file in CodeEditor, the browser never
 *     downloads any monaco-editor chunk.
 *   - WebKitGTK's disk cache never accumulates the 96 MB of Monaco
 *     language workers on a "just opened the chat app" session.
 *
 * We test the contract at two levels:
 *
 *   1. Static — grep the source file for a top-level
 *      `import * as monaco from 'monaco-editor'` (or any other named
 *      monaco-editor import at module scope). Must NOT match. This is
 *      the line that broke the build before; if a future refactor
 *      re-introduces it, this test fails closed.
 *
 *   2. Dynamic — the source must contain a `await import('monaco-editor')`
 *      inside the onMounted block. This is the replacement call site.
 */
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, it, expect } from 'vitest'

// Resolve CodeEditor.vue from the test file's location so this spec is
// location-independent (works no matter where vitest's root ends up).
const codeEditorPath = resolve(
  __dirname,
  '..',
  '..',
  'views',
  'CodeEditor.vue',
)

function loadSource(): string {
  return readFileSync(codeEditorPath, 'utf-8')
}

// Strip the contents of <!-- comments --> and /* ... */ block comments
// so a commented-out `import * as monaco` doesn't trip the static check.
// Naive but sufficient — CodeEditor.vue doesn't have nested comment
// constructs inside comments.
function stripComments(src: string): string {
  return src
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    // Drop // line comments but ONLY at the start of a line so that
    // URLs (e.g. https://…) inside string literals are untouched.
    .replace(/^\s*\/\/.*$/gm, '')
}

// Top-level <script setup> = the part of the file from the opening
// `<script setup lang="ts">` tag through the matching `</script>`.
// Everything before/after is template/style/comments and is not where
// static imports live.
function extractScriptSetup(src: string): string {
  const start = src.indexOf('<script setup')
  const end = start === -1 ? -1 : src.indexOf('</script>', start)
  if (start === -1 || end === -1) {
    throw new Error('CodeEditor.vue has no <script setup> block')
  }
  return src.slice(start, end)
}

// Replace every `{ ... }` body block in `src` with a placeholder.
// Skips braces inside strings and template literals. Returns the
// stripped source. Used to elide function bodies before grepping for
// `monaco.*` tokens at script scope.
function stripBodies(src: string): string {
  let out = ''
  let i = 0
  while (i < src.length) {
    const ch = src[i]
    // Skip string literals — braces inside don't open a body.
    if (ch === '"' || ch === "'" || ch === '`') {
      const quote = ch
      out += ch
      i++
      while (i < src.length && src[i] !== quote) {
        if (src[i] === '\\') {
          out += src[i]
          i++
          if (i < src.length) {
            out += src[i]
            i++
          }
          continue
        }
        out += src[i]
        i++
      }
      if (i < src.length) {
        out += src[i]
        i++
      }
      continue
    }
    if (ch === '{') {
      // Find the matching `}` by depth.
      let depth = 1
      let j = i + 1
      while (j < src.length && depth > 0) {
        const cj = src[j]
        if (cj === '"' || cj === "'" || cj === '`') {
          // Skip the string.
          const q = cj
          j++
          while (j < src.length && src[j] !== q) {
            if (src[j] === '\\') j++
            j++
          }
          j++ // skip closing quote
          continue
        }
        if (cj === '{') depth++
        else if (cj === '}') depth--
        j++
      }
      out += '/* body elided */'
      i = j
      continue
    }
    out += ch
    i++
  }
  return out
}

describe('CodeEditor.vue — lazy monaco-editor load', () => {
  it('does NOT statically import monaco-editor at module top level', () => {
    // Why this is the smoking-gun test: Vite's import-analysis scans the
    // *script* body for bare-specifier imports and emits a chunk for
    // each. A top-level `import * as monaco from 'monaco-editor'`
    // forces the entire monaco-editor tree (including 30+ language
    // worker bundles) into the entry chunk. Removing it is the entire
    // point of this fix.
    const scriptBody = stripComments(extractScriptSetup(loadSource()))

    // Match any monaco-editor import shape:
    //   import * as monaco from 'monaco-editor'
    //   import monaco from 'monaco-editor'
    //   import { editor } from 'monaco-editor'
    //   import 'monaco-editor'                       (side-effect import)
    const staticImport = /^\s*import\s+[^;]*?from\s+['"]monaco-editor['"]/m
    expect(
      scriptBody,
      'CodeEditor.vue must not statically import monaco-editor — ' +
        'use `await import(\'monaco-editor\')` inside onMounted instead. ' +
        'A top-level import forces Vite to ship all 30+ Monaco language ' +
        'worker bundles (~96 MB) into the entry chunk, which WebKitGTK ' +
        'then re-parses on every app start and pins one CPU core at 80–100%.',
    ).not.toMatch(staticImport)

    // Belt-and-braces: also reject a bare side-effect import on its own
    // line. The regex above misses `import 'monaco-editor'` because the
    // `from ...` clause is required.
    expect(scriptBody).not.toMatch(/^\s*import\s+['"]monaco-editor['"]/m)
  })

  it('loads monaco-editor dynamically inside onMounted', () => {
    // The replacement call site: inside onMounted(() => { ... }), the
    // first async work must be a `const monaco = await import('monaco-editor')`.
    // This is what defers the 96 MB bundle download until the user
    // actually opens a file in the editor.
    const src = loadSource()

    // Coarse sanity: the file must still contain an onMounted hook.
    expect(src).toMatch(/onMounted\s*\(/)

    // Fine-grained: find the onMounted block and assert the dynamic
    // import is inside it. We don't try to parse Vue SFCs — we look
    // for the substring between `onMounted(async () => {` (or
    // `onMounted(() => {`) and the matching closing `})` by scanning
    // brace depth from the first `{` after `onMounted`.
    const idx = src.search(/onMounted\s*\(/)
    expect(idx).toBeGreaterThanOrEqual(0)

    // Locate the body opening brace — the `(` of onMounted ends at the
    // matching `)`, then the `=>` arrow introduces a body. We accept
    // either an arrow body `() => { ... }` or a block body `() => {`.
    const bodyOpen = src.indexOf('{', idx)
    expect(bodyOpen).toBeGreaterThan(idx)

    // Walk brace depth to find the matching close.
    let depth = 0
    let bodyEnd = -1
    for (let i = bodyOpen; i < src.length; i++) {
      const ch = src[i]
      if (ch === '{') depth++
      else if (ch === '}') {
        depth--
        if (depth === 0) {
          bodyEnd = i
          break
        }
      }
    }
    expect(bodyEnd).toBeGreaterThan(bodyOpen)
    const onMountedBody = src.slice(bodyOpen, bodyEnd + 1)

    expect(
      onMountedBody,
      'CodeEditor.vue must load monaco-editor via dynamic import inside onMounted. ' +
        'Found onMounted block but no `await import(\'monaco-editor\')` inside it.',
    ).toMatch(/await\s+import\s*\([^)]*['"]monaco-editor['"][^)]*\)/)
  })

  it('does not pre-declare a typed monaco-editor ref at script scope', () => {
    // The old code had `const editor = shallowRef<monaco.editor.IStandaloneCodeEditor | null>(null)`
    // at script scope — the type parameter forces Vite's type-aware
    // tooling (and any reader of the source) to believe monaco-editor
    // is loaded. After the lazy-load refactor the ref should be typed
    // locally or with `unknown`/`any` so the static module top-level
    // has no `monaco.` token referencing the package.
    //
    // We strip the bodies of all function-like declarations
    // (onMounted, watch, handlers) before grepping — references to
    // `monacoNs.value.editor.*` inside any function body are fine.
    // What we're guarding against is a `monaco.editor.X` token in the
    // top-level type annotation / const initializer.
    const scriptBody = stripComments(extractScriptSetup(loadSource()))

    // Strip every function body before grepping. We accept `monaco.*`
    // references inside any function — what we forbid is a `monaco.*`
    // token in a top-level type annotation or const initializer.
    const strippedOfBodies = stripBodies(scriptBody)

    expect(
      strippedOfBodies,
      'Top-level script must not reference monaco.* — type the editor ref with ' +
        'unknown/any, then narrow inside onMounted after the dynamic import resolves.',
    ).not.toMatch(/\bmonaco\./)
  })
})
