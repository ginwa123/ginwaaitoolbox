/**
 * isBackgroundCommandOutput — detect + parse the session-queue envelope the
 * stale-background-process cron inserts when a background `command` finishes.
 *
 * Current wire shape (built by `buildCompletionMessage` in
 * `src/ai_workflow/tui/agentic_loop/background_process.zig`, delivered as a
 * `session_queue_messages` row with role `user`):
 *
 *   <background_command>
 *   <pid>{pid}</pid>
 *   <command>{xml-escaped command}</command>
 *   <stdout>{xml-escaped log tail, or (empty output)}</stdout>
 *   <truncated>false</truncated>
 *   </background_command>
 *
 * (Truncated logs additionally carry `<total_bytes>` + `<log_path>`.)
 *
 * Legacy rows (pre-XML) used a prose envelope — `This is an output from
 * background command (pid …, command \`…\`):` + a 3–5 double-quote fence —
 * and are still parsed via the fallback path so old history renders as a
 * card too.
 *
 * Returns:
 *   - parseBackgroundCommandOutput: `{ pid, command, body, truncated,
 *     logPath }` or `null` for ordinary text / foreground `<command>` XML.
 *   - isBackgroundCommandOutput: `true` iff the content holds a
 *     `<background_command>` block or the legacy prose prefix.
 *   - backgroundToShellXml: re-emits the parsed fields as the 9-tag shell
 *     envelope so the existing shell card renderer displays it unchanged.
 *
 * Pure functions; safe to call inside `computed`.
 */
import {
  extractBool,
  extractTag,
} from '../components/tool_outputs/_shared/toolOutputParser'

export interface ParsedBackgroundCommandOutput {
  /** digits in `<pid>` — e.g. "12345" */
  pid: string
  /** unescaped `<command>` — e.g. "sleep 10" */
  command: string
  /** unescaped `<stdout>` (legacy: text between the fences), trimmed */
  body: string
  /** `<truncated>` (legacy rows: always false) */
  truncated: boolean
  /** unescaped `<log_path>` when truncated, else null */
  logPath: string | null
}

/** Current XML envelope — non-greedy so a body containing tags can't overrun. */
const BACKGROUND_XML_RE = /<background_command>([\s\S]*?)<\/background_command>/

/** Legacy prose prefix emitted by the pre-XML `buildCompletionMessage`. */
const LEGACY_PREFIX = 'This is an output from background command (pid '

/** Legacy fence matcher — tolerates 3, 4, or 5-quote fences. */
const LEGACY_FENCE_RE = /"{3,5}/g

/**
 * Escape the 5 XML metacharacters on serialization.
 * Mirrors `llm_history.zig xmlEscape`: `&` MUST be replaced first,
 * otherwise the later replacements would double-escape their own
 * `&`-prefixed entities.
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
  if (BACKGROUND_XML_RE.test(content)) return true
  return content.startsWith(LEGACY_PREFIX)
}

export function parseBackgroundCommandOutput(content: string): ParsedBackgroundCommandOutput | null {
  const xml = content.match(BACKGROUND_XML_RE)
  if (xml) {
    const inner = xml[1] ?? ''
    const pid = extractTag(inner, 'pid')
    const command = extractTag(inner, 'command')
    const body = extractTag(inner, 'stdout')
    if (pid === null || command === null || body === null) return null
    return {
      pid,
      command,
      body: body.trim(),
      truncated: extractBool(inner, 'truncated'),
      logPath: extractTag(inner, 'log_path'),
    }
  }
  return parseLegacyProse(content)
}

/**
 * Legacy prose fallback: `This is an output from background command
 * (pid {d}, command \`{s}\`):` + first-to-last `"{3,5}` fence slice.
 * The body passes through verbatim (trimmed) — the real envelope never
 * had a header line inside the fences.
 */
function parseLegacyProse(content: string): ParsedBackgroundCommandOutput | null {
  if (!content.startsWith(LEGACY_PREFIX)) return null
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
  const fences = [...content.matchAll(LEGACY_FENCE_RE)]
  if (fences.length < 2) return null
  const first = fences[0]!
  const last = fences[fences.length - 1]!
  const bodyStart = (first.index ?? 0) + first[0].length
  const bodyEnd = last.index ?? content.length
  if (bodyEnd < bodyStart) return null
  return { pid, command, body: content.slice(bodyStart, bodyEnd).trim(), truncated: false, logPath: null }
}

/**
 * Re-emit a parsed background completion as the foreground 9-tag shell XML
 * envelope. `command`/`stdout` are XML-escaped; `stderr` is empty (the
 * background logger merges streams); `truncated` comes from the envelope.
 */
export function backgroundToShellXml(parsed: ParsedBackgroundCommandOutput): string {
  return (
    `<command>${escapeXml(parsed.command)}</command>` +
    `<stdout>${escapeXml(parsed.body)}</stdout>` +
    `<stderr></stderr>` +
    `<exit_code></exit_code>` +
    `<truncated>${parsed.truncated}</truncated>` +
    `<timeout>false</timeout>` +
    `<stdout_lines></stdout_lines>` +
    `<stderr_lines></stderr_lines>` +
    `<is_self>false</is_self>`
  )
}
