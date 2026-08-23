/**
 * Strip thinking tags and extract content from special wrappers.
 * This should be used at the display layer (Vue), NOT in API responses.
 */
export function stripThinkingTags(content: string | undefined): string {
  if (!content) return ''

  const str = String(content).trim()

  const hasThink = /<think>[\s\S]*?<\/think>/i.test(str)
  const hasPlain = /<plain>/i.test(str)
  const hasMarkdown = /<markdown>/i.test(str)
  const hasHtml = /<html>/i.test(str)

  // Only <think> exists, keep original content
  if (hasThink && !hasPlain && !hasMarkdown && !hasHtml) {
    return str
  }

  let result = str

  // Remove think block only when another content tag exists
  if (hasThink && (hasPlain || hasMarkdown || hasHtml)) {
    result = result.replace(/<think>[\s\S]*?<\/think>/gi, '')
  }

  // Unwrap plain tags
  result = result.replace(/<plain>\s*/gi, '').replace(/\s*<\/plain>/gi, '')

  // Unwrap markdown tags
  result = result.replace(/<markdown>\s*/gi, '').replace(/\s*<\/markdown>/gi, '')

  // Unwrap html tags (inner content is rendered as a live sandboxed
  // iframe block by ChatView — see getHtmlTags/isHtmlTags below).
  result = result.replace(/<html>\s*/gi, '').replace(/\s*<\/html>/gi, '')

  return result.trim()
}

export function getThinkingTags(content: string): string {
  if (!content) return ''

  // Extract content from <think>... blocks
  const matches = content.match(/<think>([\s\S]*?)<\/think>/gi)
  if (!matches) return ''

  // Extract inner content and join
  return matches
    .map((match) => {
      // Strip the tags, keep inner content
      return match.replace(/<\/?think(ing)?>/gi, '').trim()
    })
    .filter(Boolean)
    .join('\n\n')
}

export function isThinkingTags(content: string): boolean {
  if (!content) return false
  const trimmed = content.trim()

  // Check if content is ONLY <think>... blocks with no other content
  const withoutThinking = trimmed.replace(/<think>[\s\S]*?<\/think>/gi, '').trim()

  // If removing thinking blocks leaves nothing meaningful, it's thinking-only
  // Whitespace or empty string after stripping means content was only thinking tags
  return withoutThinking === ''
}

/**
 * Extract the inner payload(s) of `<html>...</html>` blocks.
 *
 * The chat UI renders each payload as a live sandboxed-iframe block
 * (see ChatView.vue). Multiple blocks are joined with a blank line,
 * mirroring getThinkingTags. Returns '' when no block is present.
 */
export function getHtmlTags(content: string): string {
  if (!content) return ''

  const matches = content.match(/<html>([\s\S]*?)<\/html>/gi)
  if (!matches) return ''

  return matches
    .map((match) => match.replace(/<\/?html>/gi, '').trim())
    .filter(Boolean)
    .join('\n\n')
}

/**
 * True when the content's only visible payload is `<html>` block(s)
 * (plus optional `<think>` reasoning, which is not visible content).
 */
export function isHtmlTags(content: string): boolean {
  if (!content) return false
  const trimmed = content.trim()

  const withoutHtml = trimmed.replace(/<html>[\s\S]*?<\/html>/gi, '').trim()
  if (withoutHtml === trimmed) return false // no <html> block at all

  // Remaining text must be think-blocks/whitespace only.
  const withoutThink = withoutHtml.replace(/<think>[\s\S]*?<\/think>/gi, '').trim()
  return withoutThink === ''
}
