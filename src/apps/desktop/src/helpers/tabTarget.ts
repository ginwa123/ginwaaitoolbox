/**
 * Pure helpers for browser-style tabs.
 *
 * A tab is a snapshot of the router target the app already uses
 * (`view` / `session` / `workspaceId` / `itemId` / `pageId` / `sorts`),
 * so nothing here knows about views or stores — it only derives a
 * stable identity, a display hint and a valid persisted shape.
 *
 * The one new query param is `tab=<tabId>`: it names the active tab and
 * is client-only (never sent to the API). It is excluded from identity.
 *
 * Why these are separate from the store: every rule in this file is a
 * decision the reviewer wants to read in one screen (which targets
 * dedupe, which ones never become tabs, what happens to corrupt
 * storage) and they are trivially testable without Pinia or the router.
 */
import { parseItemIdWithChat } from './buildItemIdWithChat'

export type TabQuery = Record<string, string>

/**
 * Display hint only — drives the glyph and the close tooltip. It is
 * deliberately coarse: a pure function cannot know a workspace item's
 * `item_type`, and a wrong icon must never affect behaviour.
 */
export type TabKind = 'home' | 'chat' | 'workspace' | 'kanban-settings' | 'settings' | 'other'

export interface Tab {
  /** Stable across reloads; the value in the URL's `tab` param. */
  id: string
  /** Dedupe identity — two navigations with the same key focus one tab. */
  key: string
  kind: TabKind
  title: string
  path: string
  query: TabQuery
  createdAt: number
}

export interface ClosedTab extends Tab {
  closedAt: number
}

export interface PersistedTabs {
  active: string
  tabs: Tab[]
  closed: ClosedTab[]
}

/** Upper bounds so a long-lived window cannot grow storage without limit. */
export const MAX_TABS = 50
export const MAX_CLOSED = 10

/** Storage format version; anything else is ignored (fresh start). */
export const TABS_VERSION = 1

const SETTINGS_PATH = '/app/settings'
const KANBAN_SETTINGS_RE = /^\/app\/kanban\/([^/]+)\/settings\/?$/

/**
 * Views that are full-surface overlays over whatever was there before
 * (`AppLayout.vue` mounts them `absolute inset-0 z-10` with their own
 * Back button). They are not destinations, so they never become tabs —
 * the strip stays behind them untouched.
 */
const OVERLAY_VIEWS = ['gitfile', 'skill', 'code-editor']

/** `ChatsList` emits this as an event flag, not as a view. */
const NON_VIEW = ['delete-chat']

/**
 * The URL contract is flat strings. Values that are arrays/objects (or
 * empty) are dropped so two URLs that mean the same thing produce the
 * same key.
 */
export function stripTabParam(query: Record<string, unknown> | null | undefined): TabQuery {
  const out: TabQuery = {}
  if (!query) return out
  for (const [key, value] of Object.entries(query)) {
    if (key === 'tab') continue
    if (value === null || value === undefined) continue
    let text = ''
    if (typeof value === 'string') text = value
    else if (typeof value === 'number' || typeof value === 'boolean') text = String(value)
    else continue
    if (text === '') continue
    out[key] = text
  }
  return out
}

/** The query to navigate to for `tab`, i.e. its target plus the tab's name. */
export function withTabParam(query: Record<string, unknown> | null | undefined, tabId: string): TabQuery {
  const out = stripTabParam(query)
  if (tabId) out.tab = tabId
  return out
}

/**
 * Dedupe identity. `tab` and `sorts` are excluded: the first names a tab
 * rather than a target, the second is per-column kanban UI state that
 * changes without the user going anywhere.
 *
 * The `/chat/<taskId>` suffix on `itemId` is stripped so opening a task
 * chat inside a board focuses the board's tab instead of opening a
 * second tab for the same board.
 */
export function tabKeyOf(path: string, query: Record<string, unknown> | null | undefined): string {
  const q = stripTabParam(query)
  const kanbanSettings = KANBAN_SETTINGS_RE.exec(path)
  if (kanbanSettings && kanbanSettings[1]) return `ks:${kanbanSettings[1]}`
  if (path === SETTINGS_PATH || path === `${SETTINGS_PATH}/`) return 'settings'

  const view = q.view || 'chat'
  if (view === 'chat') return q.session ? `chat:${q.session}` : 'home'
  if (view === 'task') return q.task ? `chat:${q.task}` : 'home'
  if (view === 'workspace') {
    const itemId = parseItemIdWithChat(q.itemId ?? '').itemId
    const parts = ['ws', q.workspaceId ?? '', itemId]
    if (q.pageId) parts.push(q.pageId)
    return parts.join(':')
  }
  return `view:${view}`
}

/** `false` means: leave the URL alone and render exactly as before. */
export function shouldTabify(path: string, query: Record<string, unknown> | null | undefined): boolean {
  const view = stripTabParam(query).view ?? ''
  if (OVERLAY_VIEWS.includes(view)) return false
  if (NON_VIEW.includes(view)) return false
  return true
}

export function kindOf(path: string, query: Record<string, unknown> | null | undefined): TabKind {
  if (KANBAN_SETTINGS_RE.test(path)) return 'kanban-settings'
  if (path === SETTINGS_PATH || path === `${SETTINGS_PATH}/`) return 'settings'
  const q = stripTabParam(query)
  const view = q.view || 'chat'
  if (view === 'chat') return q.session ? 'chat' : 'home'
  if (view === 'task') return q.task ? 'chat' : 'home'
  if (view === 'workspace') return 'workspace'
  return 'other'
}

/** Used until a live title (store or SSE) is known. */
export function fallbackTitle(kind: TabKind): string {
  switch (kind) {
    case 'home':
      return 'Chats'
    case 'chat':
      return 'Chat'
    case 'workspace':
      return 'Workspace'
    case 'kanban-settings':
      return 'Kanban settings'
    case 'settings':
      return 'Settings'
    default:
      return 'Tab'
  }
}

let idSequence = 0

/** Unique per creation; the counter keeps two same-millisecond tabs apart. */
export function newTabId(): string {
  idSequence += 1
  return `tab_${Date.now().toString(36)}${idSequence.toString(36)}${Math.random().toString(36).slice(2, 6)}`
}

/**
 * The "new tab page": the chats list. Reused both for the initial tab
 * and whenever the last tab is closed, so the strip is never empty.
 */
export function homeTab(): Tab {
  return {
    id: newTabId(),
    key: 'home',
    kind: 'home',
    title: fallbackTitle('home'),
    path: '/app',
    query: { view: 'chat' },
    createdAt: Date.now(),
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function asKind(value: unknown, path: string, query: TabQuery): TabKind {
  const allowed: TabKind[] = ['home', 'chat', 'workspace', 'kanban-settings', 'settings', 'other']
  if (typeof value === 'string' && (allowed as string[]).includes(value)) return value as TabKind
  return kindOf(path, query)
}

function coerceTab(value: unknown): Tab | null {
  const entry = asRecord(value)
  if (!entry) return null
  const id = asString(entry.id)
  if (!id) return null
  const query = stripTabParam(asRecord(entry.query) ?? {})
  const path = asString(entry.path) || '/app'
  const title = asString(entry.title) || fallbackTitle(kindOf(path, query))
  const createdAt = typeof entry.createdAt === 'number' && Number.isFinite(entry.createdAt) ? entry.createdAt : 0
  return {
    id,
    key: asString(entry.key) || tabKeyOf(path, query),
    kind: asKind(entry.kind, path, query),
    title,
    path,
    query,
    createdAt,
  }
}

function coerceClosedTab(value: unknown): ClosedTab | null {
  const tab = coerceTab(value)
  if (!tab) return null
  const entry = asRecord(value)
  const raw = entry ? entry.closedAt : 0
  const closedAt = typeof raw === 'number' && Number.isFinite(raw) ? raw : 0
  return { ...tab, closedAt }
}

function freshList(): PersistedTabs {
  const tab = homeTab()
  return { active: tab.id, tabs: [tab], closed: [] }
}

/**
 * Total: any input at all yields a usable list. A corrupt, older-version
 * or hand-edited value must never throw at boot — it starts over.
 */
export function parseTabList(raw: string | null | undefined): PersistedTabs {
  if (!raw) return freshList()
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return freshList()
  }
  const root = asRecord(parsed)
  if (!root) return freshList()
  if (root.v !== TABS_VERSION) return freshList()
  if (!Array.isArray(root.tabs)) return freshList()

  const tabs: Tab[] = []
  const seenIds = new Set<string>()
  const seenKeys = new Set<string>()
  for (const raw of root.tabs) {
    const tab = coerceTab(raw)
    if (!tab) continue
    if (seenIds.has(tab.id) || seenKeys.has(tab.key)) continue
    seenIds.add(tab.id)
    seenKeys.add(tab.key)
    tabs.push(tab)
  }
  if (tabs.length === 0) return freshList()

  const closed: ClosedTab[] = []
  if (Array.isArray(root.closed)) {
    for (const raw of root.closed) {
      const tab = coerceClosedTab(raw)
      if (tab) closed.push(tab)
    }
  }

  const first = tabs[0]
  const activeId = asString(root.active)
  const active = first && tabs.some((tab) => tab.id === activeId) ? activeId : (first ? first.id : '')
  return { active, tabs, closed: closed.slice(0, MAX_CLOSED) }
}
