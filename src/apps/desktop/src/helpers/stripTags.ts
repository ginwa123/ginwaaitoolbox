/**
 * Strip thinking tags and extract content from special wrappers.
 * This should be used at the display layer (Vue), NOT in API responses.
 */
export function stripThinkingTags(content: string | undefined): string {
  if (!content) return "";
  let result = content.trim();

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