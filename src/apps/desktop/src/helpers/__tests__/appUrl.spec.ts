import { describe, expect, it } from 'vitest'
import {
  buildAppUrl,
  detectLegacyAppUrl,
  isAppPath,
  normalizeAppPath,
  parseAppPath,
} from '../appUrl'

describe('appUrl — path-based URL contract (2026-09-22 revamp)', () => {
  describe('buildAppUrl', () => {
    it('landing: no ids → /app', () => {
      expect(buildAppUrl({})).toEqual({ path: '/app', query: {} })
    })
    it('workspace: /app/{ws}', () => {
      expect(buildAppUrl({ workspaceId: 'ws_1' })).toEqual({ path: '/app/ws_1', query: {} })
    })
    it('chat: /app/{ws}/chat/{sid}', () => {
      expect(buildAppUrl({ workspaceId: 'ws_1', chatSessionId: 'sess_9' })).toEqual({
        path: '/app/ws_1/chat/sess_9',
        query: {},
      })
    })
    it('project: /app/{ws}/projects/{pid} (+ query sub-state)', () => {
      expect(
        buildAppUrl({ workspaceId: 'ws_1', projectId: 'item_7', query: { sorts: 'a:b:asc' } }),
      ).toEqual({ path: '/app/ws_1/projects/item_7', query: { sorts: 'a:b:asc' } })
    })
    it('project chat: /app/{ws}/projects/{pid}/chat/{tid}', () => {
      expect(
        buildAppUrl({ workspaceId: 'ws_1', projectId: 'item_7', chatTaskId: 'task_3' }),
      ).toEqual({ path: '/app/ws_1/projects/item_7/chat/task_3', query: {} })
    })
    it('throws on incoherent combinations', () => {
      expect(() => buildAppUrl({ chatSessionId: 's' })).toThrow('workspaceId is required')
      expect(() => buildAppUrl({ workspaceId: 'w', chatSessionId: 's', projectId: 'p' })).toThrow(
        'cannot combine',
      )
      expect(() => buildAppUrl({ workspaceId: 'w', chatTaskId: 't' })).toThrow(
        'chatTaskId requires projectId',
      )
    })
  })

  describe('parseAppPath', () => {
    it('parses all five shapes', () => {
      expect(parseAppPath('/app')).toEqual({ kind: 'landing' })
      expect(parseAppPath('/app/ws_1')).toEqual({ kind: 'workspace', workspaceId: 'ws_1' })
      expect(parseAppPath('/app/ws_1/chat/sess_9')).toEqual({
        kind: 'chat',
        workspaceId: 'ws_1',
        sessionId: 'sess_9',
      })
      expect(parseAppPath('/app/ws_1/projects/item_7')).toEqual({
        kind: 'project',
        workspaceId: 'ws_1',
        projectId: 'item_7',
      })
      expect(parseAppPath('/app/ws_1/projects/item_7/chat/task_3')).toEqual({
        kind: 'projectChat',
        workspaceId: 'ws_1',
        projectId: 'item_7',
        chatTaskId: 'task_3',
      })
    })
    it('tolerates trailing slashes', () => {
      expect(parseAppPath('/app/ws_1/')).toEqual({ kind: 'workspace', workspaceId: 'ws_1' })
      expect(parseAppPath('/app/ws_1/projects/item_7/')).toEqual({
        kind: 'project',
        workspaceId: 'ws_1',
        projectId: 'item_7',
      })
    })
    it('non-app paths → other', () => {
      expect(parseAppPath('/app/settings')).toEqual({ kind: 'other', path: '/app/settings' })
      expect(parseAppPath('/app/kanban/i_1/settings')).toEqual({
        kind: 'other',
        path: '/app/kanban/i_1/settings',
      })
      expect(parseAppPath('/app/chat/sess_9')).toEqual({ kind: 'other', path: '/app/chat/sess_9' })
      expect(parseAppPath('/login')).toEqual({ kind: 'other', path: '/login' })
    })
  })

  describe('normalizeAppPath / isAppPath', () => {
    it('strips trailing slashes, keeps root', () => {
      expect(normalizeAppPath('/app/ws_1/')).toBe('/app/ws_1')
      expect(normalizeAppPath('/app/ws_1///')).toBe('/app/ws_1')
      expect(normalizeAppPath('/app')).toBe('/app')
      expect(normalizeAppPath('/')).toBe('/')
      expect(normalizeAppPath('')).toBe('/app')
    })
    it('isAppPath matches the five shapes only', () => {
      expect(isAppPath('/app')).toBe(true)
      expect(isAppPath('/app/ws_1/chat/s')).toBe(true)
      expect(isAppPath('/app/settings')).toBe(false)
      expect(isAppPath('/app/chat/s')).toBe(false)
    })
  })

  describe('detectLegacyAppUrl', () => {
    it('canonical URLs → null', () => {
      expect(detectLegacyAppUrl('/app', {})).toBeNull()
      expect(detectLegacyAppUrl('/app/ws_1', {})).toBeNull()
      expect(detectLegacyAppUrl('/app/ws_1/chat/s', {})).toBeNull()
      expect(detectLegacyAppUrl('/app/ws_1/projects/p', { sorts: 'x' })).toBeNull()
    })
    it('trailing slash → normalize target', () => {
      expect(detectLegacyAppUrl('/app/ws_1/', {})).toEqual({ path: '/app/ws_1', query: {} })
    })
    it('legacy path routes → __legacy marker', () => {
      expect(detectLegacyAppUrl('/app/chat/sess_9', {})).toEqual({
        path: null,
        query: { __legacy: 'chat:sess_9' },
      })
      expect(detectLegacyAppUrl('/app/task/task_3', {})).toEqual({
        path: null,
        query: { __legacy: 'task:task_3' },
      })
    })
    it('legacy ?view= URLs → __legacy marker, view dropped, rest preserved', () => {
      expect(detectLegacyAppUrl('/app', { view: 'chat', session: 'sess_9', tab: 'tab_1' })).toEqual(
        { path: null, query: { session: 'sess_9', tab: 'tab_1', __legacy: 'view:chat' } },
      )
      expect(
        detectLegacyAppUrl('/app', { view: 'workspace', workspaceId: 'ws_1', itemId: 'i_2' }),
      ).toEqual({
        path: null,
        query: { workspaceId: 'ws_1', itemId: 'i_2', __legacy: 'view:workspace' },
      })
      expect(detectLegacyAppUrl('/app', { view: 'task', task: 't' })).toEqual({
        path: null,
        query: { task: 't', __legacy: 'view:task' },
      })
    })
    it('unknown ?view= values pass through untouched', () => {
      expect(detectLegacyAppUrl('/app', { view: 'gitfile' })).toBeNull()
    })
  })
})
