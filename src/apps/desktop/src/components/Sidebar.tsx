import { createSignal, onMount, For, type Component } from "solid-js";
import { useNavigate } from "@solidjs/router";

interface Session {
  session_id: string;
  session_dir: string;
  created_at: string;
  agent: string;
  session_name: string;
}

// Helper to get base URL - both dev and prod use the backend API at 8080
const getBaseUrl = () => {
  return "http://127.0.0.1:8080";
};

const Sidebar: Component = () => {
  const [sessions, setSessions] = createSignal<Session[]>([]);
  const [loading, setLoading] = createSignal(true);
  const [expanded, setExpanded] = createSignal(true);
  const [error, setError] = createSignal<string | null>(null);
  const navigate = useNavigate();

  onMount(async () => {
    try {
      const baseUrl = getBaseUrl();
      console.log("Fetching sessions from:", `${baseUrl}/api/session?limit=50&offset=0`);
      
      const res = await fetch(`${baseUrl}/api/session?limit=50&offset=0`, {
        method: "GET",
        headers: {
          "Accept": "application/json",
        },
      });
      
      console.log("Response status:", res.status);
      console.log("Response headers:", Object.fromEntries(res.headers.entries()));
      
      const text = await res.text();
      console.log("Response text:", text.substring(0, 500));
      
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}: ${text}`);
      }
      
      const data = JSON.parse(text) as { sessions?: Session[] };
      setSessions(data.sessions || []);
    } catch (err) {
      console.error("Failed to load sessions:", err);
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  });

  const formatDate = (dateStr: string) => {
    try {
      // Handle Unix timestamp in milliseconds (from Zig std.time.milliTimestamp())
      const numericDate = Number(dateStr);
      const date = isNaN(numericDate) 
        ? new Date(dateStr) 
        : new Date(numericDate);
      
      // Check for invalid date
      if (isNaN(date.getTime())) {
        return "";
      }
      
      const now = new Date();
      const diff = now.getTime() - date.getTime();
      const days = Math.floor(diff / (1000 * 60 * 60 * 24));
      
      if (days === 0) return "Today";
      if (days === 1) return "Yesterday";
      if (days < 7) return `${days} days ago`;
      return date.toLocaleDateString();
    } catch {
      return "";
    }
  };

  const getSessionDisplayName = (session: Session) => {
    if (session.session_name && session.session_name.trim()) {
      return session.session_name;
    }
    const dir = session.session_dir || "";
    const parts = dir.split("/");
    return parts[parts.length - 1] || session.session_id.slice(0, 8);
  };

  const handleSessionClick = (sessionId: string) => {
    navigate(`/session/${sessionId}`);
  };

  return (
    <aside class="w-64 bg-[#0a0a0a] border-r border-[#2a2a2a] flex flex-col">
      <nav class="flex-1 py-6 flex flex-col">
        {/* Sessions Section */}
        <div class="mt-8 px-4 flex-1 overflow-hidden flex flex-col">
          <button
            onClick={() => setExpanded(!expanded())}
            class="flex items-center justify-between w-full px-3 py-2 text-xs font-mono uppercase tracking-wider text-[#525252] hover:text-[#737373] transition-colors"
          >
            <span>Sessions</span>
            <svg
              class={`w-3 h-3 transition-transform ${expanded() ? "rotate-90" : ""}`}
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
            >
              <path d="M9 18l6-6-6-6" />
            </svg>
          </button>
          
          {expanded() && (
            <div class="flex-1 overflow-y-auto mt-2 space-y-1">
              {loading() ? (
                <div class="px-3 py-6 text-[#525252] text-xs font-mono text-center">
                  Loading...
                </div>
              ) : error() ? (
                <div class="px-3 py-3 text-[#ef4444] text-xs font-mono">
                  Error: {error()}
                </div>
              ) : sessions().length === 0 ? (
                <div class="px-3 py-6 text-[#525252] text-xs font-mono text-center">
                  No sessions
                </div>
              ) : (
                <For each={sessions()}>
                  {(session) => (
                    <button
                      onClick={() => handleSessionClick(session.session_id)}
                      class="block group w-full text-left"
                    >
                      <div class="px-3 py-3 rounded-lg hover:bg-[#141414] transition-colors">
                        <div class="flex items-start gap-3">
                          <div class="w-2 h-2 rounded-full bg-[#262626] mt-1.5 group-hover:bg-[#facc15] transition-colors flex-shrink-0" />
                          <div class="min-w-0 flex-1">
                            <div class="text-[#a3a3a3] text-sm font-mono truncate group-hover:text-[#e5e5e5] transition-colors">
                              {getSessionDisplayName(session)}
                            </div>
                            <div class="text-[#404040] text-xs mt-1">
                              {formatDate(session.created_at)}
                            </div>
                          </div>
                        </div>
                      </div>
                    </button>
                  )}
                </For>
              )}
            </div>
          )}
        </div>
      </nav>
    </aside>
  );
};

export default Sidebar;
