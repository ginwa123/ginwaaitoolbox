import { useRouter } from 'vue-router'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore } from '../stores/workspaces'
import { useCurrentMainView } from './useCurrentMainView'

const BASE_TITLE = 'Pabrik'

/**
 * Keep the browser tab title in sync with what the main content area
 * is showing: the active session name for chats, the active task (or
 * item) name for workspace views, plain "Pabrik" everywhere else.
 *
 * Source of truth for *what* is showing is `useCurrentMainView`
 * (URL-driven, never store flags that can drift); the *names* come
 * from the navigation / workspaces stores, which the sidebar flows
 * already keep up to date (setActiveChatName, SSE rename fan-out).
 *
 * Refresh triggers (no reactive watcher): the Pinia `$subscribe`
 * hooks below fire on every store mutation (chat renames, task/item
 * switches), and `router.afterEach` covers pure URL changes where
 * the stores are untouched. Both are explicit subscriptions owned
 * for the app lifetime.
 */
export function useDocumentTitle(): void {
  const navigationStore = useNavigationStore()
  const workspacesStore = useWorkspacesStore()
  const currentMainView = useCurrentMainView()

  const updateTitle = () => {
    const { kind } = currentMainView.value
    const chatName = navigationStore.activeChatName
    const taskName = workspacesStore.activeTask?.name
    const itemName = workspacesStore.activeWorkspaceItem?.name
    let name = ''
    if (kind === 'chat') {
      name = chatName
    } else if (kind === 'workspace') {
      name = taskName || itemName || ''
    }
    document.title = name ? `${name} - Pabrik` : BASE_TITLE
  }

  updateTitle()
  navigationStore.$subscribe(() => updateTitle())
  workspacesStore.$subscribe(() => updateTitle())
  try {
    // Pure URL changes (e.g. Back/Forward between views whose names are
    // already in the stores) don't mutate any store — catch those here.
    // No router in unit mounts: the store subscriptions above suffice.
    useRouter().afterEach(() => updateTitle())
  } catch {
    // Router absent — nothing to sync.
  }
}
