/**
 * Typed parsers for tool-output XML envelopes.
 *
 * Each parser takes the raw `content` string from a tool-message, parses it
 * into a strongly-typed object, and gracefully handles missing tags (returns
 * `null` for missing optional fields, sensible defaults for missing required
 * fields where applicable).
 *
 * The parsers share two helpers:
 *
 *   - `extractTag(content, tag, multiline)` — finds `<tag>…</tag>` and returns
 *     its inner text, XML-unescaped (`&lt;` → `<`, `&gt;` → `>`, `&quot;` → `"`,
 *     `&apos;` → `'`, `&amp;` → `&`). The backend's `toXmlSuccess` /
 *     `xmlError` helpers escape these 5 characters on serialization; without
 *     this unescape, downstream consumers (Vue templates, code-block
 *     renderers) would see literal `&quot;` / `&lt;` instead of `"` / `<`
 *     when the underlying text contained those characters (e.g. a quote
 *     inside a source-code diff). `multiline` defaults to true so the body
 *     can span multiple lines.
 *
 *   - `extractAll(content, tag)` — finds every `<tag>…</tag>` occurrence and
 *     returns an array of inner-text values (XML-unescaped). Useful for
 *     repeated tags like `<skill>…</skill>`.
 *
 * Parsers are pure functions; safe to call inside `computed`. They DO
 * XML-unescape the inner text via `unescapeXml()` — this is necessary
 * because the XML inner content is escaped on the backend (e.g. `"`
 * becomes `&quot;`) and un-escaping here gives the parsed values their
 * intended byte-level fidelity.
 *
 * Conventions:
 *   - Singular boolean fields default to `false` (no <x>true</x> tag = false).
 *   - Optional strings return `null` when missing, not empty string.
 *   - Optional numbers return `null` when missing or unparseable.
 */

/**
 * Decode XML entities produced by the backend's `toXmlSuccess` / `xmlError`.
 * Mirrors `llm_history.zig xmlEscape` (its inverse) exactly. The order matters:
 * `&amp;` MUST be replaced last, otherwise the other replacements would
 * double-decode earlier `&amp;`-prefixed entities (e.g. `&amp;quot;` would
 * incorrectly become `"` instead of `&quot;`).
 *
 * Decodes:
 *   - `&lt;`   → `<`
 *   - `&gt;`   → `>`
 *   - `&quot;` → `"`
 *   - `&apos;` → `'`
 *   - `&amp;`  → `&`   (last)
 */
export function unescapeXml(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')
}

function findTag(content: string, tag: string): string | null {
  const openSeq = `<${tag}>`
  const closeSeq = `</${tag}>`
  const openIdx = content.indexOf(openSeq)
  if (openIdx === -1) return null
  const valueStart = openIdx + openSeq.length
  const closeIdx = content.indexOf(closeSeq, valueStart)
  if (closeIdx === -1) return null
  return content.slice(valueStart, closeIdx)
}

export function extractTag(content: string, tag: string, _multiline = true): string | null {
  // The `_multiline` flag is preserved for back-compat with the original
  // public signature but is currently a no-op (the implementation already
  // supports multiline inner content via `indexOf` matching the first `<tag>`
  // / `</tag>` pair, which works for both single-line and multi-line
  // bodies). Existing call sites pass only `content` and `tag`.
  const raw = findTag(content, tag)
  if (raw === null) return null
  return unescapeXml(raw)
}

/** Trim helper used by every boolean / number parser. */
function trimTag(text: string | null): string {
  return text === null ? '' : text.trim()
}

/** Parse a boolean tag like <success>true</success>. Defaults to `false`. */
export function extractBool(content: string, tag: string, defaultValue = false): boolean {
  const raw = trimTag(extractTag(content, tag))
  if (raw === '') return defaultValue
  return raw === 'true' || raw === '1'
}

/** Parse an integer tag like <exit_code>0</exit_code>. Returns null on parse failure. */
export function extractInt(content: string, tag: string): number | null {
  const raw = trimTag(extractTag(content, tag))
  if (raw === '') return null
  const n = Number(raw)
  return Number.isFinite(n) ? n : null
}

// ─── JSON data-object helpers ──────────────────────────────────────────────
//
// Migrated parsers (read_file, shell family, search, ask_user) take the
// envelope's `data` payload as a parsed object and read fields directly —
// no tag extraction, no entity decoding (JSON needs none). The helpers
// below are lenient by design: a JSON string is parsed, a full envelope
// object (or its JSON string) is unwrapped one level to `.data`, and
// anything else yields safe defaults so a card never throws.

/** Coerce unknown input to a plain record. Unparseable input → {}. */
function asRecord(data: unknown): Record<string, unknown> {
  if (typeof data === 'string') {
    const trimmed = data.trim()
    if (trimmed === '') return {}
    try {
      return asRecord(JSON.parse(trimmed))
    } catch {
      return {}
    }
  }
  if (typeof data === 'object' && data !== null && !Array.isArray(data)) {
    return data as Record<string, unknown>
  }
  return {}
}

/**
 * Unwrap one level when the input is a full tool envelope
 * (`{tool, parameters, success, data, error, v}` or its JSON string)
 * instead of the bare `data` payload. Otherwise coerce to a record.
 */
function unwrapDataRecord(data: unknown): Record<string, unknown> {
  const record = asRecord(data)
  if (
    typeof record.tool === 'string' ||
    (typeof record.success === 'boolean' && 'data' in record)
  ) {
    return asRecord(record.data)
  }
  return record
}

function strField(o: Record<string, unknown>, key: string): string {
  const v = o[key]
  if (typeof v === 'string') return v
  if (v === null || v === undefined) return ''
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return ''
}

function strOrNullField(o: Record<string, unknown>, key: string): string | null {
  const v = o[key]
  if (v === null || v === undefined) return null
  if (typeof v === 'string') return v
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return null
}

function numOrNullField(o: Record<string, unknown>, key: string): number | null {
  const v = o[key]
  if (v === null || v === undefined) return null
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v.trim())
    return Number.isFinite(n) ? n : null
  }
  return null
}

function boolField(o: Record<string, unknown>, key: string, defaultValue = false): boolean {
  const v = o[key]
  if (v === null || v === undefined) return defaultValue
  if (typeof v === 'boolean') return v
  if (typeof v === 'string') {
    const t = v.trim()
    if (t === '') return defaultValue
    return t === 'true' || t === '1'
  }
  if (typeof v === 'number') return v !== 0
  return defaultValue
}

/**
 * Normalized view of whatever a tool card's `content` prop carries:
 * either the bare `data` object (ChatView's success path) or a full
 * envelope JSON string/object (ChatView's error fallback, `m.content`).
 * Empty or unparseable input yields null data with no error (running state).
 */
export interface NormalizedToolContent {
  data: unknown
  error: string | null
  success: boolean
}

export function normalizeToolContent(content: unknown): NormalizedToolContent {
  const empty: NormalizedToolContent = { data: null, error: null, success: true }
  if (content === null || content === undefined) return empty
  if (typeof content === 'string') {
    if (content.trim() === '') return empty
    let parsed: unknown
    try {
      parsed = JSON.parse(content)
    } catch {
      return empty
    }
    return normalizeToolContent(parsed)
  }
  if (typeof content === 'object' && !Array.isArray(content)) {
    const o = content as Record<string, unknown>
    if (typeof o.tool === 'string' || (typeof o.success === 'boolean' && 'data' in o)) {
      const success = o.success !== false
      return {
        data: 'data' in o ? o.data : null,
        error: success ? null : typeof o.error === 'string' ? o.error : 'tool failed',
        success,
      }
    }
    return { data: content, error: null, success: true }
  }
  return empty
}

export interface ParsedTextReplace {
  path: string
  before: string
  after: string
  unified: string
  linesChanged: number
  success: boolean
  error: string | null
}

export function parseTextReplace(content: string): ParsedTextReplace {
  const success = extractBool(content, 'success', true)
  return {
    path: extractTag(content, 'path') ?? '',
    before: extractTag(content, 'before') ?? '',
    after: extractTag(content, 'after') ?? '',
    unified: extractTag(content, 'unified') ?? '',
    linesChanged: extractInt(content, 'lines_changed') ?? 0,
    success,
    error: success ? null : extractTag(content, 'error'),
  }
}

export interface ParsedReadFile {
  path: string
  content: string
  totalLines: number | null
  startLine: number | null
  endLine: number | null
  success: boolean
  error: string | null
}

export function parseReadFile(data: unknown): ParsedReadFile {
  const o = unwrapDataRecord(data)
  const success = boolField(o, 'success', true)
  return {
    path: strField(o, 'path'),
    content: strField(o, 'content'),
    totalLines: numOrNullField(o, 'total_lines'),
    startLine: numOrNullField(o, 'start_line'),
    endLine: numOrNullField(o, 'end_line'),
    success,
    error: success ? null : strOrNullField(o, 'error'),
  }
}

export interface ParsedWriteFile {
  path: string
  success: boolean
  error: string | null
}

export function parseWriteFile(content: string): ParsedWriteFile {
  const success = extractBool(content, 'success', true)
  return {
    path: extractTag(content, 'file_write') ?? '',
    success,
    error: success ? null : extractTag(content, 'error'),
  }
}

export interface ParsedRemoveFile {
  path: string
  deleted: boolean
  recursive: boolean
  success: boolean
  error: string | null
}

export function parseRemoveFile(content: string): ParsedRemoveFile {
  const deleted = extractBool(content, 'deleted', false)
  const recursive = extractBool(content, 'recursive', false)
  return {
    path: extractTag(content, 'path') ?? '',
    deleted,
    recursive,
    success: deleted,
    error: deleted ? null : extractTag(content, 'error'),
  }
}

export interface ParsedEditSkill {
  skillName: string
  edited: boolean
  path: string | null
  success: boolean
  error: string | null
}

export function parseEditSkill(content: string): ParsedEditSkill {
  const edited = extractBool(content, 'edited', false)
  return {
    skillName: extractTag(content, 'name') ?? '',
    edited,
    path: extractTag(content, 'path'),
    success: edited,
    error: edited ? null : extractTag(content, 'error'),
  }
}

export interface ParsedAddSkill {
  skillName: string
  created: boolean
  path: string | null
  success: boolean
  error: string | null
}

export function parseAddSkill(content: string): ParsedAddSkill {
  const created = extractBool(content, 'created', false)
  return {
    skillName: extractTag(content, 'name') ?? '',
    created,
    path: extractTag(content, 'path'),
    success: created,
    error: created ? null : extractTag(content, 'error'),
  }
}

export interface ParsedRemoveSkill {
  skillName: string
  removed: boolean
  path: string | null
  success: boolean
  error: string | null
}

export function parseRemoveSkill(content: string): ParsedRemoveSkill {
  const removed = extractBool(content, 'removed', false)
  return {
    skillName: extractTag(content, 'skill_name') ?? '',
    removed,
    path: extractTag(content, 'path'),
    success: removed,
    error: removed ? null : extractTag(content, 'error'),
  }
}

export interface ParsedSetGitWorktree {
  path: string | null
  branch: string | null
  cleared: boolean
  created: boolean
  success: boolean
  error: string | null
}

export function parseSetGitWorktree(content: string): ParsedSetGitWorktree {
  const cleared = extractBool(content, 'cleared', false)
  const created = extractBool(content, 'created', false)
  return {
    path: extractTag(content, 'path'),
    branch: extractTag(content, 'branch'),
    cleared,
    created,
    success: cleared || created,
    error: cleared || created ? null : extractTag(content, 'error'),
  }
}

export interface ParsedBash {
  command: string | null
  stdout: string
  stderr: string
  exitCode: number | null
  truncated: boolean
  timedOut: boolean
  stdoutLines: number
  stderrLines: number
  isSelf: boolean
}

export function parseBash(data: unknown): ParsedBash {
  const o = unwrapDataRecord(data)
  return {
    command: strOrNullField(o, 'command'),
    stdout: strField(o, 'stdout'),
    stderr: strField(o, 'stderr'),
    exitCode: numOrNullField(o, 'exit_code'),
    truncated: boolField(o, 'truncated', false),
    timedOut: boolField(o, 'timeout', false),
    stdoutLines: numOrNullField(o, 'stdout_lines') ?? 0,
    stderrLines: numOrNullField(o, 'stderr_lines') ?? 0,
    isSelf: boolField(o, 'is_self', false),
  }
}

/**
 * Parse a pwsh (PowerShell Core) tool result. Same JSON `data` shape as bash —
 * per plan D2 + D10 the schema is structurally identical, only the
 * `tool` field that wraps the envelope differs.
 *
 * Functionally a clone of `parseBash` so future divergence (e.g. pwsh adds a
 * `version` field for the PowerShell version that ran) is a one-line change
 * here. Tests in `toolOutputParser.spec.ts` assert `parsePwsh(x) === parseBash(x)`
 * to catch accidental drift.
 */
export function parsePwsh(data: unknown): ParsedBash {
  return parseBash(data)
}

/**
 * Parse a `command` (unified shell) tool result. Same JSON `data` shape as
 * bash — the unified `command` tool reuses the identical 9-field payload
 * (`command`/`stdout`/`stderr`/`exit_code`/`truncated`/`timeout`/
 * `stdout_lines`/`stderr_lines`/`is_self`), only the `tool` wrapper
 * differs. Functionally an alias of `parseBash` so future payload
 * divergence is a one-line change here. Tests assert
 * `parseCommand(x) === parseBash(x)` to catch accidental drift.
 * `parseBash` / `parsePwsh` are intentionally left untouched.
 */
export function parseCommand(data: unknown): ParsedBash {
  return parseBash(data)
}

/**
 * Dispatcher: parse a tool result based on the `toolName` it was registered
 * under. 'bash' / 'pwsh' / 'run_command' (legacy alias) / 'command'
 * (unified shell) all use the same payload. New shells with divergent
 * payload shapes must add their own branch here.
 */
export function parseShell(toolName: string, data: unknown): ParsedBash {
  switch (toolName) {
    case 'bash':
      return parseBash(data)
    case 'pwsh':
      return parsePwsh(data)
    case 'run_command':
      return parseBash(data)
    case 'command':
      return parseCommand(data)
    default:
      return parseBash(data)
  }
}

export interface FileResult {
  path: string
  total: number
  count: number
  matches: Array<{ lineNumber: number; snippet: string }>
}

export interface ParsedSearch {
  pattern: string | null
  path: string | null
  warning: string | null
  error: string | null
  fileResults: FileResult[]
  success: boolean
  returned: number | null
  total: number | null
  truncated: boolean
  truncatedHint: string | null
}

export function parseSearch(data: unknown): ParsedSearch {
  const o = unwrapDataRecord(data)
  const filesRaw = Array.isArray(o.files) ? o.files : []
  const fileResults: FileResult[] = filesRaw.map((f) => {
    const fr = asRecord(f)
    const matchesRaw = Array.isArray(fr.matches) ? fr.matches : []
    return {
      path: strField(fr, 'path'),
      total: numOrNullField(fr, 'total') ?? 0,
      count: numOrNullField(fr, 'count') ?? 0,
      matches: matchesRaw.map((m) => {
        const mr = asRecord(m)
        return {
          lineNumber: numOrNullField(mr, 'line') ?? 0,
          snippet: strField(mr, 'text'),
        }
      }),
    }
  })
  return {
    pattern: strOrNullField(o, 'pattern'),
    path: strOrNullField(o, 'path'),
    warning: strOrNullField(o, 'warning'),
    error: null,
    fileResults,
    success: true,
    returned: numOrNullField(o, 'returned'),
    total: numOrNullField(o, 'total'),
    truncated: boolField(o, 'truncated', false),
    truncatedHint: strOrNullField(o, 'truncated_hint'),
  }
}

export interface ParsedListSkills {
  globalSkills: Array<{ name: string; description: string; path: string }>
  localSkills: Array<{ name: string; description: string; path: string }>
  totalCount: number
}

interface SkillBlock {
  name: string
  description: string
  path: string
}

function parseSkillBlock(content: string): SkillBlock | null {
  const nameMatch = /<name>([\s\S]*?)<\/name>/.exec(content)
  if (!nameMatch) return null
  return {
    name: nameMatch[1] ?? '',
    description: /<description>([\s\S]*?)<\/description>/.exec(content)?.[1] ?? '',
    path: /<path>([\s\S]*?)<\/path>/.exec(content)?.[1] ?? '',
  }
}

export function parseListSkills(content: string): ParsedListSkills {
  const globalSkills: SkillBlock[] = []
  const localSkills: SkillBlock[] = []
  const globalSection = extractTag(content, 'global_skills') ?? ''
  if (globalSection) {
    const blockRegex = /<skill>([\s\S]*?)<\/skill>/g
    let m
    while ((m = blockRegex.exec(globalSection)) !== null) {
      const block = m[1] ? parseSkillBlock(m[1]) : null
      if (block) globalSkills.push(block)
    }
  }
  const localSection = extractTag(content, 'local_skills') ?? ''
  if (localSection) {
    const blockRegex = /<skill>([\s\S]*?)<\/skill>/g
    let m
    while ((m = blockRegex.exec(localSection)) !== null) {
      const block = m[1] ? parseSkillBlock(m[1]) : null
      if (block) localSkills.push(block)
    }
  }
  return {
    globalSkills,
    localSkills,
    totalCount: globalSkills.length + localSkills.length,
  }
}

export interface ParsedKanbanList {
  boardLabel: string | null
  columns: Array<{ id: string; name: string; taskCount: number }>
  error: string | null
  success: boolean
}

export function parseKanbanList(content: string): ParsedKanbanList {
  const error = extractTag(content, 'error')
  if (error !== null) {
    return { boardLabel: null, columns: [], error, success: false }
  }
  const boardLabel = extractTag(content, 'board') ?? extractTag(content, 'name')
  const columns: ParsedKanbanList['columns'] = []
  const colRegex = /<column\s+id="([^"]+)"\s+name="([^"]+)"\s+task_count="(\d+)"\s*\/>/g
  let m
  while ((m = colRegex.exec(content)) !== null) {
    columns.push({
      id: m[1] ?? '',
      name: m[2] ?? '',
      taskCount: parseInt(m[3] ?? '0', 10) || 0,
    })
  }
  return { boardLabel, columns, error: null, success: true }
}

export interface ParsedKanbanMove {
  boardId: string | null
  taskId: string | null
  fromColumnId: string | null
  toColumnId: string | null
  error: string | null
  success: boolean
}

export function parseKanbanMove(content: string): ParsedKanbanMove {
  const error = extractTag(content, 'error')
  if (error !== null) {
    return {
      boardId: null,
      taskId: null,
      fromColumnId: null,
      toColumnId: null,
      error,
      success: false,
    }
  }
  return {
    boardId: extractTag(content, 'board_id'),
    taskId: extractTag(content, 'task_id'),
    fromColumnId: extractTag(content, 'from_column_id'),
    toColumnId: extractTag(content, 'to_column_id'),
    error: null,
    success: true,
  }
}

/** Quick parser for the very common `<metadata>` block used by ReadCompactedMessages. */
export function parseMetadata(content: string): Record<string, string> {
  const result: Record<string, string> = {}
  const meta = /<metadata>([\s\S]*?)<\/metadata>/.exec(content)
  if (!meta || !meta[1]) return result
  const inner = meta[1]
  const tag = /<(\w+)>([\s\S]*?)<\/\1>/g
  let m
  while ((m = tag.exec(inner)) !== null) {
    if (m[1] && m[2] !== undefined) {
      result[m[1]] = m[2].trim()
    }
  }
  return result
}

// ─── generate_image ────────────────────────────────────────────────────────
//
// Parses the XML envelope produced by `execute_generate_image` in
// `src/modules/agent/tools/generate_image.zig`:
//
//   <generate_image>
//     <status>generated</status>
//     <count>1</count>
//     <model>dall-e-3</model>
//     <size>1024x1024</size>
//     <images>
//       <image index="0" path="/cwd/.../img_xxx.png" bytes="12345" mime="image/png" />
//     </images>
//     <revised_prompt>A vibrant watercolor painting of a hat-wearing cat</revised_prompt>
//   </generate_image>
//
// On error:
//   <generate_image><error>HTTP 400: ...</error></generate_image>
//
// Each `<image ... />` is a self-closing tag with FOUR attributes (in
// attribute order: `index`, `path`, `bytes`, `mime`). We pull the
// attributes with a regex because `extractTag` is tag-shape only.

export interface ParsedGenerateImage {
  status: string | null
  count: number | null
  model: string | null
  size: string | null
  /** Absolute filesystem path of each saved image (DALL-E / gpt-image-1 save to disk). */
  images: Array<{ index: number; path: string; bytes: number; mime: string }>
  /** DALL-E 3 / gpt-image-1 only — null for DALL-E 2 (which doesn't rewrite). */
  revisedPrompt: string | null
  /** null on success, populated on <error>...</error>. */
  error: string | null
}

export function parseGenerateImage(content: string): ParsedGenerateImage {
  const error = extractTag(content, 'error')
  if (error !== null) {
    return {
      status: null,
      count: null,
      model: null,
      size: null,
      images: [],
      revisedPrompt: null,
      error,
    }
  }
  const status = extractTag(content, 'status')
  const countRaw = extractTag(content, 'count')
  const count =
    countRaw === null
      ? null
      : Number.isFinite(parseInt(countRaw, 10))
        ? parseInt(countRaw, 10)
        : null
  const model = extractTag(content, 'model')
  const size = extractTag(content, 'size')
  const revisedPrompt = extractTag(content, 'revised_prompt')

  const images: ParsedGenerateImage['images'] = []
  // Self-closing `<image index="N" path="..." bytes="N" mime="..." />`
  // — each attribute is required on the backend. We default missing
  // values to safe fallbacks so a partial envelope (e.g. bytes omitted)
  // still renders without throwing.
  //
  // The attr body can contain `/` (paths like `/cwd/generated_images/...`),
  // so the lazy match must allow `/`. `[\s\S]+?` is the right choice —
  // it matches any character (including newlines, just in case) lazily,
  // stopping at the first `\s*\/>` (optional whitespace + self-close).
  const imgRegex = /<image\s+([\s\S]+?)\s*\/?>/g
  let m
  while ((m = imgRegex.exec(content)) !== null) {
    const attrs = m[1] ?? ''
    const indexRaw = /index="([^"]+)"/.exec(attrs)?.[1] ?? '0'
    const pathRaw = /path="([^"]+)"/.exec(attrs)?.[1] ?? ''
    const bytesRaw = /bytes="([^"]+)"/.exec(attrs)?.[1] ?? '0'
    const mimeRaw = /mime="([^"]+)"/.exec(attrs)?.[1] ?? 'image/png'
    images.push({
      index: Number.isFinite(parseInt(indexRaw, 10)) ? parseInt(indexRaw, 10) : 0,
      path: pathRaw,
      bytes: Number.isFinite(parseInt(bytesRaw, 10)) ? parseInt(bytesRaw, 10) : 0,
      mime: mimeRaw,
    })
  }

  return { status, count, model, size, images, revisedPrompt, error: null }
}

// ─── list_directory ─────────────────────────────────────────────────────────
//
// Parses the XML envelope produced by `execute_list_directory` +
// `toXml` in `src/modules/agent/tools/list_directory.zig`:
//
//   <directory_listing path="/proj" count="3">
//     <directory name="src"   path="/proj/src"      is_symlink="false"/>
//     <file     name="main"   path="/proj/main.zig" is_symlink="false"/>
//   </directory_listing>
//
// The `<directory_listing>` opening tag carries `path="..."` and
// `count="N"` as attributes. Each child is a self-closing
// `<directory .../>` or `<file .../>` tag with three attributes:
// `name`, `path`, `is_symlink`. The sort order is whatever the
// backend produced (directories first, then files, alphabetical) —
// the frontend does NOT re-sort.
//
// On error, the backend wraps with `wrapToolOutput(... success=false, error_msg, "")`,
// leaving the inner `<data>` empty. `ChatView.innerToolData` then
// falls back to the full `<tool>...</tool>` envelope (which still
// carries `<success>false</success><error>...</error>`). The parser
// tolerates both shapes — see the `success=false` branch below.
//
// Note: we use `match(/...<directory_listing.../)` to pick up the
// opening tag's attributes (path + count) and `matchAll(/<(directory|file)
// ...\/>/g)` to pull each child. The attribute body can contain `/`
// (paths like `/proj/src`), so the lazy match must allow `/`.

export interface ParsedListDirectoryEntry {
  name: string
  path: string
  isDirectory: boolean
  isSymlink: boolean
}

export interface ParsedListDirectory {
  /** Absolute path that was listed (from `path="..."` on the wrapper). */
  path: string
  /** Total entry count (from `count="..."` on the wrapper). */
  count: number
  /** Parsed entries in backend sort order (dirs first, then files). */
  entries: ParsedListDirectoryEntry[]
  /** false when the parser finds an `<error>` tag (success path) or wrapper `<success>false</success>`. */
  success: boolean
  /** Error message on failure; null on success. */
  error: string | null
}

export function parseListDirectory(content: string): ParsedListDirectory {
  // Error path: outer <tool> envelope carries <success>false</success>
  // and <error>...</error>. innerToolData falls back to the full envelope
  // when there's no inner <data> (the empty-data error case).
  const errorTag = extractTag(content, 'error')
  if (errorTag !== null) {
    const successFlag = extractBool(content, 'success', true)
    if (!successFlag) {
      return { path: '', count: 0, entries: [], success: false, error: errorTag }
    }
  }

  // Pull `path` and `count` off the <directory_listing ...> opening tag.
  // Note: `<directory_listing` MUST be followed by a space (or `>`) so we
  // don't match `<directory_listing>` (which has no attributes) or
  // future sibling tags that start with the same prefix.
  const pathMatch = /<directory_listing\s[^>]*\bpath="([^"]+)"/.exec(content)
  const dirPath = pathMatch?.[1] ?? ''
  const countMatch = /<directory_listing\s[^>]*\bcount="(\d+)"/.exec(content)
  const count = countMatch?.[1] ? parseInt(countMatch[1], 10) || 0 : 0

  // Pull each <directory .../> and <file .../> child.
  const entries: ParsedListDirectoryEntry[] = []
  // Self-closing tags only — the backend's `toXml` emits `<directory
  // name="..." path="..." is_symlink="..."/>` and never any inner body.
  // The lazy match must allow `/` (paths) inside attributes, so we use
  // `[\s\S]+?` for the attribute body.
  const entryRegex = /<(directory|file)\s+([\s\S]+?)\s*\/?>/g
  let m
  while ((m = entryRegex.exec(content)) !== null) {
    const kind = m[1] ?? ''
    const attrs = m[2] ?? ''
    const nameMatch = /\bname="([^"]+)"/.exec(attrs)
    const fullPathMatch = /\bpath="([^"]+)"/.exec(attrs)
    const symlinkMatch = /\bis_symlink="([^"]+)"/.exec(attrs)
    const name = nameMatch?.[1] ?? ''
    if (!name) continue // skip malformed rows
    entries.push({
      name,
      path: fullPathMatch?.[1] ?? '',
      isDirectory: kind === 'directory',
      isSymlink: symlinkMatch?.[1] === 'true',
    })
  }

  return {
    path: dirPath,
    count,
    entries,
    success: true,
    error: null,
  }
}

// ─── mcp_* (universal MCP tool) ─────────────────────────────────────────────
//
// Any tool whose name starts with `mcp_` (e.g. `mcp_graphify_graph_stats`,
// `mcp_db_query`) renders through the universal `<McpTool>` card. The backend
// (`handle_tool.zig`) stores MCP results as RAW server text (not a wrapped
// `<tool>` envelope) on success, and as a wrapped
// `wrapToolOutput(..., success=false, err, "")` envelope on failure — so the
// parser tolerates BOTH shapes:
//
//   raw success:   `Nodes: 14885 Edges: 21958 ...` (or JSON)
//   error envelope: `<tool><name>mcp_...</name>...<success>false</success><error>...</error>...</tool>`
//
// `toolName` is the full registry name (`mcp_<server>_<tool>`). The server is
// the segment between the first and second underscore; the sub-tool is the
// remainder (which may itself contain underscores, e.g. `graph_stats`).

export interface ParsedMcp {
  /** Full registry name (e.g. `mcp_graphify_graph_stats`). */
  toolName: string
  /** Server segment (e.g. `graphify`), or null when the name has no second underscore. */
  server: string | null
  /** Sub-tool segment (e.g. `graph_stats`), or null when unparseable. */
  subTool: string | null
  /** Raw output text (unwrapped from `<data>` when an envelope is present). */
  output: string
  /** JSON-pretty (2-space) when output parses as JSON, else identical to output. */
  prettyOutput: string
  /** True when output parsed as JSON. */
  isJson: boolean
  /** Line count of output (0 for empty). */
  lineCount: number
  /** Byte length of output. */
  byteSize: number
  /** False only when an envelope carries `<success>false</success>`. */
  success: boolean
  /** Error message on failure; null on success. */
  error: string | null
}

export function splitMcpToolName(toolName: string): {
  server: string | null
  subTool: string | null
} {
  const prefix = 'mcp_'
  if (!toolName.startsWith(prefix)) return { server: null, subTool: null }
  const after = toolName.slice(prefix.length)
  if (!after) return { server: null, subTool: null }
  const idx = after.indexOf('_')
  if (idx === -1) return { server: after || null, subTool: null }
  const server = after.slice(0, idx) || null
  const subTool = after.slice(idx + 1) || null
  return { server, subTool }
}

export function parseMcp(toolName: string, content: string): ParsedMcp {
  const { server, subTool } = splitMcpToolName(toolName)

  // Envelope-aware unwrap: error path carries `<success>false</success>` +
  // `<error>`, success placeholders carry `<data></data>`. Raw MCP success
  // output has neither tag — fall through to raw.
  const successFlag = extractBool(content, 'success', true)
  const errorTag = extractTag(content, 'error')
  const dataTag = extractTag(content, 'data')

  let output: string
  let success: boolean
  let error: string | null
  if (!successFlag) {
    success = false
    error = errorTag
    output = dataTag ?? ''
  } else if (dataTag !== null) {
    // Wrapped success (placeholder or future backend wrap): inner data.
    success = true
    error = null
    output = dataTag
  } else if (errorTag !== null && content.includes('<tool>')) {
    // Defensive: envelope with error tag but success flag defaulted true
    // (shouldn't happen — wrapToolOutput always pairs them). Treat as error.
    success = false
    error = errorTag
    output = ''
  } else {
    success = true
    error = null
    output = content
  }

  let prettyOutput = output
  let isJson = false
  const trimmed = output.trim()
  if (trimmed) {
    try {
      const parsed = JSON.parse(trimmed)
      prettyOutput = JSON.stringify(parsed, null, 2)
      isJson = true
    } catch {
      // Not JSON — show raw.
    }
  }

  return {
    toolName,
    server,
    subTool,
    output,
    prettyOutput,
    isJson,
    lineCount: output ? output.split('\n').length : 0,
    byteSize: output.length,
    success,
    error,
  }
}

// ─── progressive tools (search_tool / view_tool / use_tool) ──────────────────
//
// Universal `<ProgressiveTool>` card: the three agent tools that let the model
// browse a catalog of not-yet-enabled tools and equip one for the session.
// Backend renderers live in `src/agentic_loop/progressive_catalog.zig`; the
// exec adapter wraps them with the standard `wrapToolOutput` envelope, and
// `ChatView.innerToolData` passes the inner body here.
//
//   search_tool success:
//     <search_tool><query>q</query>[<server>s</server>]
//       <count>N</count><total>M</total><tools>
//         <tool><name>n</name><kind>builtin|mcp</kind><server>s</server>
//           <equipped>session|no</equipped><summary>one-liner</summary></tool>
//         ...
//       </tools>[<truncated/>][<hint>…</hint>]</search_tool>
//   view_tool found:
//     <view_tool><name>n</name><kind>…</kind><server>s</server>
//       <equipped>session|no</equipped><description>…</description>
//       <parameters><![CDATA[{"type":"object",…}]]></parameters>
//       [<note>…</note>|<hint>…</hint>]</view_tool>
//   view_tool miss:
//     <view_tool><name>n</name><found>false</found><error>…</error>
//       [<did_you_mean><name>…</name>…</did_you_mean>]
//       <hint>…</hint></view_tool>
//   use_tool found (minimal equip signal — no repeated schema, view_tool
//   already showed it; the parser still tolerates a legacy <parameters>):
//     <use_tool><name>n</name><kind>…</kind><equipped>true</equipped>
//       <inserted>true|false</inserted>[<wait_next_turn>true</wait_next_turn>]
//       [<source>session</source>]
//       <note>…</note></use_tool>
//   use_tool miss:
//     <use_tool><name>n</name><equipped>false</equipped><inserted>false</inserted>
//       <error>…</error>[<did_you_mean>…</did_you_mean>]<hint>…</hint></use_tool>

export interface ProgressiveCatalogEntry {
  name: string
  kind: string
  server: string
  equipped: string
  summary: string
}

export interface ParsedSearchTool {
  query: string
  server: string | null
  count: number
  total: number
  tools: ProgressiveCatalogEntry[]
  truncated: boolean
  hint: string | null
  success: boolean
  error: string | null
}

export interface ParsedViewTool {
  name: string
  kind: string | null
  server: string | null
  equipped: string | null
  description: string | null
  parameters: string
  prettyParameters: string
  isJsonParameters: boolean
  found: boolean
  note: string | null
  hint: string | null
  suggestions: string[]
  success: boolean
  error: string | null
}

export interface ParsedUseTool {
  name: string
  kind: string | null
  equipped: boolean
  inserted: boolean
  waitNextTurn: boolean
  source: string | null
  parameters: string
  prettyParameters: string
  isJsonParameters: boolean
  note: string | null
  hint: string | null
  suggestions: string[]
  success: boolean
  error: string | null
}

function extractCdata(content: string, tag: string): string | null {
  const openSeq = `<${tag}>`
  const closeSeq = `</${tag}>`
  const openIdx = content.indexOf(openSeq)
  if (openIdx === -1) return null
  const valueStart = openIdx + openSeq.length
  const closeIdx = content.indexOf(closeSeq, valueStart)
  if (closeIdx === -1) return null
  let inner = content.slice(valueStart, closeIdx)
  const cdataOpen = '<![CDATA['
  const cdataClose = ']]>'
  const cOpen = inner.indexOf(cdataOpen)
  const cClose = inner.lastIndexOf(cdataClose)
  if (cOpen !== -1 && cClose !== -1 && cClose > cOpen) {
    inner = inner.slice(cOpen + cdataOpen.length, cClose)
  }
  return inner
}

function extractAllNames(content: string): string[] {
  const block = extractTag(content, 'did_you_mean')
  if (block === null) return []
  const out: string[] = []
  const re = /<name>([\s\S]*?)<\/name>/g
  let m: RegExpExecArray | null
  while ((m = re.exec(block)) !== null) {
    if (m[1] !== undefined) out.push(unescapeXml(m[1]).trim())
  }
  return out.filter((s) => s.length > 0)
}

function prettyJsonOrRaw(s: string): { pretty: string; isJson: boolean } {
  const trimmed = s.trim()
  if (!trimmed) return { pretty: '', isJson: false }
  try {
    return { pretty: JSON.stringify(JSON.parse(trimmed), null, 2), isJson: true }
  } catch {
    return { pretty: s, isJson: false }
  }
}

export function parseSearchTool(content: string): ParsedSearchTool {
  const errorTag = extractTag(content, 'error')
  if (errorTag !== null) {
    return {
      query: extractTag(content, 'query') ?? '',
      server: extractTag(content, 'server'),
      count: 0,
      total: 0,
      tools: [],
      truncated: false,
      hint: extractTag(content, 'hint'),
      success: false,
      error: errorTag,
    }
  }
  const query = extractTag(content, 'query') ?? ''
  const server = extractTag(content, 'server')
  const countRaw = extractTag(content, 'count')
  const totalRaw = extractTag(content, 'total')
  const count = countRaw !== null ? parseInt(countRaw, 10) || 0 : 0
  const total = totalRaw !== null ? parseInt(totalRaw, 10) || 0 : 0
  const toolsBlock = extractTag(content, 'tools') ?? ''
  const tools: ProgressiveCatalogEntry[] = []
  const toolRe = /<tool>([\s\S]*?)<\/tool>/g
  let m: RegExpExecArray | null
  while ((m = toolRe.exec(toolsBlock)) !== null) {
    const block = m[1] ?? ''
    const name = extractTag(block, 'name') ?? ''
    if (!name) continue
    tools.push({
      name,
      kind: extractTag(block, 'kind') ?? '',
      server: extractTag(block, 'server') ?? '',
      equipped: extractTag(block, 'equipped') ?? '',
      summary: extractTag(block, 'summary') ?? '',
    })
  }
  return {
    query,
    server,
    count,
    total,
    tools,
    truncated: content.includes('<truncated'),
    hint: extractTag(content, 'hint'),
    success: true,
    error: null,
  }
}

export function parseViewTool(content: string): ParsedViewTool {
  const errorTag = extractTag(content, 'error')
  const foundTag = extractTag(content, 'found')
  const found = foundTag === null ? errorTag === null : foundTag !== 'false'
  const rawParams = extractCdata(content, 'parameters') ?? ''
  const { pretty, isJson } = prettyJsonOrRaw(rawParams)
  return {
    name: extractTag(content, 'name') ?? '',
    kind: extractTag(content, 'kind'),
    server: extractTag(content, 'server'),
    equipped: extractTag(content, 'equipped'),
    description: extractTag(content, 'description'),
    parameters: rawParams,
    prettyParameters: pretty,
    isJsonParameters: isJson,
    found,
    note: extractTag(content, 'note'),
    hint: extractTag(content, 'hint'),
    suggestions: extractAllNames(content),
    success: errorTag === null,
    error: errorTag,
  }
}

export function parseUseTool(content: string): ParsedUseTool {
  const errorTag = extractTag(content, 'error')
  const rawParams = extractCdata(content, 'parameters') ?? ''
  const { pretty, isJson } = prettyJsonOrRaw(rawParams)
  return {
    name: extractTag(content, 'name') ?? '',
    kind: extractTag(content, 'kind'),
    equipped: extractTag(content, 'equipped') === 'true',
    inserted: extractTag(content, 'inserted') === 'true',
    waitNextTurn: extractTag(content, 'wait_next_turn') === 'true',
    source: extractTag(content, 'source'),
    parameters: rawParams,
    prettyParameters: pretty,
    isJsonParameters: isJson,
    note: extractTag(content, 'note'),
    hint: extractTag(content, 'hint'),
    suggestions: extractAllNames(content),
    success: errorTag === null,
    error: errorTag,
  }
}

// Re-export shared param helper (single source of truth in helpers/).
export { extractParam } from '../../../helpers/extractParam'
// ─── present_files ─────────────────────────────────────────────────────────
//
// Parses the XML envelope produced by `executePresentFilesToString` in
// `src/modules/agent/tools/present_files.zig`:
//
//   <present_files>
//     <status>presented</status>
//     <count>2</count>
//     <files>
//       <file path="/abs/a.txt" bytes="12" mime="text/plain; charset=utf-8" label="notes"/>
//       <file path="/abs/b.jpg" bytes="48211" mime="image/jpeg" label="b.jpg"/>
//     </files>
//   </present_files>
//
// Error shape: <present_files><error>...</error></present_files>

export interface ParsedPresentFile {
  path: string
  bytes: number
  mime: string
  label: string
}

export interface ParsedPresentFiles {
  status: string | null
  count: number | null
  files: ParsedPresentFile[]
  /** null on success, populated on <error>...</error>. */
  error: string | null
}

function parsePresentFileAttrs(attrs: string): ParsedPresentFile {
  const path = /path="([^"]*)"/.exec(attrs)?.[1] ?? ''
  const bytesRaw = /bytes="([^"]*)"/.exec(attrs)?.[1] ?? '0'
  const mime = /mime="([^"]*)"/.exec(attrs)?.[1] ?? 'application/octet-stream'
  const label = /label="([^"]*)"/.exec(attrs)?.[1] ?? ''
  const bytes = Number.parseInt(bytesRaw, 10)
  return {
    path: unescapeXml(path),
    bytes: Number.isFinite(bytes) ? bytes : 0,
    mime: unescapeXml(mime),
    label: unescapeXml(label),
  }
}

export function parsePresentFiles(content: string): ParsedPresentFiles {
  const error = extractTag(content, 'error')
  if (error !== null) {
    return { status: null, count: null, files: [], error }
  }
  const status = extractTag(content, 'status')
  const countRaw = extractTag(content, 'count')
  const count =
    countRaw === null
      ? null
      : Number.isFinite(Number.parseInt(countRaw.trim(), 10))
        ? Number.parseInt(countRaw.trim(), 10)
        : null
  // Self-closing `<file path="..." bytes="..." mime="..." label="..." />`
  // — attribute values are XML-escaped on the backend (quotes in paths
  // become &quot;), so unescape after extraction. Paths can contain `/`,
  // so the lazy match must allow any char: `[\s\S]+?` up to `/>`.
  const files: ParsedPresentFile[] = []
  const fileRegex = /<file\s+([\s\S]+?)\s*\/>/g
  let m
  while ((m = fileRegex.exec(content)) !== null) {
    files.push(parsePresentFileAttrs(m[1] ?? ''))
  }
  return { status, count, files, error: null }
}

/** True for renderable image mimes (thumbnail preview before download). */
export function isPreviewableImage(mime: string): boolean {
  return mime.toLowerCase().startsWith('image/')
}

/** Basename of an absolute path (`/a/b/c.jpg` → `c.jpg`). */
export function basenameOfPath(path: string): string {
  const idx = path.lastIndexOf('/')
  return idx === -1 ? path : path.slice(idx + 1)
}

/** Human-readable byte size (`48211` → `47.1 KB`). */
export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '0 B'
  if (n < 1024) return `${n} B`
  const units = ['KB', 'MB', 'GB']
  let v = n / 1024
  let u = 0
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024
    u += 1
  }
  return `${v.toFixed(1)} ${units[u]}`
}
