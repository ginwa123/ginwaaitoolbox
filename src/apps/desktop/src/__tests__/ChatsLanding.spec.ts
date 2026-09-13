import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import Chats from '../components/views/Chats.vue'

/**
 * The landing page is a static brand page (spec:
 * docs/superpowers/specs/2026-09-13-home-landing-design.md). Two of these tests
 * are SCOPE GUARDS: the user explicitly removed the composer, the actions and
 * the modes strip, and the page used to fake an assistant turn — so a future
 * "just one quick action" or a reintroduced canned message should fail here
 * rather than ship.
 */

describe('Chats — Nalar landing page', () => {
  it('introduces Nalar with a wordmark, a tagline and the blurb', () => {
    const wrapper = mount(Chats)

    expect(wrapper.find('[data-testid="home-landing"]').exists()).toBe(true)
    expect(wrapper.find('h1[data-testid="home-wordmark"]').text()).toBe('nalar')
    expect(wrapper.find('[data-testid="home-tagline"]').text()).toBe('AI agent workspace')

    const blurb = wrapper.find('[data-testid="home-blurb"]').text()
    expect(blurb).toContain('AI agent workspace')
    expect(blurb).toContain('kanban')
    expect(blurb).toContain('canvas')
  })

  it('uses a single h1 so the page has a heading outline', () => {
    const wrapper = mount(Chats)
    expect(wrapper.findAll('h1')).toHaveLength(1)
  })

  it('no longer fakes an assistant turn (scope guard)', () => {
    const wrapper = mount(Chats)
    // the old stub rendered this string with a `new Date()` timestamp, so it
    // looked like a real reply that could never be answered
    expect(wrapper.text()).not.toContain('AI coding assistant')
    expect(wrapper.text()).not.toContain('How can I help you today')
  })

  it('stays inert: no composer, no actions, no lists (scope guard)', () => {
    const wrapper = mount(Chats)
    expect(wrapper.find('input').exists()).toBe(false)
    expect(wrapper.find('textarea').exists()).toBe(false)
    expect(wrapper.find('button').exists()).toBe(false)
    expect(wrapper.find('ul').exists()).toBe(false)
  })

  it('keeps the one-line hint that tells the user where to start', () => {
    const wrapper = mount(Chats)
    expect(wrapper.text()).toContain('Open a chat in the sidebar')
  })
})
