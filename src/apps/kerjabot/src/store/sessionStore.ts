/**
 * Session store with backend integration
 * Manages session state with reactive updates and persists to backend
 */

import { createSignal, createMemo, batch } from 'solid-js';
import type {
  Session,
  SessionSummary,
  CreateSessionParams,
  UpdateSessionParams,
  SessionFilter,
  SessionSort,
  AgentType,
} from '~/types';
import {
  createSession as createSessionType,
  updateSession as updateSessionType,
  SessionSortBy,
  SortDirection,
  SessionStatus,
} from '~/types';
import { chatService } from '~/services/chatService';

// Store state
const [sessions, setSessions] = createSignal<Session[]>([], { equals: false });
const [activeSessionId, setActiveSessionId] = createSignal<string | null>(null);
const [filter, setFilter] = createSignal<SessionFilter>({});
const [sort, setSort] = createSignal<SessionSort>({
  by: SessionSortBy.UpdatedAt,
  direction: SortDirection.Desc,
});
const [isLoading, setIsLoading] = createSignal(false);
const [backendConnected, setBackendConnected] = createSignal(false);

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
const loadSessionsFromBackend = async (): Promise<void> => {
  setIsLoading(true);
  try {
    const result = await chatService.getSessions();
    if (result.sessions && Array.isArray(result.sessions)) {
      // Convert backend sessions to frontend format
      const backendSessions: Session[] = result.sessions.map((s: any) => ({
        id: s.session_id || s.id,
        name: s.name || `Session ${(s.session_id || s.id).slice(0, 8)}`,
        status: mapBackendStatus(s.status),
        agentType: (s.agent_type || 'general') as AgentType,
        messageCount: s.message_count || 0,
        tokenCount: s.token_count || 0,
        createdAt: s.created_at ? new Date(s.created_at) : new Date(),
        updatedAt: s.updated_at ? new Date(s.updated_at) : new Date(),
        metadata: {
          description: s.preview,
          tags: s.tags || [],
        },
      }));
      setSessions(backendSessions);
      setBackendConnected(true);
    }
  } catch (error) {
    console.error('Failed to load sessions from backend:', error);
    setBackendConnected(false);
  } finally {
    setIsLoading(false);
  }
};

const mapBackendStatus = (status?: string): SessionStatus => {
  switch (status) {
    case 'active':
      return SessionStatus.Active;
    case 'idle':
      return SessionStatus.Idle;
    case 'error':
      return SessionStatus.Error;
    default:
      return SessionStatus.Idle;
  }
};

const addSession = async (params?: Partial<CreateSessionParams>): Promise<Session> => {
  const agentType = params?.agentType || 'general';
  
  // Try to create session on backend first
  let sessionId: string;
  try {
    const result = await chatService.createSession(agentType);
    sessionId = result.sessionId;
  } catch (error) {
    // Fallback to local session ID if backend is not available
    console.warn('Backend not available, using local session');
    sessionId = `local_${Date.now()}`;
  }

  const newSession = createSessionType({
    id: sessionId,
    name: params?.name || `New Session`,
    agentType: (agentType as AgentType) || 'general',
    metadata: params?.metadata,
  });

  batch(() => {
    setSessions((prev) => [newSession, ...prev]);
    setActiveSessionId(newSession.id);
    setBackendConnected(true);
  });

  return newSession;
};

const updateSessionById = (id: string, params: UpdateSessionParams): void => {
  setSessions((prev) =>
    prev.map((s) => (s.id === id ? updateSessionType(s, params) : s))
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

const checkBackendConnection = async (): Promise<boolean> => {
  const connected = await chatService.checkBackend();
  setBackendConnected(connected);
  return connected;
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
  isLoading,
  backendConnected,

  // Derived
  loadSessionsFromBackend,
  checkBackendConnection,

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
