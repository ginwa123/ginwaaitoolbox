import { defineStore } from 'pinia'
import { ref } from 'vue'

const STORAGE_KEY_CHATS_HEIGHT = 'nalar-sidebar-chats-height'
const DEFAULT_CHATS_HEIGHT = 40
const MIN_CHATS_HEIGHT = 10
const MAX_CHATS_HEIGHT = 80

export const useSidebarStore = defineStore('sidebar', () => {
  // Chats section height (percentage of nav area)
  const loadChatsHeight = (): number => {
    const saved = localStorage.getItem(STORAGE_KEY_CHATS_HEIGHT)
    if (saved) {
      const parsed = parseFloat(saved)
      if (!isNaN(parsed) && parsed >= MIN_CHATS_HEIGHT && parsed <= MAX_CHATS_HEIGHT) {
        return parsed
      }
    }
    return DEFAULT_CHATS_HEIGHT
  }

  const chatsHeight = ref(loadChatsHeight())

  const saveChatsHeight = () => {
    localStorage.setItem(STORAGE_KEY_CHATS_HEIGHT, chatsHeight.value.toString())
  }

  const setChatsHeight = (height: number) => {
    chatsHeight.value = Math.max(MIN_CHATS_HEIGHT, Math.min(MAX_CHATS_HEIGHT, height))
    saveChatsHeight()
  }

  return {
    chatsHeight,
    setChatsHeight,
  }
})
