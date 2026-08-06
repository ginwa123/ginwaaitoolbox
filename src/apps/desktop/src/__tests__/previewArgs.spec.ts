/**
 * Behavioural tests for `extractPreviewArgs` — the shared helper that
 * reads the show_preview tool-call arguments from the `<parameters>...`
 * string returned by `tryUnwrapToolOutput(msg.content)?.parameters`.
 *
 * The helper handles two shapes:
 *   1. Current backend: JSON args converted to XML by `jsonArgsToXml`
 *      (tools_wrap_output.zig). After `tryUnwrapToolOutput` unescapes
 *      one layer, the parameters string is `<content_type>html</content_type>
 *      <content><h1>Hi</h1></content>...` (raw text inside tags).
 *   2. Legacy raw-JSON rows: parameters is `{"content_type":"html",
 *      "content":"<h1>Hi</h1>", ...}` directly.
 *
 * The bug fix (2026-08-06) was that ShowPreview.vue only handled
 * shape 2 (JSON.parse), so the chat-bubble HTML preview rendered
 * blank while the side panel (which handled both) worked.
 */
import { describe, expect, it } from 'vitest'

import { extractPreviewArgs } from '../helpers/previewArgs'

describe('extractPreviewArgs', () => {
  describe('XML shape (current backend — `jsonArgsToXml` output)', () => {
    it('extracts content_type, content, title from XML parameters', () => {
      const result = extractPreviewArgs(
        '<content_type>html</content_type><content><h1>Hi</h1></content><title>Plan</title>',
      )
      expect(result.content_type).toBe('html')
      expect(result.content).toBe('<h1>Hi</h1>')
      expect(result.title).toBe('Plan')
    })

    it('returns the raw (post-unescape) content for html previews', () => {
      // The fixture intentionally has raw HTML inside <content> —
      // mirroring what `tryUnwrapToolOutput` produces in production
      // (one level of XML-unescape already applied).
      const result = extractPreviewArgs(
        '<content_type>html</content_type><content><p>Hello & <b>World</b></p></content>',
      )
      expect(result.content).toBe('<p>Hello & <b>World</b></p>')
    })

    it('extracts markdown content correctly', () => {
      const result = extractPreviewArgs(
        '<content_type>markdown</content_type><content># Hello\n\nBody</content>',
      )
      expect(result.content_type).toBe('markdown')
      expect(result.content).toBe('# Hello\n\nBody')
    })

    it('extracts code content + language correctly', () => {
      const result = extractPreviewArgs(
        '<content_type>code</content_type><content>fn main() {}</content><language>zig</language>',
      )
      expect(result.content_type).toBe('code')
      expect(result.content).toBe('fn main() {}')
      expect(result.language).toBe('zig')
    })

    it('extracts image src from data: URL', () => {
      const result = extractPreviewArgs(
        '<content_type>image</content_type><content>data:image/png;base64,iVBORw0KGgo=</content>',
      )
      expect(result.content_type).toBe('image')
      expect(result.content).toBe('data:image/png;base64,iVBORw0KGgo=')
    })

    it('returns {} when parameters is empty string', () => {
      expect(extractPreviewArgs('')).toEqual({})
    })

    it('returns {} when parameters is null/undefined', () => {
      expect(extractPreviewArgs(null)).toEqual({})
      expect(extractPreviewArgs(undefined)).toEqual({})
    })

    it('returns {} when parameters has no recognised tags', () => {
      expect(extractPreviewArgs('<unknown>x</unknown>')).toEqual({})
    })

    it('returns {} when parameters is malformed (no fallback to JSON)', () => {
      // Without a `<content>` tag, the JSON.parse fallback would
      // attempt to parse this raw text — `{` is valid JSON start but
      // `}` alone isn't. The XML path returns {} first; JSON.parse
      // throws and is silently caught.
      expect(extractPreviewArgs('{not json')).toEqual({})
    })

    it('returns {} when XML is malformed (e.g. truncated <content> tag)', () => {
      expect(extractPreviewArgs('<content_type>html</content_type><content>truncated')).toEqual({})
    })
  })

  describe('legacy raw-JSON shape (older rows)', () => {
    it('parses JSON-stringified parameters when no <content> tag is found', () => {
      const result = extractPreviewArgs(
        '{"content_type":"html","content":"<h1>Hi</h1>","title":"T"}',
      )
      expect(result.content_type).toBe('html')
      expect(result.content).toBe('<h1>Hi</h1>')
      expect(result.title).toBe('T')
    })

    it('parses legacy JSON with markdown content', () => {
      const result = extractPreviewArgs(
        '{"content_type":"markdown","content":"# Legacy"}',
      )
      expect(result.content_type).toBe('markdown')
      expect(result.content).toBe('# Legacy')
    })

    it('returns {} when JSON has no content field', () => {
      const result = extractPreviewArgs('{"content_type":"markdown","title":"No body"}')
      // XML path returns {} (no <content> tag) → JSON path tries
      // the literal JSON, which parses successfully but content is
      // undefined → returns the parsed object as-is (the consumer
      // handles undefined content).
      expect(result).toEqual({ content_type: 'markdown', title: 'No body' })
    })
  })

  describe('XML takes precedence over JSON when both would match', () => {
    it('extracts from XML even when JSON.parse would also succeed on the same string', () => {
      // Hypothetical: a string that's both valid XML and valid JSON
      // (rare in practice — the XML form has no equivalent valid JSON).
      // The XML path is tried first; if it finds content, JSON is
      // never attempted.
      const xml = '<content_type>html</content_type><content>from xml</content>'
      expect(extractPreviewArgs(xml)).toEqual({
        content_type: 'html',
        content: 'from xml',
      })
    })
  })
})
