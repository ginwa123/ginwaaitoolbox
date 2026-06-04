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

  // Only <think> exists, keep original content
  if (hasThink && !hasPlain && !hasMarkdown) {
    return str
  }

  let result = str

  // Remove think block only when another content tag exists
  if (hasThink && (hasPlain || hasMarkdown)) {
    result = result.replace(/<think>[\s\S]*?<\/think>/gi, '')
  }

  // Unwrap plain tags
  result = result.replace(/<plain>\s*/gi, '').replace(/\s*<\/plain>/gi, '')

  // Unwrap markdown tags
  result = result.replace(/<markdown>\s*/gi, '').replace(/\s*<\/markdown>/gi, '')

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
