// Pinia store for workspace-scoped documents (Migration 095).
//
// Two things this store deliberately does NOT do:
//
//  1. No client-side workspace filter. The backend scopes every read by
//     the `workspace_id` in the path, so a document from another
//     workspace is never in the response to filter out. Adding a
//     `documents.filter(d => d.workspace_id === id)` guard here would be
//     a second, weaker copy of a rule that already lives in SQL — and the
//     kind of duplicate that drifts.
//  2. No local `isActive` flag. Which document is open is derived from the
//     URL (`?doc=<id>`), so a refresh, a Back/Forward, or a shared link
//     all restore the same view. Same reasoning as
//     `ChatsList.isCurrentChat`.
//
// `try`/`catch` appears in the actions and nowhere else: this is the
// sanctioned seam for a fallible operation, and each one records the
// failure in `error` so the component can render it. A catch that
// returned an empty list with no error would be the exact bug the
// "No try/catch in the desktop app" rule exists to prevent — "no
// documents" and "could not load documents" would look identical.

import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import * as api from '../api'
import type { Document } from '../api'

export const useDocumentsStore = defineStore('documents', () => {
  const documents = ref<Document[]>([])
  const loading = ref(false)
  const saving = ref(false)
  /** Last failure message, or null. Rendered by the view — never write-only. */
  const error = ref<string | null>(null)
  /**
   * True once a list has been fetched for SOME workspace. Distinguishes
   * "not loaded yet" (render nothing) from "loaded, and there are none"
   * (render the empty state) — without it a fresh sidebar shows a
   * misleading "No documents yet" before the first request returns.
   */
  const loaded = ref(false)

  const count = computed(() => documents.value.length)

  const findById = (id: string): Document | null => documents.value.find((d) => d.id === id) ?? null

  const toMessage = (e: unknown): string => (e instanceof Error ? e.message : String(e))

  async function fetchDocuments(workspaceId: string): Promise<void> {
    if (!workspaceId) return
    loading.value = true
    error.value = null
    try {
      const data = await api.listDocuments(workspaceId)
      documents.value = data.documents
      loaded.value = true
    } catch (e) {
      // Deliberately does NOT clear `documents`. A failed refresh must
      // not blank a list the user is reading; it leaves the last good
      // data on screen and surfaces the failure.
      error.value = toMessage(e)
    } finally {
      loading.value = false
    }
  }

  async function createDocument(
    workspaceId: string,
    title: string,
    content = '',
  ): Promise<Document | null> {
    if (!workspaceId) return null
    saving.value = true
    error.value = null
    try {
      const { document } = await api.createDocument(workspaceId, title, content)
      // Prepend rather than refetch: the list is ordered by
      // updated_at DESC and a brand-new document is the most recent.
      // Saves a round-trip on the click that created it.
      documents.value = [document, ...documents.value]
      loaded.value = true
      return document
    } catch (e) {
      error.value = toMessage(e)
      return null
    } finally {
      saving.value = false
    }
  }

  async function updateDocument(
    workspaceId: string,
    documentId: string,
    patch: { title?: string; content?: string },
  ): Promise<Document | null> {
    if (!workspaceId) return null
    saving.value = true
    error.value = null
    try {
      const { document } = await api.updateDocument(workspaceId, documentId, patch)
      documents.value = documents.value.map((d) => (d.id === document.id ? document : d))
      return document
    } catch (e) {
      error.value = toMessage(e)
      return null
    } finally {
      saving.value = false
    }
  }

  async function deleteDocument(workspaceId: string, documentId: string): Promise<boolean> {
    if (!workspaceId) return false
    saving.value = true
    error.value = null
    try {
      await api.deleteDocument(workspaceId, documentId)
      documents.value = documents.value.filter((d) => d.id !== documentId)
      return true
    } catch (e) {
      error.value = toMessage(e)
      return false
    } finally {
      saving.value = false
    }
  }

  /**
   * Fetch a single document for the editor. The list response already
   * carries every body, so this is a no-op when the row is cached and
   * only reaches the network for a deep link opened before the sidebar
   * list loaded.
   */
  async function loadDocument(workspaceId: string, documentId: string): Promise<Document | null> {
    if (!workspaceId || !documentId) return null
    error.value = null
    const cached = findById(documentId)
    if (cached) return cached
    try {
      const { document } = await api.getDocument(workspaceId, documentId)
      return document
    } catch (e) {
      error.value = toMessage(e)
      return null
    }
  }

  /** Called on workspace switch so a stale list is never shown under a new header. */
  function reset(): void {
    documents.value = []
    error.value = null
    loaded.value = false
    loading.value = false
    saving.value = false
  }

  return {
    documents,
    loading,
    saving,
    error,
    loaded,
    count,
    findById,
    fetchDocuments,
    createDocument,
    updateDocument,
    deleteDocument,
    loadDocument,
    reset,
  }
})
