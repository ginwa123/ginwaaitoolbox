/**
 * Static source-grep tests for DesignElementPreview.vue.
 *
 * The component renders a sandboxed iframe for the element's HTML
 * body. When `editable=true`, the iframe body becomes contenteditable
 * and emits `htmlChanged` on blur.
 *
 * Static contract: the iframe has `sandbox="allow-scripts"` (no
 * allow-same-origin!), the editable flow wires body.contentEditable,
 * and the data-testid selector is set.
 */
import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const SOURCE_PATH = path.resolve(__dirname, '../components/design/DesignElementPreview.vue')
const source = fs.readFileSync(SOURCE_PATH, 'utf-8')

describe('DesignElementPreview.vue static contract', () => {
  it('renders an iframe with sandbox=allow-scripts', () => {
    // `allow-same-origin` would let user-pasted HTML reach the host
    // document; we deliberately restrict to `allow-scripts` only.
    expect(source).toContain('sandbox="allow-scripts"')
  })

  it('binds srcdoc to the html prop', () => {
    // The reactive html prop drives the iframe content.
    expect(source).toContain(":srcdoc")
    expect(source).toContain("html")
  })

  it('emits htmlChanged on iframe blur when editable=true', () => {
    // The blur handler reads body.innerHTML and emits htmlChanged.
    expect(source).toContain("contentEditable")
    expect(source).toContain("htmlChanged")
    expect(source).toContain("innerHTML")
  })

  it('declares the html prop and optional editable prop', () => {
    expect(source).toContain("html:")
    expect(source).toContain("editable:")
  })

  it('has the design-element-preview data-testid', () => {
    expect(source).toContain("design-element-preview")
  })
})