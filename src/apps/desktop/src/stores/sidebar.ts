import { defineStore } from 'pinia'
import { ref } from 'vue'

const STORAGE_KEY_CHATS_HEIGHT = 'nalar-sidebar-chats-height'
const STORAGE_KEY_NAV_EXPANDED = 'nalar-sidebar-nav-expanded'
// Legacy key kept ONLY to seed the renamed projects key once, so
// existing users don't get a silently re-collapsed section (revamp
// plan: docs/plans/2026-09-22-revamp-workspace-ui-dropdown-projects.md).
const STORAGE_KEY_LEGACY_WORKSPACES_EXPANDED = 'nalar-sidebar-workspaces-expanded'
const STORAGE_KEY_PROJECTS_EXPANDED = 'nalar-sidebar-projects-expanded'
// Documents section (Migration 095). Separate key from the projects one
// so collapsing Projects does not collapse Documents — they are
// independent lists and the user collapses them independently.
const STORAGE_KEY_DOCUMENTS_EXPANDED = 'nalar-sidebar-documents-expanded'
const STORAGE_KEY_RIGHT_SIDEBAR_WIDTH = 'nalar-right-sidebar-width'
const STORAGE_KEY_SKILLS_GLOBAL = 'nalar-sidebar-skills-global-expanded'
const STORAGE_KEY_SKILLS_LOCAL = 'nalar-sidebar-skills-local-expanded'
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
      if (
        !isNaN(parsed) &&
        parsed >= MIN_RIGHT_SIDEBAR_WIDTH &&
        parsed <= MAX_RIGHT_SIDEBAR_WIDTH
      ) {
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
    rightSidebarWidth.value = Math.max(
      MIN_RIGHT_SIDEBAR_WIDTH,
      Math.min(MAX_RIGHT_SIDEBAR_WIDTH, width),
    )
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

  // Load projects section expanded state — the renamed key first,
  // then the legacy workspaces key as a one-time seed source.
  const loadProjectsExpanded = (): boolean => {
    const saved = localStorage.getItem(STORAGE_KEY_PROJECTS_EXPANDED)
    if (saved !== null) {
      return saved === 'true'
    }
    const legacy = localStorage.getItem(STORAGE_KEY_LEGACY_WORKSPACES_EXPANDED)
    if (legacy !== null) {
      return legacy === 'true'
    }
    return true // Default to expanded
  }

  const navExpanded = ref(loadNavExpanded())
  const projectsExpanded = ref(loadProjectsExpanded())

  // Load documents section expanded state. Default expanded so a fresh
  // install shows the new section's contents, matching the projects and
  // recent sections.
  const loadDocumentsExpanded = (): boolean => {
    const saved = localStorage.getItem(STORAGE_KEY_DOCUMENTS_EXPANDED)
    if (saved !== null) {
      return saved === 'true'
    }
    return true
  }

  const documentsExpanded = ref(loadDocumentsExpanded())

  const saveDocumentsExpanded = () => {
    localStorage.setItem(STORAGE_KEY_DOCUMENTS_EXPANDED, String(documentsExpanded.value))
  }

  const toggleDocumentsExpanded = () => {
    documentsExpanded.value = !documentsExpanded.value
    saveDocumentsExpanded()
  }

  const saveNavExpanded = () => {
    localStorage.setItem(STORAGE_KEY_NAV_EXPANDED, String(navExpanded.value))
  }

  const saveProjectsExpanded = () => {
    localStorage.setItem(STORAGE_KEY_PROJECTS_EXPANDED, String(projectsExpanded.value))
  }

  const toggleNavExpanded = () => {
    navExpanded.value = !navExpanded.value
    saveNavExpanded()
  }

  const toggleProjectsExpanded = () => {
    projectsExpanded.value = !projectsExpanded.value
    saveProjectsExpanded()
  }

  // Load skills section expanded state from localStorage
  const loadSkillsGlobalExpanded = (): boolean => {
    const saved = localStorage.getItem(STORAGE_KEY_SKILLS_GLOBAL)
    if (saved !== null) {
      return saved === 'true'
    }
    return true // Default to expanded
  }

  // Load local skills section expanded state from localStorage
  const loadSkillsLocalExpanded = (): boolean => {
    const saved = localStorage.getItem(STORAGE_KEY_SKILLS_LOCAL)
    if (saved !== null) {
      return saved === 'true'
    }
    return true // Default to expanded
  }

  const skillsGlobalExpanded = ref(loadSkillsGlobalExpanded())
  const skillsLocalExpanded = ref(loadSkillsLocalExpanded())

  const saveSkillsGlobalExpanded = () => {
    localStorage.setItem(STORAGE_KEY_SKILLS_GLOBAL, String(skillsGlobalExpanded.value))
  }

  const saveSkillsLocalExpanded = () => {
    localStorage.setItem(STORAGE_KEY_SKILLS_LOCAL, String(skillsLocalExpanded.value))
  }

  const toggleSkillsGlobalExpanded = () => {
    skillsGlobalExpanded.value = !skillsGlobalExpanded.value
    saveSkillsGlobalExpanded()
  }

  const toggleSkillsLocalExpanded = () => {
    skillsLocalExpanded.value = !skillsLocalExpanded.value
    saveSkillsLocalExpanded()
  }

  return {
    chatsHeight,
    setChatsHeight,
    navExpanded,
    projectsExpanded,
    toggleNavExpanded,
    toggleProjectsExpanded,
    documentsExpanded,
    toggleDocumentsExpanded,
    rightSidebarWidth,
    setRightSidebarWidth,
    skillsGlobalExpanded,
    skillsLocalExpanded,
    toggleSkillsGlobalExpanded,
    toggleSkillsLocalExpanded,
  }
})
