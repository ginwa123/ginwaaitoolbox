import { createSignal, createResource, Show, For, createEffect, type Component } from "solid-js";
import { useParams } from "@solidjs/router";
import { parseMessages, decodeXmlEntities, type XmlMessage } from "../utils/xmlParser";

interface ChatMessage {
  id: string;
  role: "user" | "assistant" | "system" | "tool";
  content: string;
  timestamp: string;
  // Extended fields from API
  is_input?: string;
  is_output?: string;
  tool_name?: string;
  finish_reason?: string;
}

interface SessionInfo {
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

// Convert XmlMessage to ChatMessage (normalizes role, decodes XML entities)
const normalizeMessage = (msg: XmlMessage): ChatMessage => {
  return {
    id: msg.id,
    role: msg.role as ChatMessage["role"],
    content: decodeXmlEntities(msg.content),
    timestamp: msg.timestamp,
    is_input: msg.is_input,
    is_output: msg.is_output,
    tool_name: msg.tool_name,
    finish_reason: msg.finish_reason,
  };
};

// Normalize JSON message format to ChatMessage
const normalizeJsonMessage = (msg: Record<string, unknown>): ChatMessage => {
  return {
    id: String(msg.id || ""),
    role: String(msg.role || "unknown") as ChatMessage["role"],
    content: String(msg.content || ""),
    timestamp: String(msg.timestamp || ""),
    is_input: String(msg.is_input || "0"),
    is_output: String(msg.is_output || "0"),
    tool_name: String(msg.tool_name || ""),
    finish_reason: String(msg.finish_reason || ""),
  };
};

const SessionChat: Component = () => {
  const params = useParams<{ sessionId: string }>();
  const [messages, setMessages] = createSignal<ChatMessage[]>([]);
  const [error, setError] = createSignal<string | null>(null);
  const [loading, setLoading] = createSignal(true);
  const [responseFormat, setResponseFormat] = createSignal<"json" | "xml">("xml");

  const [sessionInfo] = createResource(() => params.sessionId, async (sessionId) => {
    try {
      const res = await fetch(`${getBaseUrl()}/api/session/${sessionId}`, {
        headers: {
          Accept: "application/json",
        },
      });
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

  createEffect(() => {
    const sessionId = params.sessionId;
    if (!sessionId) return;

    // Clear previous messages and reset state when session changes
    setMessages([]);
    setError(null);
    setLoading(true);

    const fetchMessages = async () => {
      try {
        // Use selected format (JSON or XML)
        const format = responseFormat();
        const url = `${getBaseUrl()}/api/session/${sessionId}/messages?format=${format}`;
        console.log("Fetching messages from:", url);

        const res = await fetch(url, {
          headers: {
            Accept: format === "xml" ? "text/xml" : "application/json",
          },
        });
        console.log("Messages response status:", res.status);
        console.log("Content-Type:", res.headers.get("content-type"));

        const text = await res.text();
        console.log("Messages response text:", text.substring(0, 1000));

        if (!res.ok) {
          throw new Error(`HTTP ${res.status}: ${text}`);
        }

        // Parse messages based on format
        if (format === "xml") {
          const xmlMessages = parseMessages(text);
          setMessages(xmlMessages.map(normalizeMessage));
        } else {
          const data = JSON.parse(text) as { messages?: Record<string, unknown>[] };
          setMessages((data.messages || []).map(normalizeJsonMessage));
        }
      } catch (err) {
        console.error("Failed to load messages:", err);
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setLoading(false);
      }
    };

    fetchMessages();
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

  const toggleFormat = () => {
    setResponseFormat((prev) => (prev === "xml" ? "xml" : "json"));
  };

  return (
    <div class="h-full flex flex-col">
      {/* Session Header */}
      <div class="border-b border-[#2a2a2a] pb-6 mb-6">
        <div class="flex items-center justify-between">
          <Show when={sessionInfo()}>
            {(info) => (
              <div>
                <h1 class="font-mono text-2xl font-semibold text-[#e5e5e5] mb-2">
                  {info().session_name || info().session_id.slice(0, 8)}
                </h1>
                <div class="flex items-center gap-4 text-xs text-[#525252] font-mono">
                  <span>Agent: {info().agent || "default"}</span>
                  <span class="text-[#2a2a2a]">·</span>
                  <span>ID: {info().session_id.slice(0, 8)}...</span>
                </div>
              </div>
            )}
          </Show>
          <Show when={!sessionInfo() && !loading()}>
            <h1 class="font-mono text-2xl font-semibold text-[#e5e5e5] mb-2">
              Session {params.sessionId?.slice(0, 8)}...
            </h1>
          </Show>

          {/* Format Toggle */}
          <button
            onClick={toggleFormat}
            class="px-3 py-1.5 text-xs font-mono bg-[#141414] border border-[#2a2a2a] hover:border-[#facc15] hover:text-[#facc15] transition-colors"
            title="Toggle between JSON and XML format"
          >
            <span class="text-[#737373]">Format:</span>{" "}
            <span class={responseFormat() === "xml" ? "text-[#facc15]" : "text-[#e5e5e5]"}>
              {responseFormat() === "xml" ? "XML" : "JSON"}
            </span>
          </button>
        </div>
      </div>

      {/* Chat Messages */}
      <div class="flex-1 overflow-y-auto space-y-6">
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
              <div class="group py-3 px-4 -mx-4 rounded-lg hover:bg-[#0f0f0f] transition-colors">
                <div class="flex items-start gap-4">
                  <span class={`font-mono text-base w-5 mt-0.5 ${getRoleColor(message.role)}`}>
                    {getRoleIcon(message.role)}
                  </span>
                  <div class="flex-1 min-w-0">
                    <div class="flex items-baseline gap-3 mb-2">
                      <span class={`font-mono text-xs uppercase tracking-wider ${getRoleColor(message.role)}`}>
                        {message.role}
                      </span>
                      <span class="font-mono text-xs text-[#404040]">
                        {formatTimestamp(message.timestamp)}
                      </span>
                      <Show when={message.tool_name}>
                        <span class="font-mono text-xs text-[#525252] bg-[#1a1a1a] px-2 py-0.5">
                          {message.tool_name}
                        </span>
                      </Show>
                    </div>
                    <div class="font-mono text-sm text-[#a3a3a3] whitespace-pre-wrap break-words leading-relaxed">
                      {message.content}
                    </div>
                    <Show when={message.finish_reason}>
                      <div class="mt-2 font-mono text-xs text-[#404040]">
                        <span class="text-[#2a2a2a]">finish_reason:</span> {message.finish_reason}
                      </div>
                    </Show>
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
