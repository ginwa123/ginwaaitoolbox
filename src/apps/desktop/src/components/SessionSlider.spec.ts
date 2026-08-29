import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { ref, type Ref } from 'vue'
import SessionSlider from './SessionSlider.vue'

describe('SessionSlider', () => {
  let processingState: Ref<Record<string, boolean>>

  beforeEach(() => {
    processingState = ref({})
  })

  it('renders nothing visible when processingState[sessionId] is falsy', () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    const bar = document.querySelector('[data-testid="session-slider"]') as HTMLElement | null
    expect(bar).not.toBeNull()
    expect(bar!.classList.contains('session-slider--visible')).toBe(false)
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
    const bar = document.querySelector('[data-testid="session-slider"]') as HTMLElement | null
    expect(bar!.classList.contains('session-slider--visible')).toBe(true)
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
    const bar = document.querySelector('[data-testid="session-slider"]') as HTMLElement | null
    expect(bar!.classList.contains('session-slider--visible')).toBe(false)
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
    const bars = document.querySelectorAll('[data-testid="session-slider"]')
    expect(bars.length).toBe(2)
    expect((bars[0] as HTMLElement).classList.contains('session-slider--visible')).toBe(true)
    expect((bars[1] as HTMLElement).classList.contains('session-slider--visible')).toBe(false)
    wrapper1.unmount()
    wrapper2.unmount()
  })

  it('the inner track carries the slide animation class', async () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    processingState.value = { s_1: true }
    await wrapper.vm.$nextTick()
    const track = document.querySelector('[data-testid="session-slider-track"]') as HTMLElement | null
    expect(track).not.toBeNull()
    expect(track!.classList.contains('session-slider__track')).toBe(true)
    wrapper.unmount()
  })

  it('the wrapper carries the session-slider root class', () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    const bar = document.querySelector('[data-testid="session-slider"]') as HTMLElement
    expect(bar.classList.contains('session-slider')).toBe(true)
    wrapper.unmount()
  })

  it('aria-busy reflects the visible state (true when processing, false otherwise)', async () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    const bar = document.querySelector('[data-testid="session-slider"]') as HTMLElement
    expect(bar.getAttribute('aria-busy')).toBe('false')
    processingState.value = { s_1: true }
    await wrapper.vm.$nextTick()
    expect(bar.getAttribute('aria-busy')).toBe('true')
    wrapper.unmount()
  })
})
