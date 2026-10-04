import { watch } from 'vue'
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
 */
export function useDocumentTitle(): void {
  const navigationStore = useNavigationStore()
  const workspacesStore = useWorkspacesStore()
  const currentMainView = useCurrentMainView()

  watch(
    () => ({
      kind: currentMainView.value.kind,
      chatName: navigationStore.activeChatName,
      taskName: workspacesStore.activeTask?.name,
      itemName: workspacesStore.activeWorkspaceItem?.name,
    }),
    ({ kind, chatName, taskName, itemName }) => {
      let name = ''
      if (kind === 'chat') {
        name = chatName
      } else if (kind === 'workspace') {
        name = taskName || itemName || ''
      }
      document.title = name ? `${name} - Pabrik` : BASE_TITLE
    },
    { immediate: true },
  )
}
