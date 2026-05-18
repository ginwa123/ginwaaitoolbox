/**
 * Strip thinking tags and extract content from special wrappers.
 * This should be used at the display layer (Vue), NOT in API responses.
 */
export function stripThinkingTags(content: string | undefined): string {
  if (!content) return "";
  // Coerce to string to handle numbers, objects, etc. passed at runtime
  const str = String(content);
  let result = str.trim();

  // Remove <think>... blocks
  result = result.replace(/<think>[\s\S]*?<\/think>/gi, "");

  // Remove <plain>...</plain> tags and extract inner content
  result = result.replace(/<plain>\s*/g, "").replace(/\s*<\/plain>/g, "");

  // Remove <markdown>...</markdown> wrapper but KEEP the inner content
  result = result
    .replace(/<markdown>\s*/gi, "")
    .replace(/\s*<\/markdown>/gi, "");

  return result.trim();
}

export function getThinkingTags(content: string): string {
  if (!content) return "";

  // Extract content from <think>... blocks
  const matches = content.match(/<think>([\s\S]*?)<\/think>/gi);
  if (!matches) return "";

  // Extract inner content and join
  return matches
    .map(match => {
      // Strip the tags, keep inner content
      return match.replace(/<\/?think(ing)?>/gi, "").trim();
    })
    .filter(Boolean)
    .join("\n\n");
}

export function isThinkingTags(content: string): boolean {
  if (!content) return false;
  const trimmed = content.trim();

  // Check if content is ONLY <think>... blocks with no other content
  const withoutThinking = trimmed.replace(/<think>[\s\S]*?<\/think>/gi, "").trim();

  // If removing thinking blocks leaves nothing meaningful, it's thinking-only
  // Whitespace or empty string after stripping means content was only thinking tags
  return withoutThinking === "";
}

