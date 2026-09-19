import { mount } from '@vue/test-utils'
import { beforeAll, describe, expect, it } from 'vitest'
import TextReplace from '../TextReplace.vue'
import ToolParameters from '../_shared/ToolParameters.vue'

beforeAll(() => {
  Object.defineProperty(globalThis, 'localStorage', {
    value: (() => {
      const store = new Map<string, string>()
      return {
        getItem: (k: string) => store.get(k) ?? null,
        setItem: (k: string, v: string) => store.set(k, v),
        removeItem: (k: string) => store.delete(k),
        clear: () => store.clear(),
        get length() {
          return store.size
        },
        key: (i: number) => Array.from(store.keys())[i] ?? null,
      }
    })(),
    writable: true,
    configurable: true,
  })
})

describe('TextReplace.vue — diff fallback + filtered Arguments', () => {
  it('error envelope with null data still renders a diff from parameters old_str/new_str', async () => {
    const params = JSON.stringify({
      path: '/proj/a.txt',
      old_str: 'line1\nline2',
      new_str: 'line1\nLINE2-EDITED',
    })
    // Error path: ChatView passes the full envelope as content, so
    // normalizeToolContent yields data=null + error message.
    const envelope = JSON.stringify({
      tool: 'text_replace',
      parameters: JSON.parse(params),
      success: false,
      data: null,
      error: 'text_replace failed: OldStrNotFound',
      v: 1,
    })
    const wrapper = mount(TextReplace, {
      props: { content: envelope, parameters: params, expanded: true } as never,
    })
    // Diff renders from the parameters fallback even though data is null.
    expect(wrapper.html()).toContain('Before')
    expect(wrapper.html()).toContain('After')
    // Arguments must NOT repeat the huge raw blob — only the path survives.
    const args = wrapper.findComponent(ToolParameters)
    expect(args.exists()).toBe(true)
    expect(args.find('pre').text()).toContain('/proj/a.txt')
    expect(args.find('pre').text()).not.toContain('LINE2-EDITED')
    expect(args.find('pre').text()).not.toContain('old_str')
  })

  it('success envelope keeps envelope diff and hides old_str/new_str from Arguments', async () => {
    const params = JSON.stringify({
      path: '/proj/a.txt',
      old_str: 'aaa',
      new_str: 'bbb',
    })
    const wrapper = mount(TextReplace, {
      props: {
        content: {
          path: '/proj/a.txt',
          before: 'aaa',
          after: 'bbb',
          unified: '@@',
          lines_changed: 2,
          error: null,
        },
        parameters: params,
        expanded: true,
      } as never,
    })
    expect(wrapper.html()).toContain('Before')
    const args = wrapper.findComponent(ToolParameters)
    expect(args.find('pre').text()).toContain('/proj/a.txt')
    expect(args.find('pre').text()).not.toContain('old_str')
    expect(args.find('pre').text()).not.toContain('new_str')
  })

  it('delete (new_str="") still counts as a diff via parameters fallback', async () => {
    const params = JSON.stringify({
      path: '/proj/a.txt',
      old_str: 'remove me',
      new_str: '',
    })
    const envelope = JSON.stringify({
      tool: 'text_replace',
      parameters: JSON.parse(params),
      success: false,
      data: null,
      error: 'text_replace failed: OldStrNotFound',
      v: 1,
    })
    const wrapper = mount(TextReplace, {
      props: { content: envelope, parameters: params, expanded: true } as never,
    })
    expect(wrapper.html()).toContain('Before')
  })

  // Regression: the DB diffview_* columns are NULL (backend only fills them
  // from legacy XML), so ChatView passes explicit null props. Null must fall
  // through to the envelope data — passing it into DiffView crashes
  // splitLines (Cannot read properties of null). Exact shape from the
  // production crash report.
  it('explicit null diffview props fall through to envelope data (no crash)', async () => {
    const params = JSON.stringify({
      path: '/tmp/nalar_dummy_test.txt',
      old_str: 'test again - second replacement works!',
      new_str: 'again - third replacement works! count: 3',
    })
    const wrapper = mount(TextReplace, {
      props: {
        content: {
          path: '/tmp/nalar_dummy_test.txt',
          unified: '@@ -1,2 +1,2 @@',
          before: 'test again - second replacement works!',
          after: 'again - third replacement works! count: 3',
          lines_changed: 2,
          error: null,
        },
        parameters: params,
        expanded: true,
        diffviewBefore: null,
        diffviewAfter: null,
      } as never,
    })
    expect(wrapper.html()).toContain('Before')
    expect(wrapper.html()).toContain('After')
  })

  it('null diffview props + error envelope still diffs from parameters', async () => {
    const params = JSON.stringify({
      path: '/proj/a.txt',
      old_str: 'aaa',
      new_str: 'bbb',
    })
    const envelope = JSON.stringify({
      tool: 'text_replace',
      parameters: JSON.parse(params),
      success: false,
      data: null,
      error: 'text_replace failed: OldStrNotFound',
      v: 1,
    })
    const wrapper = mount(TextReplace, {
      props: {
        content: envelope,
        parameters: params,
        expanded: true,
        diffviewBefore: null,
        diffviewAfter: null,
      } as never,
    })
    expect(wrapper.html()).toContain('Before')
    expect(wrapper.html()).toContain('After')
  })
})
