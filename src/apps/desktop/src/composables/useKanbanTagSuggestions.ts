/**
 * Lazy-load + paginated tag suggestions for a kanban.
 *
 * Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md
 *
 * Lifecycle:
 *   - `ensureLoaded()` — fetches the first page if not yet loaded.
 *   - `loadNextPage()` — fetches the next page (appends to internal list).
 *   - `reset()` — clears the internal list (used when the dialog closes).
 *
 * The fetched list is exposed as readonly `tags`. `hasMore` and
 * `loading` are exposed for UI to render a "Loading more..." indicator.
 *
 * The composable does NOT trigger fetches automatically — the caller
 * (KanbanTagsInput) is responsible for calling `ensureLoaded()` on
 * focus and `loadNextPage()` from an IntersectionObserver on the
 * scroll sentinel. This keeps the composable testable and the
 * "when to fetch" logic in the component.
 */
import { ref, type Ref } from 'vue'
import { getKanbanTagSuggestions, type KanbanTagSuggestion } from '../api'

export interface UseKanbanTagSuggestionsOptions {
  limit?: number
}

export function useKanbanTagSuggestions(
  workspaceId: string,
  itemId: string,
  options?: UseKanbanTagSuggestionsOptions,
) {
  const limit = options?.limit ?? 8
  const tags: Ref<KanbanTagSuggestion[]> = ref([])
  const hasMore = ref(false)
  const loading = ref(false)
  const loaded = ref(false)

  async function ensureLoaded(): Promise<void> {
    // Stub.
  }

  async function loadNextPage(): Promise<void> {
    // Stub.
  }

  function reset(): void {
    tags.value = []
    hasMore.value = false
    loading.value = false
    loaded.value = false
  }

  return { tags, hasMore, loading, loaded, ensureLoaded, loadNextPage, reset }
}
