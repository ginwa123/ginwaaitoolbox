/**
 * Extract the show_preview tool-call arguments from the
 * `<parameters>...</parameters>` string returned by
 * `tryUnwrapToolOutput(msg.content)?.parameters`.
 *
 * The backend produces this string in two shapes depending on the
 * tool path:
 *
 * 1. **Current backend (production)** — `tools_wrap_output.zig` calls
 *    `jsonArgsToXml` to convert the JSON args into XML inside the
 *    `<parameters>...</parameters>` tag. Each JSON key becomes a
 *    child tag:
 *
 *      {"content_type":"html","content":"<h1>Hi</h1>","title":"T"}
 *        → <parameters><content_type>html</content_type>
 *          <content><h1>Hi</h1></content><title>T</title></parameters>
 *
 *    After `tryUnwrapToolOutput` (which XML-unescapes the inner
 *    text), the value passed to consumers is:
 *
 *      <content_type>html</content_type><content><h1>Hi</h1></content><title>T</title>
 *
 *    In this shape, `JSON.parse(...)` THROWS (the `<` at position 0
 *    is not valid JSON start), so consumers MUST use XML extraction.
 *
 * 2. **Legacy raw-JSON rows** — older tool results (pre-PR #55 fix
 *    to the double-wrap in `jsonArgsToXml`) embedded the raw JSON
 *    inside `<parameters>`. These are rare but still in old DB
 *    rows. Consumers should also try `JSON.parse(...)` and fall
 *    back to `{}` on failure.
 *
 * Usage:
 *
 *   const params = getParametersForMessage(msg)  // unwrapped.parameters
 *   const args = extractPreviewArgs(params)
 *   // args.content === "<h1>Hi</h1>" (XML-unescaped from <content>)
 *
 * This helper is the single source of truth used by `<ShowPreview>`
 * (the inline chat-bubble card) and `PreviewContentRenderer`.
 */

import { findXmlTag } from './unwrapToolOutput'

export interface PreviewArgs {
  /** markdown | text | code | image | html */
  content_type?: string
  /** Raw payload — markdown source, plain text, code body, image data: URL, or HTML */
  content?: string
  /** Optional title rendered above the body */
  title?: string
  /** Required for content_type=code (matches the show_preview schema) */
  language?: string
  /** Optional caption rendered below the body */
  caption?: string
}

/**
 * Extract show_preview args from a `<parameters>...</parameters>` string.
 *
 * Tries XML extraction first (current backend behavior), then falls
 * back to JSON parsing for legacy raw-JSON rows. Returns an empty
 * object on malformed input so consumers can always render the header
 * even when the body is missing.
 */
export function extractPreviewArgs(parameters: string | undefined | null): PreviewArgs {
  if (!parameters) return {}

  // 1. XML extraction (current backend — `jsonArgsToXml`).
  //    XML extraction for the current backend shape.
  const fromXml: PreviewArgs = {
    content_type: findXmlTag(parameters, 'content_type') ?? undefined,
    content: findXmlTag(parameters, 'content') ?? undefined,
    title: findXmlTag(parameters, 'title') ?? undefined,
    language: findXmlTag(parameters, 'language') ?? undefined,
    caption: findXmlTag(parameters, 'caption') ?? undefined,
  }
  if (fromXml.content !== undefined) return fromXml

  // 2. Legacy raw-JSON fallback (older rows that embed JSON directly
  //    inside `<parameters>`). `JSON.parse` throws SyntaxError on the
  //    XML form, which is why this is the SECOND attempt.
  try {
    const parsed = JSON.parse(parameters) as PreviewArgs
    if (parsed && typeof parsed === 'object') return parsed
  } catch {
    /* not JSON — fall through to {} */
  }

  return {}
}
