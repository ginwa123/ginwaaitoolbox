import { defineStore } from 'pinia'
import { ref } from 'vue'

const STORAGE_KEY_CHATS_HEIGHT = 'nalar-sidebar-chats-height'
const STORAGE_KEY_NAV_EXPANDED = 'nalar-sidebar-nav-expanded'
const STORAGE_KEY_WORKSPACES_EXPANDED = 'nalar-sidebar-workspaces-expanded'
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

  // Load nav section expanded state from localStorage
  const loadNavExpanded = (): boolean => {
    const saved = localStorage.getItem(STORAGE_KEY_NAV_EXPANDED)
    if (saved !== null) {
      return saved === 'true'
    }
    return true // Default to expanded
  }

  // Load workspaces section expanded state from localStorage
  const loadWorkspacesExpanded = (): boolean => {
    const saved = localStorage.getItem(STORAGE_KEY_WORKSPACES_EXPANDED)
    if (saved !== null) {
      return saved === 'true'
    }
    return true // Default to expanded
  }

  const navExpanded = ref(loadNavExpanded())
  const workspacesExpanded = ref(loadWorkspacesExpanded())

  const saveNavExpanded = () => {
    localStorage.setItem(STORAGE_KEY_NAV_EXPANDED, String(navExpanded.value))
  }

  const saveWorkspacesExpanded = () => {
    localStorage.setItem(STORAGE_KEY_WORKSPACES_EXPANDED, String(workspacesExpanded.value))
  }

  const toggleNavExpanded = () => {
    navExpanded.value = !navExpanded.value
    saveNavExpanded()
  }

  const toggleWorkspacesExpanded = () => {
    workspacesExpanded.value = !workspacesExpanded.value
    saveWorkspacesExpanded()
  }

  return {
    chatsHeight,
    setChatsHeight,
    navExpanded,
    workspacesExpanded,
    toggleNavExpanded,
    toggleWorkspacesExpanded,
  }
})
