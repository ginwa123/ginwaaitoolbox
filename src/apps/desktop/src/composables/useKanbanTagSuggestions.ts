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
  const offset = ref(0)
  let inFlight = false

  async function fetchPage(targetOffset: number): Promise<void> {
    if (inFlight) return
    inFlight = true
    loading.value = true
    try {
      const page = await getKanbanTagSuggestions(workspaceId, itemId, {
        limit,
        offset: targetOffset,
      })
      tags.value = [...tags.value, ...page.tags]
      hasMore.value = page.has_more
      loaded.value = true
      offset.value = targetOffset + limit
    } catch {
      hasMore.value = false
    } finally {
      loading.value = false
      inFlight = false
    }
  }

  async function ensureLoaded(): Promise<void> {
    if (loaded.value) return
    await fetchPage(0)
  }

  async function loadNextPage(): Promise<void> {
    if (!hasMore.value || inFlight) return
    await fetchPage(offset.value)
  }

  function reset(): void {
    tags.value = []
    hasMore.value = false
    loading.value = false
    loaded.value = false
    offset.value = 0
  }

  return { tags, hasMore, loading, loaded, ensureLoaded, loadNextPage, reset }
}
