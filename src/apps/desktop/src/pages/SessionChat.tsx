import { createSignal, createResource, Show, For, onMount, type Component } from "solid-js";
import { useParams } from "@solidjs/router";

interface ChatMessage {
  id: string;
  role: "user" | "assistant" | "system" | "tool";
  content: string;
  timestamp: string;
}

interface SessionInfo {
  sessionId: string;
  sessionDir: string;
  createdAt: string;
  agent: string;
  sessionName: string;
}

// Helper to get base URL - both dev and prod use the backend API at 8080
const getBaseUrl = () => {
  return "http://127.0.0.1:8080";
};

const SessionChat: Component = () => {
  const params = useParams<{ sessionId: string }>();
  const [messages, setMessages] = createSignal<ChatMessage[]>([]);
  const [error, setError] = createSignal<string | null>(null);
  const [loading, setLoading] = createSignal(true);

  const [sessionInfo] = createResource(() => params.sessionId, async (sessionId) => {
    try {
      const res = await fetch(`${getBaseUrl()}/api/session/${sessionId}`);
      if (!res.ok) {
        console.error("Failed to load session info:", res.status);
        return null;
      }
      const text = await res.text();
      console.log("Session info response:", text.substring(0, 500));
      return JSON.parse(text) as SessionInfo;
    } catch (err) {
      console.error("Failed to load session info:", err);
      return null;
    }
  });

  onMount(async () => {
    try {
      const url = `${getBaseUrl()}/api/session/${params.sessionId}/messages`;
      console.log("Fetching messages from:", url);
      
      const res = await fetch(url);
      console.log("Messages response status:", res.status);
      
      const text = await res.text();
      console.log("Messages response text:", text.substring(0, 1000));
      
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}: ${text}`);
      }
      
      const data = JSON.parse(text) as { messages?: ChatMessage[] };
      setMessages(data.messages || []);
    } catch (err) {
      console.error("Failed to load messages:", err);
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  });

  const formatTimestamp = (ts: string) => {
    try {
      const numericTs = Number(ts);
      const date = isNaN(numericTs) ? new Date(ts) : new Date(numericTs);
      if (isNaN(date.getTime())) return "";
      return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    } catch {
      return "";
    }
  };

  const getRoleColor = (role: string) => {
    switch (role) {
      case "user": return "text-[#60a5fa]";
      case "assistant": return "text-[#facc15]";
      case "system": return "text-[#a78bfa]";
      case "tool": return "text-[#34d399]";
      default: return "text-[#737373]";
    }
  };

  const getRoleIcon = (role: string) => {
    switch (role) {
      case "user": return ">";
      case "assistant": return "◆";
      case "system": return "★";
      case "tool": return "⚙";
      default: return "·";
    }
  };

  return (
    <div class="h-full flex flex-col">
      {/* Session Header */}
      <div class="border-b border-[#2a2a2a] pb-4 mb-4">
        <Show when={sessionInfo()}>
          {(info) => (
            <div>
              <h1 class="font-mono text-xl font-semibold text-[#e5e5e5] mb-1">
                {info().sessionName || info().sessionId.slice(0, 8)}
              </h1>
              <div class="flex items-center gap-4 text-xs text-[#525252] font-mono">
                <span>Agent: {info().agent || "default"}</span>
                <span>·</span>
                <span>ID: {info().sessionId.slice(0, 8)}...</span>
              </div>
            </div>
          )}
        </Show>
        <Show when={!sessionInfo() && !loading()}>
          <h1 class="font-mono text-xl font-semibold text-[#e5e5e5] mb-1">
            Session {params.sessionId?.slice(0, 8)}...
          </h1>
        </Show>
      </div>

      {/* Chat Messages */}
      <div class="flex-1 overflow-y-auto space-y-4">
        <Show when={loading()}>
          <div class="flex items-center justify-center h-full">
            <div class="text-[#525252] font-mono text-sm">Loading messages...</div>
          </div>
        </Show>

        <Show when={error()}>
          <div class="flex items-center justify-center h-full">
            <div class="text-center">
              <div class="text-[#ef4444] font-mono text-lg mb-2">Error</div>
              <div class="text-[#525252] font-mono text-sm">{error()}</div>
            </div>
          </div>
        </Show>

        <Show when={!loading() && !error() && messages().length === 0}>
          <div class="flex items-center justify-center h-full">
            <div class="text-center">
              <div class="text-[#525252] font-mono text-lg mb-2">No messages yet</div>
              <div class="text-[#404040] font-mono text-sm">
                Start a conversation to see messages here
              </div>
            </div>
          </div>
        </Show>

        <Show when={!loading() && !error() && messages().length > 0}>
          <For each={messages()}>
            {(message) => (
              <div class="group">
                <div class="flex items-start gap-3">
                  <span class={`font-mono text-sm w-4 mt-0.5 ${getRoleColor(message.role)}`}>
                    {getRoleIcon(message.role)}
                  </span>
                  <div class="flex-1 min-w-0">
                    <div class="flex items-baseline gap-2 mb-1">
                      <span class={`font-mono text-xs uppercase ${getRoleColor(message.role)}`}>
                        {message.role}
                      </span>
                      <span class="font-mono text-xs text-[#404040]">
                        {formatTimestamp(message.timestamp)}
                      </span>
                    </div>
                    <div class="font-mono text-sm text-[#a3a3a3] whitespace-pre-wrap break-words">
                      {message.content}
                    </div>
                  </div>
                </div>
              </div>
            )}
          </For>
        </Show>
      </div>
    </div>
  );
};

export default SessionChat;
