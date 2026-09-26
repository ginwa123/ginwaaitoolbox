import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { ref, type Ref } from 'vue'
import SessionSlider from './SessionSlider.vue'

const originalMatchMedia = window.matchMedia

const setReducedMotion = (matches: boolean) => {
  const mediaQuery = {
    matches,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  }
  Object.defineProperty(window, 'matchMedia', {
    configurable: true,
    value: vi.fn().mockReturnValue(mediaQuery),
  })
  return mediaQuery
}

describe('SessionSlider', () => {
  let processingState: Ref<Record<string, boolean>>

  beforeEach(() => {
    processingState = ref({})
  })

  afterEach(() => {
    Object.defineProperty(window, 'matchMedia', {
      configurable: true,
      value: originalMatchMedia,
    })
  })

  const mountVisibleSpinner = () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    processingState.value = { s_1: true }
    return wrapper
  }

  it('renders nothing when processingState[sessionId] is falsy', () => {
    const wrapper = mount(SessionSlider, {
      props: { sessionId: 's_1' },
      global: { provide: { processingState } },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="session-slider"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('shows native SVG rotation instead of a CSS border-rotation spinner', async () => {
    const wrapper = mountVisibleSpinner()
    await wrapper.vm.$nextTick()

    const svg = wrapper.find('[data-testid="session-slider-track"]')
    expect(svg.exists()).toBe(true)
    expect(svg.element.tagName.toLowerCase()).toBe('svg')
    expect(wrapper.find('.session-spinner__circle').exists()).toBe(false)

    const motion = wrapper.find('[data-testid="session-spinner-motion"]')
    expect(motion.exists()).toBe(true)
    expect(motion.element.tagName.toLowerCase()).toBe('animatetransform')
    expect(motion.attributes('attributeName')).toBe('transform')
    expect(motion.attributes('type')).toBe('rotate')
    expect(motion.attributes('from')).toBe('0 10 10')
    expect(motion.attributes('to')).toBe('360 10 10')
    expect(motion.attributes('dur')).toBe('0.8s')
    expect(motion.attributes('repeatCount')).toBe('indefinite')
    wrapper.unmount()
  })

  it('keeps the static reduced-motion ring when the user requests reduced motion', async () => {
    const mediaQuery = setReducedMotion(true)
    const wrapper = mountVisibleSpinner()
    await wrapper.vm.$nextTick()

    // VueUse's useMediaQuery subscribes with `{ passive: true }` as the third
    // argument, so match the full (event, handler, options) triple.
    expect(mediaQuery.addEventListener).toHaveBeenCalledWith(
      'change',
      expect.any(Function),
      expect.anything(),
    )
    expect(wrapper.find('[data-testid="session-spinner-motion"]').exists()).toBe(false)
    expect(wrapper.find('.session-spinner__arc').exists()).toBe(true)
    wrapper.unmount()
    expect(mediaQuery.removeEventListener).toHaveBeenCalledWith(
      'change',
      expect.any(Function),
      expect.anything(),
    )
  })

  it('hides again when processingState[sessionId] flips back to false', async () => {
    const wrapper = mountVisibleSpinner()
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="session-slider"]').exists()).toBe(true)

    processingState.value = {}
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="session-slider"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('is independent across sessionIds', async () => {
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
    processingState.value = { s_1: true }
    await wrapper1.vm.$nextTick()
    await wrapper2.vm.$nextTick()

    expect(wrapper1.find('[data-testid="session-slider"]').exists()).toBe(true)
    expect(wrapper2.find('[data-testid="session-slider"]').exists()).toBe(false)
    wrapper1.unmount()
    wrapper2.unmount()
  })

  it('exposes role=status with aria-busy=true while processing', async () => {
    const wrapper = mountVisibleSpinner()
    await wrapper.vm.$nextTick()
    const spinner = wrapper.find('[data-testid="session-slider"]')

    expect(spinner.attributes('role')).toBe('status')
    expect(spinner.attributes('aria-busy')).toBe('true')
    expect(spinner.attributes('aria-label')).toBe('Agent is working')
    wrapper.unmount()
  })
})
