import { useTitle } from '@vueuse/core'
import { computed } from 'vue'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore } from '../stores/workspaces'
import { useCurrentMainView } from './useCurrentMainView'

const BASE_TITLE = 'Nalar'

/**
 * Keep the browser tab title in sync with what the main content area
 * is showing: the active session name for chats, the active task (or
 * item) name for workspace views, plain "Nalar" everywhere else.
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

  const name = computed(() => {
    const kind = currentMainView.value.kind
    if (kind === 'chat') return navigationStore.activeChatName
    if (kind === 'workspace') {
      return workspacesStore.activeTask?.name || workspacesStore.activeWorkspaceItem?.name || ''
    }
    return ''
  })

  // `restoreOnUnmount: false` keeps the previous contract: the title is
  // only ever pushed on change, never snapped back when the owner unmounts
  // (AppLayout remounts on every route change).
  useTitle(() => (name.value ? `${name.value} - Nalar` : BASE_TITLE), { restoreOnUnmount: false })
}
