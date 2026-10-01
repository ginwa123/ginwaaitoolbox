/*
 * SearchSkills.vue — the `search_skills` card.
 *
 * Pins the NEW paged-search result shape (flat `skills[]` rows with a
 * per-row `scope`, plus `count`/`total`/`offset`/`limit`/`truncated`/
 * `next_offset`/`pattern_warning`). The empty state must distinguish
 * "nothing matched this query" from "no skills installed at all" — that
 * branch is driven by whether `query` came back empty, so both are covered.
 */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import SearchSkills from '../SearchSkills.vue'

const page = {
  query: 'auth',
  pattern_mode: 'regex',
  pattern_warning: null,
  scope: null,
  count: 2,
  total: 7,
  offset: 0,
  limit: 2,
  skills: [
    { name: 'auth', description: 'handles auth', scope: 'global', path: '/g/auth/SKILL.MD' },
    {
      name: 'auth-local',
      description: 'local auth notes',
      scope: 'local',
      path: '/l/auth/SKILL.MD',
    },
  ],
  truncated: true,
  next_offset: 2,
  hint: 'Showing 0-2 of 7 matches — call again with offset=2 (same query) for the next page, or narrow the query.',
}

describe('SearchSkills.vue — header names the tool and the paging facts', () => {
  it('renders search_skills with the count-of-total and the next offset', () => {
    const wrapper = mount(SearchSkills, {
      props: { content: page, expanded: true } as never,
    })
    const text = wrapper.text()
    expect(text).toContain('search_skills')
    expect(text).toContain('2/7 skills')
    expect(text).toContain('next offset 2')
    // The hint (which names the offset for the next page) is rendered too.
    expect(text).toContain('Showing 0-2 of 7 matches')
  })

  it('renders one flat row per skill with a scope badge, path and description', () => {
    const wrapper = mount(SearchSkills, { props: { content: page, expanded: true } as never })
    const rows = wrapper.findAll('[data-testid="search-skills-row"]')
    expect(rows).toHaveLength(2)
    const firstRow = rows.at(0)
    expect(firstRow?.text()).toContain('auth')
    expect(firstRow?.text()).toContain('handles auth')
    expect(firstRow?.text()).toContain('/g/auth/SKILL.MD')
    expect(rows.map((r) => r.find('[data-testid="search-skills-scope"]')?.text())).toEqual([
      'global',
      'local',
    ])
    // The old card split the list into Global / Local sections — no more.
    expect(wrapper.text()).not.toContain('Global Skills')
    expect(wrapper.text()).not.toContain('Local Skills')
  })
})

describe('SearchSkills.vue — warnings and empty states', () => {
  it('surfaces a non-null pattern_warning', () => {
    const wrapper = mount(SearchSkills, {
      props: {
        content: {
          ...page,
          query: 'foo(',
          pattern_mode: 'literal_fallback',
          pattern_warning: 'unbalanced ( — matched as a literal',
          truncated: false,
          next_offset: null,
        },
        expanded: true,
      } as never,
    })
    expect(wrapper.find('[data-testid="search-skills-warning"]').text()).toContain(
      'unbalanced ( — matched as a literal',
    )
  })

  it('renders no warning block when pattern_warning is null', () => {
    const wrapper = mount(SearchSkills, { props: { content: page, expanded: true } as never })
    expect(wrapper.find('[data-testid="search-skills-warning"]').exists()).toBe(false)
  })

  it('distinguishes "no match" from "no skills installed" by query emptiness', () => {
    const noMatch = mount(SearchSkills, {
      props: {
        content: { ...page, skills: [], count: 0, total: 0, hint: '' },
        expanded: true,
      } as never,
    })
    expect(noMatch.find('[data-testid="search-skills-empty"]').text()).toContain(
      'No skills match "auth"',
    )

    const noneInstalled = mount(SearchSkills, {
      props: {
        content: { ...page, query: '', skills: [], count: 0, total: 0, hint: '' },
        expanded: true,
      } as never,
    })
    expect(noneInstalled.find('[data-testid="search-skills-empty"]').text()).toContain(
      'No skills installed',
    )
  })

  it('does not throw on missing / empty data', () => {
    const wrapper = mount(SearchSkills, { props: { content: undefined, expanded: true } as never })
    expect(wrapper.findAll('[data-testid="search-skills-row"]')).toHaveLength(0)
    expect(wrapper.text()).toContain('search_skills')
  })
})

describe('SearchSkills.vue — success with args shows Arguments when expanded', () => {
  it('expanded body shows Arguments', () => {
    const wrapper = mount(SearchSkills, {
      props: {
        content: { query: 'all', skills: [], count: 0, total: 0, hint: '' },
        parameters: '{"query":"all"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.text()).toContain('Arguments')
  })
})
