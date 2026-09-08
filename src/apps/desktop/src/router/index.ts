import { createRouter, createWebHistory } from 'vue-router'
import AppLayout from '../components/AppLayout.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/',
      redirect: '/app',
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

export default router
