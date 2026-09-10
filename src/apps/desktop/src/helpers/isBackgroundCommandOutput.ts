/**
 * isBackgroundCommandOutput — detect + parse the session-queue envelope the
 * stale-background-process cron inserts when a background `command` finishes.
 *
 * Wire shape (built by `buildCompletionMessage` in
 * `src/ai_workflow/tui/agentic_loop/background_process.zig`, delivered as a
 * `session_queue_messages` row wrapped in a `"""` envelope):
 *
 *   This is an output from background command (pid {pid}, command `{command}`):
 *   """""
 *   {body}
 *   """""
 *
 * The fence is 5 double-quotes on the backend; the parser tolerates 3, 4, or
 * 5-quote fences (`/"{3,5}/`) so a body that itself contains `"""` cannot
 * break extraction — the body is the text between the FIRST fence and the
 * LAST fence, trimmed. (There is no exit-code header line in the real
 * envelope — `buildCompletionMessage` emits only the prose prefix + fences —
 * so the body is passed through verbatim; never strip a leading line.)
 *
 * Returns:
 *   - parseBackgroundCommandOutput: `{ pid, command, body }` (body trimmed)
 *     or `null` when the content is ordinary text, a foreground `<command>`
 *     XML envelope (wrong prefix), or has no parseable fence.
 *   - isBackgroundCommandOutput: `true` iff `content` starts with the exact
 *     background prefix.
 *   - backgroundToShellXml: re-emits the parsed body as the 9-tag shell
 *     envelope (`command`/`stdout`/`stderr`/`exit_code`/`truncated`/
 *     `timeout`/`stdout_lines`/`stderr_lines`/`is_self`) so the existing
 *     shell card renderer can display it unchanged.
 *
 * Pure functions; safe to call inside `computed`.
 */
export interface ParsedBackgroundCommandOutput {
  /** digits after `(pid ` — e.g. "12345" */
  pid: string
  /** text between the first pair of backticks after the pid — e.g. "sleep 10" */
  command: string
  /** text between the first and last `"{3,5}` fence, minus the `(exit …)` header, trimmed */
  body: string
}

/** Exact prefix emitted by `buildCompletionMessage` — `startsWith` gate. */
const BACKGROUND_PREFIX = 'This is an output from background command (pid '

/** Fence matcher — tolerates 3, 4, or 5-quote fences. */
const FENCE_RE = /"{3,5}/g

/**
 * Escape the 5 XML metacharacters on serialization.
 * Mirrors `llm_history.zig xmlEscape` (the inverse of `unescapeXml` in
 * `toolOutputParser.ts`): `&` MUST be replaced first, otherwise the later
 * replacements would double-escape their own `&`-prefixed entities.
 */
function escapeXml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
}

export function isBackgroundCommandOutput(content: string): boolean {
  return content.startsWith(BACKGROUND_PREFIX)
}

export function parseBackgroundCommandOutput(content: string): ParsedBackgroundCommandOutput | null {
  if (!content.startsWith(BACKGROUND_PREFIX)) return null
  // Real envelope: `(pid {d}, command \`{s}\`)` — the closing paren comes
  // after the command, so only anchor on `(pid {digits}`.
  const pidMatch = content.match(/\(pid (\d+)/)
  if (!pidMatch) return null
  const pid = pidMatch[1]!
  const afterPid = content.slice((pidMatch.index ?? 0) + pidMatch[0].length)
  const openTick = afterPid.indexOf('`')
  if (openTick === -1) return null
  const closeTick = afterPid.indexOf('`', openTick + 1)
  if (closeTick === -1) return null
  const command = afterPid.slice(openTick + 1, closeTick)
  const fences = [...content.matchAll(FENCE_RE)]
  if (fences.length < 2) return null
  const first = fences[0]!
  const last = fences[fences.length - 1]!
  const bodyStart = (first.index ?? 0) + first[0].length
  const bodyEnd = last.index ?? content.length
  if (bodyEnd < bodyStart) return null
  const raw = content.slice(bodyStart, bodyEnd)
  const body = raw.trim()
  return { pid, command, body }
}

/**
 * Re-emit a parsed background completion as the foreground 9-tag shell XML
 * envelope. `command`/`stdout` are XML-escaped; the remaining tags carry the
 * unknown-as-empty defaults (the queue envelope does not record exit code or
 * line counts).
 */
export function backgroundToShellXml(parsed: ParsedBackgroundCommandOutput): string {
  return (
    `<command>${escapeXml(parsed.command)}</command>` +
    `<stdout>${escapeXml(parsed.body)}</stdout>` +
    `<stderr></stderr>` +
    `<exit_code></exit_code>` +
    `<truncated>false</truncated>` +
    `<timeout>false</timeout>` +
    `<stdout_lines></stdout_lines>` +
    `<stderr_lines></stderr_lines>` +
    `<is_self>false</is_self>`
  )
}
