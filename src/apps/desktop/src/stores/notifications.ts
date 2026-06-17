import { defineStore } from 'pinia'
import { ref } from 'vue'

export interface Notification {
  id: string
  message: string
  details?: string
  createdAt: number
}

const AUTO_DISMISS_MS = 5000

export const useNotificationStore = defineStore('notifications', () => {
  const notifications = ref<Notification[]>([])
  let counter = 0

  function notifyError(message: string, details?: string) {
    counter += 1
    const id = `n_${Date.now()}_${counter}`
    notifications.value.push({ id, message, details, createdAt: Date.now() })
    setTimeout(() => dismiss(id), AUTO_DISMISS_MS)
  }

  function dismiss(id: string) {
    const i = notifications.value.findIndex(n => n.id === id)
    if (i !== -1) notifications.value.splice(i, 1)
  }

  function dismissAll() {
    notifications.value = []
  }

  return { notifications, notifyError, dismiss, dismissAll }
})