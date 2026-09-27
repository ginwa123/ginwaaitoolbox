/**
 * Typed parsers for tool-output JSON `data` payloads.
 *
 * Each parser takes the envelope's `data` payload as a parsed object (via
 * `normalizeToolContent`, which also unwraps full envelopes and JSON
 * strings), reads fields directly, and gracefully handles missing keys
 * (returns `null` for missing optional fields, sensible defaults for
 * missing required fields where applicable).
 *
 * Parsers are pure functions; safe to call inside `computed`. JSON needs
 * no entity decoding — values arrive byte-exact from `std.json`.
 *
 * The legacy XML helpers (`extractTag`, `extractBool`, `extractInt`,
 * `unescapeXml`) are retained for `helpers/isBackgroundCommandOutput.ts`,
 * the only remaining XML consumer. New code must not use them.
 *
 * Conventions:
 *   - Singular boolean fields default to `false` (absent key = false).
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

export function parseTextReplace(data: unknown): ParsedTextReplace {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  const success = error === null
  return {
    path: strField(o, 'path'),
    before: strOrNullField(o, 'before') ?? strOrNullField(o, 'old_str') ?? '',
    after: strOrNullField(o, 'after') ?? strOrNullField(o, 'new_str') ?? '',
    unified: strOrNullField(o, 'unified') ?? '',
    linesChanged: numOrNullField(o, 'lines_changed') ?? 0,
    success,
    error,
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

export function parseWriteFile(data: unknown): ParsedWriteFile {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  const success = error === null
  return {
    path: strOrNullField(o, 'file_write') ?? strField(o, 'path'),
    success,
    error,
  }
}

export interface ParsedRemoveFile {
  path: string
  deleted: boolean
  recursive: boolean
  success: boolean
  error: string | null
}

export function parseRemoveFile(data: unknown): ParsedRemoveFile {
  const o = unwrapDataRecord(data)
  const deleted = boolField(o, 'deleted', false)
  const recursive = boolField(o, 'recursive', false)
  const error = strOrNullField(o, 'error')
  return {
    path: strField(o, 'path'),
    deleted,
    recursive,
    success: error === null && (deleted || !('deleted' in o)),
    error,
  }
}

export interface ParsedEditSkill {
  skillName: string
  edited: boolean
  path: string | null
  success: boolean
  error: string | null
}

export function parseEditSkill(data: unknown): ParsedEditSkill {
  const o = unwrapDataRecord(data)
  const edited = boolField(o, 'edited', false)
  const error = strOrNullField(o, 'error')
  return {
    skillName: strField(o, 'name'),
    edited,
    path: strOrNullField(o, 'path'),
    success: error === null,
    error,
  }
}

export interface ParsedAddSkill {
  skillName: string
  created: boolean
  path: string | null
  success: boolean
  error: string | null
}

export function parseAddSkill(data: unknown): ParsedAddSkill {
  const o = unwrapDataRecord(data)
  const created = boolField(o, 'created', false)
  const error = strOrNullField(o, 'error')
  return {
    skillName: strField(o, 'name'),
    created,
    path: strOrNullField(o, 'path'),
    success: error === null,
    error,
  }
}

export interface ParsedRemoveSkill {
  skillName: string
  removed: boolean
  path: string | null
  success: boolean
  error: string | null
}

export function parseRemoveSkill(data: unknown): ParsedRemoveSkill {
  const o = unwrapDataRecord(data)
  const removed = boolField(o, 'removed', false)
  const error = strOrNullField(o, 'error')
  return {
    skillName: strOrNullField(o, 'skill_name') ?? strField(o, 'name'),
    removed,
    path: strOrNullField(o, 'path'),
    success: error === null,
    error,
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

export function parseSetGitWorktree(data: unknown): ParsedSetGitWorktree {
  const o = unwrapDataRecord(data)
  const cleared = boolField(o, 'cleared', false)
  const created = boolField(o, 'created', false)
  const error = strOrNullField(o, 'error')
  return {
    path: strOrNullField(o, 'path'),
    branch: strOrNullField(o, 'branch'),
    cleared,
    created,
    success: error === null,
    error,
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
 * bash — the unified `command` tool reuses the identical 8-field payload
 * (`command`/`stdout`/`stderr`/`exit_code`/`truncated`/`timeout`/
 * `stdout_lines`/`stderr_lines`), only the `tool` wrapper
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
  outputTruncated: boolean
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
    outputTruncated: boolField(o, 'output_truncated', false),
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

function parseSkillRecord(item: unknown): SkillBlock | null {
  const r = asRecord(item)
  const name = strField(r, 'name')
  if (!name) return null
  return {
    name,
    description: strField(r, 'description'),
    path: strField(r, 'path'),
  }
}

export function parseListSkills(data: unknown): ParsedListSkills {
  const o = unwrapDataRecord(data)
  const globalSkills: SkillBlock[] = []
  const localSkills: SkillBlock[] = []
  const globalRaw = Array.isArray(o.global_skills) ? o.global_skills : []
  for (const item of globalRaw) {
    const block = parseSkillRecord(item)
    if (block) globalSkills.push(block)
  }
  const localRaw = Array.isArray(o.local_skills) ? o.local_skills : []
  for (const item of localRaw) {
    const block = parseSkillRecord(item)
    if (block) localSkills.push(block)
  }
  return {
    globalSkills,
    localSkills,
    totalCount: globalSkills.length + localSkills.length,
  }
}

export interface KanbanListColumn {
  id: string
  name: string
  position: number
  taskCount: number
}

export interface KanbanListTask {
  id: string
  name: string
  columnId: string | null
  columnName: string | null
  position: number
}

export interface ParsedKanbanList {
  workspaceId: string | null
  itemId: string | null
  boardLabel: string | null
  columns: KanbanListColumn[]
  tasks: KanbanListTask[]
  totalCount: number | null
  limit: number | null
  offset: number | null
  hasMore: boolean
  hint: string | null
  error: string | null
  success: boolean
}

export function parseKanbanList(data: unknown): ParsedKanbanList {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return {
      workspaceId: null,
      itemId: null,
      boardLabel: null,
      columns: [],
      tasks: [],
      totalCount: null,
      limit: null,
      offset: null,
      hasMore: false,
      hint: null,
      error,
      success: false,
    }
  }
  const columns: KanbanListColumn[] = []
  const colsRaw = Array.isArray(o.columns) ? o.columns : []
  for (const item of colsRaw) {
    const r = asRecord(item)
    const id = strField(r, 'id')
    if (!id) continue
    columns.push({
      id,
      name: strField(r, 'name'),
      position: numOrNullField(r, 'position') ?? 0,
      taskCount: numOrNullField(r, 'task_count') ?? 0,
    })
  }
  const tasks: KanbanListTask[] = []
  const tasksRaw = Array.isArray(o.tasks) ? o.tasks : []
  for (const item of tasksRaw) {
    const r = asRecord(item)
    const id = strField(r, 'id')
    if (!id) continue
    tasks.push({
      id,
      name: strField(r, 'name'),
      columnId: strOrNullField(r, 'column_id'),
      columnName: strOrNullField(r, 'column_name'),
      position: numOrNullField(r, 'position') ?? 0,
    })
  }
  const workspaceId = strOrNullField(o, 'workspace_id')
  const itemId = strOrNullField(o, 'item_id')
  return {
    workspaceId,
    itemId,
    boardLabel: strOrNullField(o, 'board') ?? strOrNullField(o, 'name'),
    columns,
    tasks,
    totalCount: numOrNullField(o, 'total_count'),
    limit: numOrNullField(o, 'limit'),
    offset: numOrNullField(o, 'offset'),
    hasMore: boolField(o, 'has_more', false),
    hint: strOrNullField(o, 'hint'),
    error: null,
    success: true,
  }
}

export interface ParsedKanbanMove {
  boardId: string | null
  taskId: string | null
  taskName: string | null
  fromColumnId: string | null
  toColumnId: string | null
  columnId: string | null
  columnName: string | null
  position: number | null
  error: string | null
  success: boolean
}

export function parseKanbanMove(data: unknown): ParsedKanbanMove {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return {
      boardId: null,
      taskId: null,
      taskName: null,
      fromColumnId: null,
      toColumnId: null,
      columnId: null,
      columnName: null,
      position: null,
      error,
      success: false,
    }
  }
  const success = boolField(o, 'success', true)
  return {
    boardId: strOrNullField(o, 'board_id'),
    taskId: strOrNullField(o, 'task_id'),
    taskName: strOrNullField(o, 'task_name'),
    fromColumnId: strOrNullField(o, 'from_column_id'),
    toColumnId: strOrNullField(o, 'to_column_id') ?? strOrNullField(o, 'column_id'),
    columnId: strOrNullField(o, 'column_id'),
    columnName: strOrNullField(o, 'column_name'),
    position: numOrNullField(o, 'position'),
    error: null,
    success,
  }
}

/** Quick parser for the `metadata` object used by ReadCompactedMessages. */
export function parseMetadata(data: unknown): Record<string, string> {
  const result: Record<string, string> = {}
  const o = unwrapDataRecord(data)
  const meta = o.metadata !== undefined ? asRecord(o.metadata) : o
  for (const [key, value] of Object.entries(meta)) {
    if (value === null || value === undefined) continue
    if (typeof value === 'string') result[key] = value
    else if (typeof value === 'number' || typeof value === 'boolean') result[key] = String(value)
  }
  return result
}

// ─── generate_image ────────────────────────────────────────────────────────
//
// Parses the JSON `data` payload produced by `execute_generate_image` in
// `src/modules/agent/tools/generate_image.zig`:
//
//   {"status":"generated","count":1,"model":"dall-e-3","size":"1024x1024",
//    "images":[{"index":0,"path":"/cwd/.../img_xxx.png","bytes":12345,"mime":"image/png"}],
//    "revised_prompt":"A vibrant watercolor painting of a hat-wearing cat","error":null}
//
// On error:
//   {"status":null,"count":null,"model":null,"size":null,"images":[],
//    "revised_prompt":null,"error":"HTTP 400: ..."}

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

export function parseGenerateImage(data: unknown): ParsedGenerateImage {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
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
  const images: ParsedGenerateImage['images'] = []
  const imagesRaw = Array.isArray(o.images) ? o.images : []
  for (const item of imagesRaw) {
    const r = asRecord(item)
    images.push({
      index: numOrNullField(r, 'index') ?? 0,
      path: strField(r, 'path'),
      bytes: numOrNullField(r, 'bytes') ?? 0,
      mime: strField(r, 'mime') || 'image/png',
    })
  }

  return {
    status: strOrNullField(o, 'status'),
    count: numOrNullField(o, 'count'),
    model: strOrNullField(o, 'model'),
    size: strOrNullField(o, 'size'),
    images,
    revisedPrompt: strOrNullField(o, 'revised_prompt'),
    error: null,
  }
}

// ─── list_directory ─────────────────────────────────────────────────────────
//
// Parses the JSON `data` payload produced by `execute_list_directory` +
// `toJSON` in `src/modules/agent/tools/list_directory.zig`:
//
//   {"path":"/proj","count":3,"entries":[
//     {"name":"src","path":"/proj/src","is_directory":true,"is_symlink":false},
//     {"name":"main.zig","path":"/proj/main.zig","is_directory":false,"is_symlink":false}
//   ]}
//
// The sort order is whatever the backend produced (directories first,
// then files, alphabetical) — the frontend does NOT re-sort.
//
// On error, `normalizeToolContent` unwraps the full envelope and the
// parser reads the `error` key — see the `error !== null` branch below.

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

export function parseListDirectory(data: unknown): ParsedListDirectory {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return { path: '', count: 0, entries: [], success: false, error }
  }

  const dirPath = strField(o, 'path')
  const entriesRaw = Array.isArray(o.entries) ? o.entries : []
  const entries: ParsedListDirectoryEntry[] = []
  for (const item of entriesRaw) {
    const r = asRecord(item)
    const name = strField(r, 'name')
    if (!name) continue // skip malformed rows
    entries.push({
      name,
      path: strField(r, 'path'),
      isDirectory: boolField(r, 'is_directory', false),
      isSymlink: boolField(r, 'is_symlink', false),
    })
  }

  return {
    path: dirPath,
    count: numOrNullField(o, 'count') ?? entries.length,
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
// envelope) on success, and as a wrapped
// `wrapToolOutput(..., success=false, err, "")` JSON envelope on failure — so the
// parser tolerates BOTH shapes:
//
//   raw success:   `Nodes: 14885 Edges: 21958 ...` (or JSON)
//   error envelope: `{"tool":"mcp_...","parameters":{},"success":false,"data":null,"error":"..."}`
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

export function parseMcp(toolName: string, data: unknown): ParsedMcp {
  const { server, subTool } = splitMcpToolName(toolName)

  // The MCP `data` payload is the raw server text on success (a string),
  // or an object carrying `error` on failure. A full envelope object is
  // unwrapped one level so error fallbacks keep working.
  let output: string
  let success: boolean
  let error: string | null
  if (typeof data === 'string') {
    success = true
    error = null
    output = data
  } else if (data === null || data === undefined) {
    success = true
    error = null
    output = ''
  } else if (typeof data === 'object' && !Array.isArray(data)) {
    const record = data as Record<string, unknown>
    if (
      typeof record.tool === 'string' ||
      (typeof record.success === 'boolean' && 'data' in record)
    ) {
      const ok = record.success !== false
      if (!ok) {
        success = false
        error = typeof record.error === 'string' ? record.error : 'tool failed'
        output = ''
      } else {
        const inner = record.data
        success = true
        error = null
        output = typeof inner === 'string' ? inner : JSON.stringify(inner ?? '')
      }
    } else if (typeof record.error === 'string') {
      success = false
      error = record.error
      output = typeof record.output === 'string' ? record.output : ''
    } else if (typeof record.output === 'string') {
      success = true
      error = null
      output = record.output
    } else {
      success = true
      error = null
      output = JSON.stringify(data)
    }
  } else {
    success = true
    error = null
    output = String(data)
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
// exec adapter wraps them with the standard `wrapToolOutput` JSON envelope,
// and the card reads the inner `data` object here.
//
//   search_tool success:
//     {"query":"q","server":"s"|null,"count":N,"total":M,
//      "tools":[{"name":"n","kind":"builtin|mcp","server":"s",
//        "equipped":"session|no","summary":"one-liner"}, ...],
//      "truncated":false,"hint":"..."|null}
//   view_tool found:
//     {"name":"n","kind":"...","server":"s","equipped":"session|no",
//      "description":"...","parameters":{...}|"..."|null,
//      "note":null,"hint":"..."}
//   view_tool miss:
//     {"name":"n","found":false,"error":"...",
//      "did_you_mean":["..."],"hint":"..."}
//   use_tool found (minimal equip signal — no repeated schema, view_tool
//   already showed it):
//     {"name":"n","kind":"...","equipped":true,
//      "inserted":true|false,"wait_next_turn":true|false,
//      "source":"session"|null,"note":"..."}
//   use_tool miss:
//     {"name":"n","equipped":false,"inserted":false,
//      "error":"...","did_you_mean":[...],"hint":"..."}

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

function extractAllNames(o: Record<string, unknown>): string[] {
  const raw = o.did_you_mean ?? o.suggestions
  if (!Array.isArray(raw)) return []
  const out: string[] = []
  for (const item of raw) {
    if (typeof item === 'string') {
      const t = item.trim()
      if (t) out.push(t)
    } else {
      const r = asRecord(item)
      const name = strField(r, 'name').trim()
      if (name) out.push(name)
    }
  }
  return out
}

/** Read the `parameters` payload: a JSON-schema object, its JSON string, or ''. */
function readParametersField(o: Record<string, unknown>): string {
  const v = o.parameters
  if (v === null || v === undefined) return ''
  if (typeof v === 'string') return v
  try {
    return JSON.stringify(v)
  } catch {
    return ''
  }
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

export function parseSearchTool(data: unknown): ParsedSearchTool {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return {
      query: strField(o, 'query'),
      server: strOrNullField(o, 'server'),
      count: 0,
      total: 0,
      tools: [],
      truncated: false,
      hint: strOrNullField(o, 'hint'),
      success: false,
      error,
    }
  }
  const tools: ProgressiveCatalogEntry[] = []
  const toolsRaw = Array.isArray(o.tools) ? o.tools : []
  for (const item of toolsRaw) {
    const r = asRecord(item)
    const name = strField(r, 'name')
    if (!name) continue
    tools.push({
      name,
      kind: strField(r, 'kind'),
      server: strField(r, 'server'),
      equipped: strField(r, 'equipped'),
      summary: strField(r, 'summary'),
    })
  }
  return {
    query: strField(o, 'query'),
    server: strOrNullField(o, 'server'),
    count: numOrNullField(o, 'count') ?? tools.length,
    total: numOrNullField(o, 'total') ?? tools.length,
    tools,
    truncated: boolField(o, 'truncated', false),
    hint: strOrNullField(o, 'hint'),
    success: true,
    error: null,
  }
}

export function parseViewTool(data: unknown): ParsedViewTool {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  const foundRaw = o.found
  const found =
    foundRaw === undefined || foundRaw === null
      ? error === null
      : foundRaw !== false && foundRaw !== 'false'
  const rawParams = readParametersField(o)
  const { pretty, isJson } = prettyJsonOrRaw(rawParams)
  return {
    name: strField(o, 'name'),
    kind: strOrNullField(o, 'kind'),
    server: strOrNullField(o, 'server'),
    equipped: strOrNullField(o, 'equipped'),
    description: strOrNullField(o, 'description'),
    parameters: rawParams,
    prettyParameters: pretty,
    isJsonParameters: isJson,
    found,
    note: strOrNullField(o, 'note'),
    hint: strOrNullField(o, 'hint'),
    suggestions: extractAllNames(o),
    success: error === null,
    error,
  }
}

export function parseUseTool(data: unknown): ParsedUseTool {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  const rawParams = readParametersField(o)
  const { pretty, isJson } = prettyJsonOrRaw(rawParams)
  return {
    name: strField(o, 'name'),
    kind: strOrNullField(o, 'kind'),
    equipped: boolField(o, 'equipped', false),
    inserted: boolField(o, 'inserted', false),
    waitNextTurn: boolField(o, 'wait_next_turn', false),
    source: strOrNullField(o, 'source'),
    parameters: rawParams,
    prettyParameters: pretty,
    isJsonParameters: isJson,
    note: strOrNullField(o, 'note'),
    hint: strOrNullField(o, 'hint'),
    suggestions: extractAllNames(o),
    success: error === null,
    error,
  }
}

// Re-export shared param helper (single source of truth in helpers/).
export { extractParam } from '../../../helpers/extractParam'
// ─── present_files ─────────────────────────────────────────────────────────
//
// Parses the JSON `data` payload produced by `executePresentFilesToString` in
// `src/modules/agent/tools/present_files.zig`:
//
//   {"status":"presented","count":2,"files":[
//     {"path":"/abs/a.txt","bytes":12,"mime":"text/plain; charset=utf-8","label":"notes"},
//     {"path":"/abs/b.jpg","bytes":48211,"mime":"image/jpeg","label":"b.jpg"}
//   ],"error":null}
//
// Error shape: {"status":null,"count":0,"files":[],"error":"..."}

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

function parsePresentFileRecord(item: unknown): ParsedPresentFile {
  const r = asRecord(item)
  return {
    path: strField(r, 'path'),
    bytes: numOrNullField(r, 'bytes') ?? 0,
    mime: strField(r, 'mime') || 'application/octet-stream',
    label: strField(r, 'label'),
  }
}

export function parsePresentFiles(data: unknown): ParsedPresentFiles {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return { status: null, count: null, files: [], error }
  }
  const files: ParsedPresentFile[] = []
  const filesRaw = Array.isArray(o.files) ? o.files : []
  for (const item of filesRaw) {
    files.push(parsePresentFileRecord(item))
  }
  return {
    status: strOrNullField(o, 'status'),
    count: numOrNullField(o, 'count') ?? files.length,
    files,
    error: null,
  }
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
