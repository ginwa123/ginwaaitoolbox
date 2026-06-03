import { describe, it, expect } from 'vitest'

import { mount } from '@vue/test-utils'
import App from '../App.vue'

describe('App', () => {
  it('mounts without throwing', () => {
    // Smoke test: App.vue should mount cleanly. EventSource is polyfilled
    // in src/__tests__/setup.ts so the SSE connection opened in onMounted
    // does not crash. The template is a <router-view />, so we only assert
    // that the component instance exists — no router is provided here.
    const wrapper = mount(App)
    expect(wrapper.exists()).toBe(true)
  })
})
