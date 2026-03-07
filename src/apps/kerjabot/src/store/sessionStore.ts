/**
 * Session store using SolidJS signals
 * Manages session state with reactive updates
 */

import { createSignal, createMemo, batch } from 'solid-js';
import type {
  Session,
  SessionSummary,
  CreateSessionParams,
  UpdateSessionParams,
  SessionFilter,
  SessionSort,
} from '~/types';
import {
  createSession,
  updateSession,
  SessionSortBy,
  SortDirection,
} from '~/types';

// Store state
const [sessions, setSessions] = createSignal<Session[]>([], { equals: false });
const [activeSessionId, setActiveSessionId] = createSignal<string | null>(null);
const [filter, setFilter] = createSignal<SessionFilter>({});
const [sort, setSort] = createSignal<SessionSort>({
  by: SessionSortBy.UpdatedAt,
  direction: SortDirection.Desc,
});

// Derived state
const filteredSessions = createMemo(() => {
  const currentFilter = filter();
  let result = sessions();

  if (currentFilter.status) {
    result = result.filter((s) => s.status === currentFilter.status);
  }

  if (currentFilter.agentType) {
    result = result.filter((s) => s.agentType === currentFilter.agentType);
  }

  if (currentFilter.searchQuery) {
    const query = currentFilter.searchQuery.toLowerCase();
    result = result.filter(
      (s) =>
        s.name.toLowerCase().includes(query) ||
        s.metadata?.description?.toLowerCase().includes(query)
    );
  }

  if (currentFilter.tags && currentFilter.tags.length > 0) {
    result = result.filter((s) =>
      currentFilter.tags!.some((tag) => s.metadata?.tags?.includes(tag))
    );
  }

  return result;
});

const sortedSessions = createMemo(() => {
  const currentSort = sort();
  const toSort = [...filteredSessions()];

  toSort.sort((a, b) => {
    let comparison = 0;

    switch (currentSort.by) {
      case SessionSortBy.Name:
        comparison = a.name.localeCompare(b.name);
        break;
      case SessionSortBy.CreatedAt:
        comparison = a.createdAt.getTime() - b.createdAt.getTime();
        break;
      case SessionSortBy.UpdatedAt:
        comparison = a.updatedAt.getTime() - b.updatedAt.getTime();
        break;
      case SessionSortBy.MessageCount:
        comparison = a.messageCount - b.messageCount;
        break;
    }

    return currentSort.direction === SortDirection.Asc ? comparison : -comparison;
  });

  return toSort;
});

const sessionSummaries = createMemo<SessionSummary[]>(() => {
  return sortedSessions().map((session) => ({
    id: session.id,
    name: session.name,
    status: session.status,
    agentType: session.agentType,
    messageCount: session.messageCount,
    lastMessageAt: session.updatedAt,
    preview: session.metadata?.description,
  }));
});

const activeSession = createMemo(() => {
  const id = activeSessionId();
  if (!id) return null;
  return sessions().find((s) => s.id === id) ?? null;
});

// Actions
const addSession = (params: CreateSessionParams): Session => {
  const newSession = createSession(params);
  batch(() => {
    setSessions((prev) => [newSession, ...prev]);
    setActiveSessionId(newSession.id);
  });
  return newSession;
};

const updateSessionById = (id: string, params: UpdateSessionParams): void => {
  setSessions((prev) =>
    prev.map((s) => (s.id === id ? updateSession(s, params) : s))
  );
};

const removeSession = (id: string): void => {
  batch(() => {
    setSessions((prev) => prev.filter((s) => s.id !== id));
    if (activeSessionId() === id) {
      const remaining = sessions().filter((s) => s.id !== id);
      setActiveSessionId(remaining.length > 0 ? remaining[0].id : null);
    }
  });
};

const selectSession = (id: string | null): void => {
  setActiveSessionId(id);
};

const incrementMessageCount = (id: string): void => {
  setSessions((prev) =>
    prev.map((s) =>
      s.id === id
        ? { ...s, messageCount: s.messageCount + 1, updatedAt: new Date() }
        : s
    )
  );
};

const updateTokenCount = (id: string, tokens: number): void => {
  setSessions((prev) =>
    prev.map((s) =>
      s.id === id ? { ...s, tokenCount: s.tokenCount + tokens } : s
    )
  );
};

// Export store API
export const sessionStore = {
  // State
  sessions,
  activeSessionId,
  activeSession,
  filter,
  sort,
  filteredSessions,
  sortedSessions,
  sessionSummaries,

  // Actions
  setFilter,
  setSort,
  addSession,
  updateSessionById,
  removeSession,
  selectSession,
  incrementMessageCount,
  updateTokenCount,
};
