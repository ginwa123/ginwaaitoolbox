import { describe, it, expect, vi, beforeEach } from 'vitest'
import { useDesignDragDebounce } from '../composables/useDesignDragDebounce'

describe('useDesignDragDebounce', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  it('recordDelta schedules a flush after 250 ms of stillness', () => {
    const onFlush = vi.fn()
    const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

    debounce.recordDelta({ x: 100, y: 200 })

    expect(onFlush).not.toHaveBeenCalled()
    vi.advanceTimersByTime(249)
    expect(onFlush).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(onFlush).toHaveBeenCalledTimes(1)
    expect(onFlush).toHaveBeenCalledWith({ x: 100, y: 200 })
  })

  it('resets the idle window on every recordDelta (only the LAST snapshot flushes)', () => {
    const onFlush = vi.fn()
    const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

    debounce.recordDelta({ x: 100, y: 200 })
    vi.advanceTimersByTime(100)
    debounce.recordDelta({ x: 150, y: 250 })
    vi.advanceTimersByTime(100)
    debounce.recordDelta({ x: 200, y: 300 })

    vi.advanceTimersByTime(250)
    expect(onFlush).toHaveBeenCalledTimes(1)
    expect(onFlush).toHaveBeenCalledWith({ x: 200, y: 300 })
  })

  it('flush() fires synchronously and clears the timer (pointerup behavior)', () => {
    const onFlush = vi.fn()
    const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

    debounce.recordDelta({ x: 100, y: 200 })
    vi.advanceTimersByTime(50)

    debounce.flush()

    expect(onFlush).toHaveBeenCalledTimes(1)
    expect(onFlush).toHaveBeenCalledWith({ x: 100, y: 200 })

    // The timer should be cleared — advancing past 250 ms must NOT fire again
    vi.advanceTimersByTime(500)
    expect(onFlush).toHaveBeenCalledTimes(1)
  })

  it('cancel() clears the timer and snapshot without firing (pointercancel behavior)', () => {
    const onFlush = vi.fn()
    const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

    debounce.recordDelta({ x: 100, y: 200 })
    debounce.cancel()

    vi.advanceTimersByTime(500)
    expect(onFlush).not.toHaveBeenCalled()
  })

  it('flush() is a no-op when nothing has been recorded (no spurious empty flush)', () => {
    const onFlush = vi.fn()
    const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

    debounce.flush()
    expect(onFlush).not.toHaveBeenCalled()
  })

  it('recordDelta after flush() starts a new debounce window', () => {
    const onFlush = vi.fn()
    const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

    debounce.recordDelta({ x: 100, y: 200 })
    debounce.flush()
    onFlush.mockClear()

    debounce.recordDelta({ x: 300, y: 400 })
    vi.advanceTimersByTime(250)
    expect(onFlush).toHaveBeenCalledTimes(1)
    expect(onFlush).toHaveBeenCalledWith({ x: 300, y: 400 })
  })

  it('dispose() clears the timer (no leaked timers after the component is destroyed)', () => {
    const onFlush = vi.fn()
    const debounce = useDesignDragDebounce({ onFlush, idleMs: 250 })

    debounce.recordDelta({ x: 100, y: 200 })

    // Simulate component unmount: dispose the composable
    debounce.dispose()
    vi.advanceTimersByTime(500)
    expect(onFlush).not.toHaveBeenCalled()
  })

  it('default idleMs is 250 ms when not specified', () => {
    const onFlush = vi.fn()
    const debounce = useDesignDragDebounce({ onFlush })

    debounce.recordDelta({ x: 50, y: 60 })
    vi.advanceTimersByTime(249)
    expect(onFlush).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(onFlush).toHaveBeenCalledTimes(1)
  })
})