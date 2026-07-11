/// <reference types="vite/client" />

// Module shim so vue-tsc (TypeScript with the Vue language plugin) can
// resolve `import Foo from './Foo.vue'` even when the importing project
// (e.g. tsconfig.vitest.json) doesn't include the .vue file in its
// `include`. Without this, vue-tsc 3.x emits TS2307 "Cannot find
// module ... .vue" for every spec that imports an SFC. The actual SFC
// shape comes through Vite at runtime; this shim only satisfies the
// type-checker.
//
// Using `any` for the default export lets tests treat the component
// flexibly (mount with arbitrary props, use as a generic). For named
// exports from <script setup>, we re-export `* as` so any name resolves.
// This is intentionally permissive — the spec files are tests, not
// type-strict app code.
declare module '*.vue' {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const component: any
  export default component
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  export const __vueAnyNamedExport: any
}