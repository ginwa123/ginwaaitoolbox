import { createSignal, onMount, For, type Component } from "solid-js";
import NavItem from "./NavItem";
import { fetch } from "@tauri-apps/plugin-http";

interface Session {
  sessionId: string;
  sessionDir: string;
  createdAt: string;
  agent: string;
  sessionName: string;
}

const navItems = [
  {
    label: "Home",
    href: "/",
    icon: (
      <svg
        width="18"
        height="18"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
        <polyline points="9 22 9 12 15 12 15 22" />
      </svg>
    ),
  },
  {
    label: "Settings",
    href: "/settings",
    icon: (
      <svg
        width="18"
        height="18"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <circle cx="12" cy="12" r="3" />
        <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" />
      </svg>
    ),
  },
];

// Helper to get base URL - both dev and prod use the backend API at 8080
const getBaseUrl = () => {
  return "http://127.0.0.1:8080";
};

const Sidebar: Component = () => {
  const [sessions, setSessions] = createSignal<Session[]>([]);
  const [loading, setLoading] = createSignal(true);
  const [expanded, setExpanded] = createSignal(true);

  onMount(async () => {
    try {
      const baseUrl = getBaseUrl();
      const res = await fetch(`${baseUrl}/api/session?limit=50&offset=0`);
      const data = await res.json() as { sessions?: Session[] };
      setSessions(data.sessions || []);
    } catch (err) {
      console.error("Failed to load sessions:", err);
    } finally {
      setLoading(false);
    }
  });

  const formatDate = (dateStr: string) => {
    try {
      const date = new Date(dateStr);
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
    if (session.sessionName && session.sessionName.trim()) {
      return session.sessionName;
    }
    const dir = session.sessionDir || "";
    const parts = dir.split("/");
    return parts[parts.length - 1] || session.sessionId.slice(0, 8);
  };

  return (
    <aside class="w-60 bg-[#0a0a0a] border-r border-[#2a2a2a] flex flex-col">
      <nav class="flex-1 py-4 flex flex-col">
        <ul class="space-y-1 px-2">
          {navItems.map((item) => (
            <NavItem label={item.label} href={item.href} icon={item.icon} />
          ))}
        </ul>
        
        {/* Sessions Section */}
        <div class="mt-6 px-2 flex-1 overflow-hidden flex flex-col">
          <button
            onClick={() => setExpanded(!expanded())}
            class="flex items-center justify-between w-full px-2 py-1.5 text-xs font-mono uppercase tracking-wider text-[#525252] hover:text-[#737373] transition-colors"
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
            <div class="flex-1 overflow-y-auto mt-1 space-y-0.5">
              {loading() ? (
                <div class="px-2 py-4 text-[#525252] text-xs font-mono text-center">
                  Loading...
                </div>
              ) : sessions().length === 0 ? (
                <div class="px-2 py-4 text-[#525252] text-xs font-mono text-center">
                  No sessions
                </div>
              ) : (
                <For each={sessions()}>
                  {(session) => (
                    <a
                      href={`/session/${session.sessionId}`}
                      class="block group"
                    >
                      <div class="px-2 py-2 rounded hover:bg-[#141414] transition-colors">
                        <div class="flex items-start gap-2">
                          <div class="w-1.5 h-1.5 rounded-full bg-[#262626] mt-1.5 group-hover:bg-[#facc15] transition-colors flex-shrink-0" />
                          <div class="min-w-0 flex-1">
                            <div class="text-[#a3a3a3] text-sm font-mono truncate group-hover:text-[#e5e5e5] transition-colors">
                              {getSessionDisplayName(session)}
                            </div>
                            <div class="text-[#404040] text-xs mt-0.5">
                              {formatDate(session.createdAt)}
                            </div>
                          </div>
                        </div>
                      </div>
                    </a>
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
