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
  ],
})

export default router
