/**
 * Static source-grep tests for PropertiesPanel.vue.
 *
 * The component renders the right-rail form for editing the selected
 * element's properties: geometry inputs, style inputs, type-specific
 * inputs (text/image), HTML body editor (lazy-loaded Monaco), and a
 * delete button with confirm.
 *
 * Static contract:
 *  - Emits `update`, `htmlChanged`, `delete`.
 *  - Has geometry / style / type-specific / HTML / delete sections.
 *  - The Monaco editor is loaded lazily via dynamic import (the
 *    chunk is split at the import call so the bundle doesn't pay
 *    ~3 MB up-front).
 *  - Falls back to a textarea if Monaco fails to load.
 *  - Has data-testid selectors for E2E tests.
 */
import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

const SOURCE_PATH = path.resolve(__dirname, '../components/PropertiesPanel.vue')
const source = fs.readFileSync(SOURCE_PATH, 'utf-8')

describe('PropertiesPanel.vue static contract', () => {
  it('emits update, htmlChanged, delete', () => {
    expect(source).toContain("update:")
    expect(source).toContain("htmlChanged:")
    expect(source).toContain("delete:")
  })

  it('declares element and readonly props', () => {
    expect(source).toContain("element:")
    expect(source).toContain("readonly:")
  })

  it('renders all 4 section types (geometry, style, type-specific, html)', () => {
    expect(source).toContain("properties-section-geometry")
    expect(source).toContain("properties-section-style")
    expect(source).toContain("properties-section-type")
    expect(source).toContain("properties-section-html")
  })

  it('exposes geometry inputs (x, y, w, h, rotation)', () => {
    expect(source).toContain("properties-input-x")
    expect(source).toContain("properties-input-y")
    expect(source).toContain("properties-input-width")
    expect(source).toContain("properties-input-height")
    expect(source).toContain("properties-input-rotation")
  })

  it('exposes style inputs (fill, stroke, stroke-width, corner-radius, opacity)', () => {
    expect(source).toContain("properties-input-fill")
    expect(source).toContain("properties-input-stroke")
    expect(source).toContain("properties-input-stroke-width")
    expect(source).toContain("properties-input-corner-radius")
    expect(source).toContain("properties-input-opacity")
  })

  it('exposes type-specific inputs (text_content, text_style, image_url)', () => {
    expect(source).toContain("properties-input-text-content")
    expect(source).toContain("properties-input-text-style")
    expect(source).toContain("properties-input-image-url")
  })

  it('lazy-loads Monaco via dynamic import on first expand', () => {
    // The dynamic import call is what defers the Monaco chunk; a
    // future refactor that switches to a top-level static import
    // would lose the bundle-split.
    expect(source).toContain("await import('monaco-editor')")
  })

  it('has the toggle/editor/cancel/save data-testids for the HTML section', () => {
    expect(source).toContain("properties-toggle-html-editor")
    expect(source).toContain("properties-html-editor")
    expect(source).toContain("properties-html-save")
    expect(source).toContain("properties-html-cancel")
  })

  it('has the delete + confirm data-testids', () => {
    expect(source).toContain("properties-delete-button")
    expect(source).toContain("properties-delete-confirm")
    expect(source).toContain("properties-delete-cancel")
  })

  it('renders an empty state when no element is selected', () => {
    expect(source).toContain("properties-panel-empty")
  })

  it('has the top-level properties-panel data-testid', () => {
    expect(source).toContain('data-testid="properties-panel"')
  })
})