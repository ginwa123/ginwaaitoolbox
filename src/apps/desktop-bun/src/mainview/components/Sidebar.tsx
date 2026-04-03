import { useNavigate } from '@solidjs/router';
import { type Component, For, createEffect, createSignal, onCleanup, onMount } from 'solid-js';
import { getSessionListVersion } from '../store/sessionStore';
import { baseUrl, initBaseUrl } from '../utils/baseUrl';
import { getSessionDir } from '../utils/config';
import { log } from '../utils/logger';
import { FolderPicker } from './FolderPicker';

// =============================================================================
// Types
// =============================================================================

interface Session {
  session_id: string;
  session_dir: string;
  created_at: string;
  agent: string;
  session_name: string;
}

const Sidebar: Component = () => {
  const [sessions, setSessions] = createSignal<Session[]>([]);
  const [loading, setLoading] = createSignal(true);
  const [expanded, setExpanded] = createSignal(true);
  const [error, setError] = createSignal<string | null>(null);
  const [hasMore, setHasMore] = createSignal(true);
  const [loadingMore, setLoadingMore] = createSignal(false);
  const [nextCursor, setNextCursor] = createSignal<string | null>(null);
  const navigate = useNavigate();
  const sessionListVersion = getSessionListVersion;

  // Folder picker state (modal only - open/close)
  const [folderPickerOpen, setFolderPickerOpen] = createSignal(false);
  // Current session_dir filter (loaded from config)
  const [currentSessionDir, setCurrentSessionDir] = createSignal<string | undefined>(undefined);
  const [configLoaded, setConfigLoaded] = createSignal(false);

  // Refs for DOM elements
  let scrollContainerRef: HTMLDivElement | undefined;
  let sentinelRef: HTMLDivElement | undefined;
  let observer: IntersectionObserver | undefined;
  let initialized = false;

  // Load session directory from config on mount
  createEffect(async () => {
    if (!configLoaded()) {
      try {
        const savedDir = await getSessionDir();
        log.info(`[Sidebar] Loaded session_dir from config: ${savedDir}`);
        const sessionDir = savedDir !== '/' ? savedDir : undefined;
        setCurrentSessionDir(sessionDir);
        // Initial fetch with loaded session_dir
        if (initialized) {
          fetchSessions(undefined, sessionDir);
        }
      } catch (err) {
        log.warn('[Sidebar] Failed to load session_dir from config:', err);
      }
      setConfigLoaded(true);
    }
  });

  // Refresh when session list version changes (new session created) OR folder changes
  createEffect(() => {
    const version = sessionListVersion();
    const sessionDir = currentSessionDir();
    if (!configLoaded()) return; // Wait for config to load first
    log.info(`[Sidebar] Session list version changed: ${version} SessionDir: ${sessionDir}`);
    // Reset and fetch
    setSessions([]);
    setNextCursor(null);
    setHasMore(true);
    fetchSessions(undefined, sessionDir);
  });

  // Callback ref pattern for sentinel - more reliable than let ref
  const setSentinelRef = (el: HTMLDivElement | null) => {
    sentinelRef = el || undefined;
    // Set up observer when sentinel is available
    if (el && observer) {
      observer.observe(el);
    }
  };

  const fetchSessions = async (cursor?: string, sessionDir?: string) => {
    try {
      let url: string;

      if (sessionDir && sessionDir !== '/') {
        // Fetch sessions filtered by session_dir
        url = cursor
          ? `${baseUrl()}/api/session?session_dir=${encodeURIComponent(sessionDir)}&limit=20&cursor=${encodeURIComponent(cursor)}`
          : `${baseUrl()}/api/session?session_dir=${encodeURIComponent(sessionDir)}&limit=20`;
      } else {
        // Fetch all sessions (existing behavior)
        url = cursor
          ? `${baseUrl()}/api/session?limit=20&cursor=${encodeURIComponent(cursor)}`
          : `${baseUrl()}/api/session?limit=20`;
      }

      log.info(`[Sidebar] fetchSessions called - url: ${url} | sessionDir: ${sessionDir}`);

      const res = await fetch(url, {
        method: 'GET',
        headers: { Accept: 'application/json' },
      });

      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const data = (await res.json()) as {
        sessions?: Session[];
        has_more?: boolean;
        next_cursor?: string;
      };

      if (cursor) {
        setSessions((prev) => [...prev, ...(data.sessions || [])]);
      } else {
        setSessions(data.sessions || []);
      }
      setHasMore(data.has_more ?? false);
      setNextCursor(data.next_cursor ?? null);
    } catch (err) {
      log.error(`[Sidebar] Failed to load sessions: ${String(err)}`);
      setError(err instanceof Error ? err.message : String(err));
    }
  };

  const lazyLoadMore = async () => {
    if (!hasMore() || loadingMore() || !nextCursor()) return;
    setLoadingMore(true);
    log.info(`[Sidebar] lazyLoadMore - currentSessionDir: ${currentSessionDir()}`);
    // Pass current session_dir filter for pagination
    await fetchSessions(nextCursor()!, currentSessionDir());
    setLoadingMore(false);
  };

  // Fallback: scroll event listener
  const handleScroll = () => {
    if (!scrollContainerRef || !hasMore() || loadingMore() || !nextCursor()) return;

    const { scrollTop, scrollHeight, clientHeight } = scrollContainerRef;
    const distanceFromBottom = scrollHeight - scrollTop - clientHeight;

    // Trigger when within 100px of bottom
    if (distanceFromBottom < 100) {
      lazyLoadMore();
    }
  };

  onMount(async () => {
    if (!initialized) {
      initBaseUrl();
      initialized = true;
    }

    // Load session_dir from config first
    setLoading(true);
    try {
      const savedDir = await getSessionDir();
      log.info(`[Sidebar] onMount loaded session_dir from config: ${savedDir}`);
      const sessionDir = savedDir !== '/' ? savedDir : undefined;
      setCurrentSessionDir(sessionDir);
      fetchSessions(undefined, sessionDir).finally(() => setLoading(false));
    } catch (err) {
      log.warn('[Sidebar] onMount failed to load session_dir:', err);
      setCurrentSessionDir(undefined);
      fetchSessions(undefined, undefined).finally(() => setLoading(false));
    }

    // Set up IntersectionObserver
    observer = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting) {
          lazyLoadMore();
        }
      },
      {
        root: scrollContainerRef, // scroll container as root
        threshold: 0,
      }
    );

    // Observe sentinel if already available
    if (sentinelRef) {
      observer.observe(sentinelRef);
    }

    onCleanup(() => {
      if (observer) {
        observer.disconnect();
        observer = undefined;
      }
    });
  });

  const formatDate = (dateStr: string) => {
    try {
      const numericDate = Number(dateStr);
      const date = Number.isNaN(numericDate) ? new Date(dateStr) : new Date(numericDate);

      if (Number.isNaN(date.getTime())) {
        return '';
      }

      const now = new Date();
      const diff = now.getTime() - date.getTime();
      const days = Math.floor(diff / (1000 * 60 * 60 * 24));

      if (days === 0) return 'Today';
      if (days === 1) return 'Yesterday';
      if (days < 7) return `${days}d ago`;
      return date.toLocaleDateString();
    } catch {
      return '';
    }
  };

  const getSessionDisplayName = (session: Session) => {
    if (session.session_name?.trim()) {
      return session.session_name;
    }
    const dir = session.session_dir || '';
    const parts = dir.split('/');
    const dirName = parts[parts.length - 1] || '';
    if (dirName) return dirName;
    if (session.session_id) return session.session_id.slice(0, 8);
    return 'Untitled';
  };

  const handleSessionClick = (sessionId: string) => {
    navigate(`/session/${sessionId}`);
  };

  // Just navigate to new session placeholder - session created on first message
  const handleNewSession = () => {
    navigate('/session/new');
  };

  // Handle folder selection
  const handleFolderSelect = async (path: string) => {
    log.info(`[Sidebar] Folder selected: ${path}`);
    const sessionDir = path !== '/' ? path : undefined;
    setCurrentSessionDir(sessionDir);
    setFolderPickerOpen(false);

    // Persist to config
    try {
      const { setSessionDir } = await import('../utils/config');
      await setSessionDir(path);
      log.info(`[Sidebar] Session dir persisted to config: ${path}`);
    } catch (err) {
      log.warn('[Sidebar] Failed to persist session_dir:', err);
    }

    // Reset and refetch sessions
    setSessions([]);
    setNextCursor(null);
    setHasMore(true);
    fetchSessions(undefined, sessionDir);
  };

  return (
    <aside
      class="w-56 flex-shrink-0 bg-[#050505] border-r border-[#18181b] flex flex-col overflow-hidden"
      style="height: 100%;"
    >
      <div class="flex-1 flex flex-col py-3 overflow-hidden">
        <div class="px-4 mb-2 flex items-center justify-between">
          <button
            onClick={() => setExpanded(!expanded())}
            class="flex items-center gap-2 px-2 py-2 text-xs font-mono uppercase tracking-[0.15em] text-[#71717a] hover:text-[#a1a1aa] transition-colors"
          >
            <svg
              class={`w-3 h-3 transition-transform ${expanded() ? 'rotate-90' : ''}`}
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
            >
              <path d="M9 18l6-6-6-6" />
            </svg>
            <span>Sessions</span>
          </button>

          {/* New Session Button - navigates to placeholder, session created on first message */}
          <button
            onClick={handleNewSession}
            class="flex items-center justify-center w-7 h-7 rounded-md bg-[#18181b] hover:bg-[#27272a] border border-[#3f3f46] hover:border-[#fbbf24] text-[#52525b] hover:text-[#fbbf24] transition-all font-mono text-lg font-bold shadow-sm"
            title="New Chat"
          >
            <span class="text-base leading-none">+</span>
          </button>

          {/* Folder Picker Button */}
          <button
            onClick={() => setFolderPickerOpen(true)}
            class="flex items-center justify-center w-7 h-7 rounded-md bg-[#18181b] hover:bg-[#27272a] border border-[#3f3f46] hover:border-[#fbbf24] text-[#52525b] hover:text-[#fbbf24] transition-all font-mono shadow-sm"
            title="Pick Folder"
          >
            <span class="text-base">📁</span>
          </button>
        </div>

        {expanded() && (
          <div
            ref={scrollContainerRef}
            onScroll={handleScroll}
            class="flex-1 px-4 overflow-y-auto sidebar-scroll"
          >
            {loading() ? (
              <div class="py-6 text-[#52525b] text-xs font-mono uppercase tracking-widest text-center">
                Loading...
              </div>
            ) : error() ? (
              <div class="py-4 text-[#ef4444] text-xs font-mono">Error: {error()}</div>
            ) : sessions().length === 0 ? (
              <div class="py-6 text-[#52525b] text-xs font-mono uppercase tracking-widest text-center">
                No sessions
              </div>
            ) : (
              <>
                <For each={sessions()}>
                  {(session) => (
                    <button
                      onClick={() => handleSessionClick(session.session_id)}
                      class="block group w-full text-left py-2"
                    >
                      <div class="px-2 py-2 border-l-2 border-l-transparent hover:border-l-[#fbbf24] transition-colors">
                        <div class="flex items-start gap-2">
                          <div class="w-1.5 h-1.5 bg-[#3f3f46] mt-1.5 group-hover:bg-[#fbbf24] transition-colors flex-shrink-0 rounded-sm" />
                          <div class="min-w-0 flex-1">
                            <div class="text-[#a1a1aa] text-sm font-mono truncate group-hover:text-[#e4e4e7] transition-colors">
                              {getSessionDisplayName(session)}
                            </div>
                            <div class="text-[#52525b] text-xs mt-1 font-mono">
                              {formatDate(session.created_at)}
                            </div>
                          </div>
                        </div>
                      </div>
                    </button>
                  )}
                </For>
                {loadingMore() ? (
                  <div class="py-3 text-[#71717a] text-xs font-mono uppercase tracking-widest text-center animate-pulse">
                    Loading more...
                  </div>
                ) : null}
                <div ref={setSentinelRef} class="h-10 flex-shrink-0" />
              </>
            )}
          </div>
        )}
      </div>

      {/* Folder Picker Modal */}
      <FolderPicker
        isOpen={folderPickerOpen()}
        initialPath={currentSessionDir() ?? '/'}
        onSelect={handleFolderSelect}
        onClose={() => setFolderPickerOpen(false)}
      />
    </aside>
  );
};

export default Sidebar;
