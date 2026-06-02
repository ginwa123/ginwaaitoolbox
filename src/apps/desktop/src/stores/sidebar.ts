import { defineStore } from 'pinia'
import { ref } from 'vue'

const STORAGE_KEY_CHATS_HEIGHT = 'nalar-sidebar-chats-height'
const STORAGE_KEY_NAV_EXPANDED = 'nalar-sidebar-nav-expanded'
const STORAGE_KEY_WORKSPACES_EXPANDED = 'nalar-sidebar-workspaces-expanded'
const STORAGE_KEY_RIGHT_SIDEBAR_WIDTH = 'nalar-right-sidebar-width'
const DEFAULT_CHATS_HEIGHT = 40
const MIN_CHATS_HEIGHT = 10
const MAX_CHATS_HEIGHT = 80
const DEFAULT_RIGHT_SIDEBAR_WIDTH = 280
const MIN_RIGHT_SIDEBAR_WIDTH = 200
const MAX_RIGHT_SIDEBAR_WIDTH = 600

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

  // Load right sidebar width from localStorage
  const loadRightSidebarWidth = (): number => {
    const saved = localStorage.getItem(STORAGE_KEY_RIGHT_SIDEBAR_WIDTH)
    if (saved) {
      const parsed = parseInt(saved, 10)
      if (!isNaN(parsed) && parsed >= MIN_RIGHT_SIDEBAR_WIDTH && parsed <= MAX_RIGHT_SIDEBAR_WIDTH) {
        return parsed
      }
    }
    return DEFAULT_RIGHT_SIDEBAR_WIDTH
  }

  const rightSidebarWidth = ref(loadRightSidebarWidth())

  const saveRightSidebarWidth = () => {
    localStorage.setItem(STORAGE_KEY_RIGHT_SIDEBAR_WIDTH, rightSidebarWidth.value.toString())
  }

  const setRightSidebarWidth = (width: number) => {
    rightSidebarWidth.value = Math.max(MIN_RIGHT_SIDEBAR_WIDTH, Math.min(MAX_RIGHT_SIDEBAR_WIDTH, width))
    saveRightSidebarWidth()
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
    rightSidebarWidth,
    setRightSidebarWidth,
  }
})
