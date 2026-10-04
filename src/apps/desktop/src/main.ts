import { createApp } from 'vue'
import { createPinia } from 'pinia'
import piniaPluginPersistedstate from 'pinia-plugin-persistedstate'

import App from './App.vue'
import router from './router'
import './style.css'

import { installFrontendLogClient, type FrontendLogContext } from './helpers/frontendLogClient'
import { API_BASE } from './api'

const app = createApp(App)

const pinia = createPinia()
pinia.use(piniaPluginPersistedstate)

app.use(pinia)
app.use(router)

// Install the frontend error-log client BEFORE app.mount so the global
// `window.error` / `unhandledrejection` / console.error / console.warn
// listeners are wired up before any component can throw. App.vue
// re-wires the context callbacks (route + session) once Vue router is
// alive. See docs/plans/2026-07-17-frontend-error-logs-design.md.
const logCtx: FrontendLogContext = {
  getRoutePath: () => null,
  getSessionId: () => null,
}
;(window as unknown as { __pabrikLogCtx: FrontendLogContext }).__pabrikLogCtx = logCtx
installFrontendLogClient({
  endpoint: `${API_BASE}/logs`,
  getContext: () => logCtx,
})

app.mount('#app')