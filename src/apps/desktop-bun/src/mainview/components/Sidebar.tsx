import { useNavigate } from '@solidjs/router';
import { type Component, For, createSignal, onCleanup, onMount } from 'solid-js';
import { baseUrl, initBaseUrl } from '../utils/baseUrl';

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
  let sentinelRef: HTMLDivElement | undefined;
  let initialized = false;

  const fetchSessions = async (cursor?: string) => {
    try {
      const url = cursor
        ? `${baseUrl()}/api/session?limit=20&cursor=${encodeURIComponent(cursor)}`
        : `${baseUrl()}/api/session?limit=20`;

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
      console.error('Failed to load sessions:', err);
      setError(err instanceof Error ? err.message : String(err));
    }
  };

  const lazyLoadMore = async () => {
    if (!hasMore() || loadingMore() || !nextCursor()) return;
    setLoadingMore(true);
    await fetchSessions(nextCursor()!);
    setLoadingMore(false);
  };

  onMount(() => {
    if (!initialized) {
      initBaseUrl();
      initialized = true;
    }

    setLoading(true);
    fetchSessions().finally(() => setLoading(false));

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries[0].isIntersecting) {
          lazyLoadMore();
        }
      },
      { threshold: 0.1, rootMargin: '100px' }
    );

    if (sentinelRef) {
      observer.observe(sentinelRef);
    }

    onCleanup(() => observer.disconnect());
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

  return (
    <aside class="w-56 h-full bg-[#050505] border-r border-[#18181b] flex flex-col flex-shrink-0">
      <nav class="flex-1 h-full py-4 flex flex-col">
        <div class="mt-4 px-4 flex-1 flex flex-col min-h-0">
          <button
            onClick={() => setExpanded(!expanded())}
            class="flex items-center justify-between w-full px-2 py-1.5 text-[10px] font-mono uppercase tracking-[0.2em] text-[#52525b] hover:text-[#71717a] transition-colors"
          >
            <span>Sessions</span>
            <svg
              class={`w-2.5 h-2.5 transition-transform ${expanded() ? 'rotate-90' : ''}`}
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
            >
              <path d="M9 18l6-6-6-6" />
            </svg>
          </button>

          {expanded() && (
            <div class="flex-1 min-h-0 overflow-y-auto mt-2 space-y-0">
              {loading() ? (
                <div class="px-2 py-4 text-[#3f3f46] text-[10px] font-mono uppercase tracking-widest text-center">
                  Loading...
                </div>
              ) : error() ? (
                <div class="px-2 py-3 text-[#ef4444] text-[10px] font-mono">Error: {error()}</div>
              ) : sessions().length === 0 ? (
                <div class="px-2 py-4 text-[#3f3f46] text-[10px] font-mono uppercase tracking-widest text-center">
                  No sessions
                </div>
              ) : (
                <>
                  <For each={sessions()}>
                    {(session) => (
                      <button
                        onClick={() => handleSessionClick(session.session_id)}
                        class="block group w-full text-left"
                      >
                        <div class="px-2 py-3 border-l-2 border-l-transparent hover:border-l-[#fbbf24] transition-colors">
                          <div class="flex items-start gap-2">
                            <div class="w-1 h-1 bg-[#27272a] mt-1.5 group-hover:bg-[#fbbf24] transition-colors flex-shrink-0" />
                            <div class="min-w-0 flex-1">
                              <div class="text-[#71717a] text-[11px] font-mono truncate group-hover:text-[#e4e4e7] transition-colors">
                                {getSessionDisplayName(session)}
                              </div>
                              <div class="text-[#3f3f46] text-[10px] mt-0.5 font-mono uppercase tracking-wider">
                                {formatDate(session.created_at)}
                              </div>
                            </div>
                          </div>
                        </div>
                      </button>
                    )}
                  </For>
                  <div ref={sentinelRef} class="h-1 flex-shrink-0" />
                </>
              )}
            </div>
          )}
        </div>
      </nav>
    </aside>
  );
};

export default Sidebar;
