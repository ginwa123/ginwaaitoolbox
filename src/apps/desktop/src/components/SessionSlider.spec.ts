import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { ref, type Ref } from 'vue'
import SessionSlider from './SessionSlider.vue'

describe('SessionSlider', () => {
  let processingState: Ref<Record<string, boolean>>

  beforeEach(() => {
    processingState = ref({})
  })

  it('renders nothing when processingState[sessionId] is falsy', () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    const spinner = document.querySelector('[data-testid="session-slider"]')
    expect(spinner).toBeNull()
    wrapper.unmount()
  })

  it('becomes visible when processingState[sessionId] becomes true', async () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    processingState.value = { ...processingState.value, s_1: true }
    await wrapper.vm.$nextTick()
    const spinner = document.querySelector('[data-testid="session-slider"]') as HTMLElement | null
    expect(spinner).not.toBeNull()
    expect(spinner!.getAttribute('aria-busy')).toBe('true')
    wrapper.unmount()
  })

  it('hides again when processingState[sessionId] flips back to false', async () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    processingState.value = { s_1: true }
    await wrapper.vm.$nextTick()
    processingState.value = {}
    await wrapper.vm.$nextTick()
    const spinner = document.querySelector('[data-testid="session-slider"]')
    expect(spinner).toBeNull()
    wrapper.unmount()
  })

  it('is INDEPENDENT across sessionIds — s_1 processing does NOT show s_2', async () => {
    const wrapper1 = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    const wrapper2 = mount(SessionSlider, {
      props: { sessionId: 's_2' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    processingState.value = { s_1: true } // s_2 stays idle
    await wrapper1.vm.$nextTick()
    await wrapper2.vm.$nextTick()
    // Only the processing session renders a spinner.
    expect(wrapper1.find('[data-testid="session-slider"]').exists()).toBe(true)
    expect(wrapper2.find('[data-testid="session-slider"]').exists()).toBe(false)
    wrapper1.unmount()
    wrapper2.unmount()
  })

  it('the inner circle carries the spinner animation class', async () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    processingState.value = { s_1: true }
    await wrapper.vm.$nextTick()
    const circle = wrapper.find('[data-testid="session-slider-track"]')
    expect(circle.exists()).toBe(true)
    expect(circle.classes()).toContain('session-spinner__circle')
    wrapper.unmount()
  })

  it('the wrapper carries the session-spinner root class', async () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    processingState.value = { s_1: true }
    await wrapper.vm.$nextTick()
    const spinner = wrapper.find('[data-testid="session-slider"]')
    expect(spinner.classes()).toContain('session-spinner')
    wrapper.unmount()
  })

  it('exposes role=status with aria-busy=true while processing', async () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="session-slider"]').exists()).toBe(false)
    processingState.value = { s_1: true }
    await wrapper.vm.$nextTick()
    const spinner = wrapper.find('[data-testid="session-slider"]')
    expect(spinner.attributes('role')).toBe('status')
    expect(spinner.attributes('aria-busy')).toBe('true')
    wrapper.unmount()
  })
})
