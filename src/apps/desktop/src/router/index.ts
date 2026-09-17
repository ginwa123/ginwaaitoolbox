import { createRouter, createWebHistory } from 'vue-router'
import AppLayout from '../components/AppLayout.vue'
import LoginView from '../views/LoginView.vue'
import { useLoadingStore } from '../stores/loading'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/',
      redirect: '/app',
    },
    {
      path: '/login',
      name: 'login',
      component: LoginView,
      meta: { public: true },
    },
    {
      path: '/app',
      name: 'app',
      component: AppLayout,
    },
    {
      path: '/app/settings',
      name: 'settings',
      component: AppLayout,
    },
    // Catch-all route for chat links with session ID
    {
      path: '/app/chat/:sessionId',
      name: 'chat',
      component: AppLayout,
    },
    // Catch-all route for task links with task ID
    {
      path: '/app/task/:taskId',
      name: 'task',
      component: AppLayout,
    },
    // Kanban settings page (plan: 2026-09-02-kanban-settings-as-page).
    // Resolves to AppLayout which dispatches via the `currentView`
    // computed (path-based regex match at AppLayout.vue). The `name`
    // is informational — we navigate by path from
    // AppLayout.handleOpenKanbanSettings via `router.push`.
    {
      path: '/app/kanban/:itemId/settings',
      name: 'kanban-settings',
      component: AppLayout,
    },
    // Global catch-all: any path the backend's SPA fallback serves
    // index.html for but no route above matches (stale deep link,
    // refresh at a removed URL) lands on /app instead of rendering
    // an empty router-view. Must stay LAST — Vue matches in order.
    {
      path: '/:pathMatch(.*)*',
      redirect: '/app',
    },
  ],
})

// Auth guard: when the backend runs with `--auth`, every `/app*`
// view requires a valid `nalar_session` cookie. Anonymous visits
// redirect to `/login?redirect=<target>` (router.replace, so Back
// skips the bounce); authed visits to `/login` bounce back to the
// target. Public when auth is off (`/api/auth/me` 200 +
// auth_enabled=false) — no redirect. Every view switch stays in the
// URL (repo rule), so refresh/Back/shared links keep working.
//
// The top loading bar is driven here: start on beforeEach (covers the
// async auth check, which is the slowest part of a redirect), finish
// on afterEach/onError. Lazily resolved inside the guard so the router
// module never hard-depends on an installed pinia (specs import the
// router without one).
function loadingStore() {
  try {
    return useLoadingStore()
  } catch {
    return null
  }
}

router.beforeEach(async (to) => {
  loadingStore()?.startRoute()
  if (to.meta.public) {
    // Leaving /login while authed? Bounce to the redirect target.
    if (to.name === 'login') {
      try {
        const res = await fetch('/api/auth/me', { credentials: 'same-origin' })
        if (res.ok) {
          const data = await res.json().catch(() => null)
          if (data && data.authenticated === true) {
            const r = to.query.redirect
            const target = typeof r === 'string' && r.startsWith('/') ? r : '/app'
            return { path: target, replace: true }
          }
        }
      } catch {
        /* offline — show login */
      }
    }
    return true
  }
  try {
    const res = await fetch('/api/auth/me', { credentials: 'same-origin' })
    if (res.ok) {
      const data = await res.json().catch(() => null)
      // Auth disabled on server → open access, no redirect.
      if (data && data.auth_enabled === false) return true
      if (data && data.authenticated === true) return true
    }
    if (res.status === 401) {
      return { path: '/login', query: { redirect: to.fullPath }, replace: true }
    }
    // Non-401 error (offline/500): let the view render; apiFetch
    // toasts will surface the failure. Avoids login-loop on outage.
    return true
  } catch {
    return true
  }
})

router.afterEach(() => {
  loadingStore()?.finishRoute()
})

router.onError(() => {
  loadingStore()?.finishRoute()
})

export default router
