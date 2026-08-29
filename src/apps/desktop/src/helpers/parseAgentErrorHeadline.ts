/**
 * parseAgentErrorHeadline — single source of truth for parsing
 * agentic-loop error/retry diagnostic content into a headline + retry
 * label.
 *
 * Extracted from <AgentErrorCard>'s inline regexes on 2026-08-29 so
 * the same wire format is parsed identically by the ChatView's
 * <AgentErrorCard> and the kanban card's hover tooltip. Two copies
 * of the same regex WILL drift over time — keep them in one place.
 *
 * Wire shapes handled (from saveRetryAttemptMessage / bail diagnostics
 * in workflow.zig's 3 sites: retry-catch, unexpected finish_reason,
 * soft/hard TooManyRetries bails):
 *
 *   [Retry {attempt}/{max}] {error_name} ({source}). Retrying in {delay_ms}ms.
 *   Server said: {server_detail}
 *
 *   [Agent Nalar System error] workflow halted after {n} consecutive retries.
 *   Reason for last retry: {error} (source: {source}).
 *   Server said: {detail}
 *
 * Returns:
 *   - retryLabel: "3/10" or null (absent on bail diagnostics)
 *   - headline:   "StreamInterrupted (callDynamicAgentNew)" or null
 *                 (null only when the input has no parseable content)
 */
export interface ParsedAgentError {
  /** retry label like "3/10" — null when the content is a bail diagnostic (no [Retry N/M] prefix) */
  retryLabel: string | null
  /** "StreamInterrupted (callDynamicAgentNew)" or similar — null only on empty content */
  headline: string | null
}

export function parseAgentErrorHeadline(content: string): ParsedAgentError {
  const retryMatch = content.match(/\[Retry (\d+\/\d+)\]/)
  const retryLabel = retryMatch ? retryMatch[1]! : null
  const reason = content.match(/Reason for last retry:\s*(.+?)\.?\s*$/m)
  if (reason) return { retryLabel, headline: reason[1]!.trim() || null }
  const stripped = content.replace(/\[Retry \d+\/\d+\]\s*/, '')
  const firstLine = stripped.split('\n')[0] ?? stripped
  const m = firstLine.match(/^(.*?)\.\s*(Retrying|$)/)
  return { retryLabel, headline: (m ? m[1]! : firstLine).trim() || null }
}
