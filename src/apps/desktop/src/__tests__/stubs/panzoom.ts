/**
 * Stub for the `panzoom` package. The real package is installed
 * (`bun add panzoom`), but its module body sets up DOM event
 * handlers and tries to read `getBoundingClientRect()` patterns
 * that don't make sense in jsdom. Vite's `import-analysis` runs
 * at file-transform time, BEFORE vi.mock can intercept, so we
 * alias the bare specifier to this stub in `vitest.config.ts`.
 *
 * The DesignView is stubbed at mount-time (or the design view's
 * own static-contract tests just check the source code), so the
 * panzoom controller is never actually called in tests. The stub
 * exposes a fake `PanZoom` controller whose methods are no-ops —
 * that way any unmocked test path that escapes the stub layer
 * still doesn't crash.
 *
 * If a future maintainer needs to drive panzoom behavior in
 * tests, they should use `vi.mock('panzoom', ...)` ON TOP OF this
 * alias (the alias satisfies import-analysis; `vi.mock` then
 * overrides the stub for the modules that DO get evaluated).
 */

// Mirrors the signature of the real `createPanZoom` (the default
// export of the `panzoom` package). The return value is a
// `PanZoom` instance — all its methods are no-ops so test code
// that accidentally calls them never crashes. The `.dispose()`
// method is real (returns void).
const fakePanZoom = {
  dispose: () => {},
  moveBy: (_dx: number, _dy: number, _smooth: boolean) => {},
  moveTo: (_x: number, _y: number) => {},
  smoothMoveTo: (_x: number, _y: number) => {},
  centerOn: (_ui: unknown) => {},
  zoomTo: (_cx: number, _cy: number, _k: number) => {},
  zoomAbs: (_cx: number, _cy: number, _z: number) => {},
  smoothZoom: (_cx: number, _cy: number, _k: number) => {},
  smoothZoomAbs: (_cx: number, _cy: number, _z: number) => {},
  getTransform: () => ({ x: 0, y: 0, scale: 1 }),
  showRectangle: (_rect: unknown) => {},
  pause: () => {},
  resume: () => {},
  isPaused: () => false,
  on: <T>(_name: string, _h: (e: T) => void) => {},
  off: (_name: string, _h: (...args: unknown[]) => void) => {},
  fire: (_name: string) => {},
  getMinZoom: () => 0,
  setMinZoom: (_z: number) => 0,
  getMaxZoom: () => 10,
  setMaxZoom: (_z: number) => 10,
  getTransformOrigin: () => ({ x: 0, y: 0 }),
  setTransformOrigin: (_o: { x: number; y: number }) => {},
  getZoomSpeed: () => 1,
  setZoomSpeed: (_z: number) => {},
}

export default function createPanZoom(
  _domElement: HTMLElement | SVGElement,
  _options?: unknown,
): typeof fakePanZoom {
  return fakePanZoom
}
