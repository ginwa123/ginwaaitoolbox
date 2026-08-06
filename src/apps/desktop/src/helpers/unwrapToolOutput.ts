/**
 * Parsed parts of a standardized tool result envelope.
 * Returned by `unwrapToolOutput` / `tryUnwrapToolOutput`.
 */
export interface UnwrappedToolOutput {
  /** Tool name (e.g. "read_file") */
  name: string
  /** Tool arguments as a raw JSON string (XML-unescaped) */
  parameters: string
  /** Whether the tool succeeded */
  success: boolean
  /** Error message (XML-unescaped), or null on success */
  error: string | null
  /** Inner tool-specific output (XML-unescaped), or null on error */
  data: string | null
}

/**
 * Reverse the XML escaping applied by the backend's `wrapToolOutput`.
 * Mirrors `llm_history.zig xmlEscape` exactly.
 */
function unescapeXml(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&') // MUST be last to avoid double-unescaping
}

/**
 * Find the first `<tag>...</tag>` block and return its inner text.
 * Returns `null` if the tag is not present.
 */
function findTag(haystack: string, tag: string): string | null {
  const openSeq = `<${tag}>`
  const closeSeq = `</${tag}>`
  const openIdx = haystack.indexOf(openSeq)
  if (openIdx === -1) return null
  const valueStart = openIdx + openSeq.length
  const closeIdx = haystack.indexOf(closeSeq, valueStart)
  if (closeIdx === -1) return null
  return haystack.slice(valueStart, closeIdx)
}

/**
 * Public re-export of `findTag` for callers that need to extract a
 * single tag from a `<tool>...</tool>` envelope's inner XML without
 * using the full unwrap path. Used by `previewArgs.ts` (the show_preview
 * parameter extractor that handles both XML and legacy-JSON shapes).
 */
export { findTag as findXmlTag }

/**
 * Parse a `<tool>...</tool>` envelope.
 * Throws on malformed input — use `tryUnwrapToolOutput` for a null fallback.
 *
 * The backend produces this envelope in `tool_registry.wrapToolOutput`.
 * The inner `<data>` field contains the existing tool-specific XML
 * (e.g. `<path>/foo</path><content>hello</content>` for read_file).
 */
export function unwrapToolOutput(content: string): UnwrappedToolOutput {
  if (!content.startsWith('<tool>') || !content.endsWith('</tool>')) {
    throw new Error('MalformedToolEnvelope: missing <tool>...</tool> wrapper')
  }
  const inner = content.slice('<tool>'.length, -'</tool>'.length)

  const nameRaw = findTag(inner, 'name')
  const paramsRaw = findTag(inner, 'parameters')
  const successRaw = findTag(inner, 'success')
  if (nameRaw === null || paramsRaw === null || successRaw === null) {
    throw new Error('MalformedToolEnvelope: missing required field (name|parameters|success)')
  }

  const errRaw = findTag(inner, 'error')
  const dataRaw = findTag(inner, 'data')

  return {
    name: unescapeXml(nameRaw),
    parameters: unescapeXml(paramsRaw),
    success: successRaw.trim() === 'true',
    error: errRaw === null ? null : unescapeXml(errRaw),
    data: dataRaw === null ? null : unescapeXml(dataRaw),
  }
}

/**
 * Like `unwrapToolOutput` but returns `null` instead of throwing.
 * Use this for inputs that may legitimately be unwrapped XML
 * (e.g. legacy tool results that pre-date the envelope).
 */
export function tryUnwrapToolOutput(content: string): UnwrappedToolOutput | null {
  try {
    return unwrapToolOutput(content)
  } catch {
    return null
  }
}
