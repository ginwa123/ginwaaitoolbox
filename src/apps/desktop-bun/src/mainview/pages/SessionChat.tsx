import { createSignal, createResource, Show, For, createEffect, onMount, type Component } from "solid-js";
import { useParams } from "@solidjs/router";
import { parseMessages, decodeXmlEntities, type XmlMessage } from "../utils/xmlParser";
import { getBaseUrl } from "../../utils/baseUrl";

interface ChatMessage {
  id: string;
  role: "user" | "assistant" | "system" | "tool";
  content: string;
  timestamp: string;
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

const normalizeMessage = (msg: XmlMessage): ChatMessage => ({
  id: msg?.id || "",
  role: (msg?.role || "unknown") as ChatMessage["role"],
  content: decodeXmlEntities(msg?.content),
  timestamp: msg?.timestamp || "",
  is_input: msg?.is_input,
  is_output: msg?.is_output,
  tool_name: msg?.tool_name,
  finish_reason: msg?.finish_reason,
});

const normalizeJsonMessage = (msg: Record<string, unknown>): ChatMessage => ({
  id: String(msg.id || ""),
  role: String(msg.role || "unknown") as ChatMessage["role"],
  content: String(msg.content || ""),
  timestamp: String(msg.timestamp || ""),
  is_input: String(msg.is_input || "0"),
  is_output: String(msg.is_output || "0"),
  tool_name: String(msg.tool_name || ""),
  finish_reason: String(msg.finish_reason || ""),
});

interface MessageListProps {
  messages: ChatMessage[];
}

const MessageList: Component<MessageListProps> = (props) => {
  let containerRef: HTMLDivElement | undefined;

  onMount(() => {
    // Scroll to bottom when component mounts
    if (containerRef) {
      containerRef.scrollTop = containerRef.scrollHeight;
    }
  });

  createEffect(() => {
    // Track messages length to scroll when new messages arrive
    const _ = props.messages.length;
    if (containerRef) {
      requestAnimationFrame(() => {
        if (containerRef) {
          containerRef.scrollTop = containerRef.scrollHeight;
        }
      });
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
      case "user": return "text-sky-400";
      case "assistant": return "text-yellow-400";
      case "system": return "text-violet-400";
      case "tool": return "text-emerald-400";
      default: return "text-zinc-500";
    }
  };

  const getRoleIcon = (role: string) => {
    switch (role) {
      case "user": return "▸";
      case "assistant": return "◆";
      case "system": return "★";
      case "tool": return "⚙";
      default: return "·";
    }
  };

  return (
    <div
      ref={containerRef}
      class="h-full overflow-y-auto overflow-x-hidden"
    >
      <For each={props.messages}>
        {(msg, index) => (
          <div class="px-4 py-3 hover:bg-neutral-900/50 transition-colors border-b border-neutral-900/50">
            <div class="flex gap-4">
              <span class={`font-mono text-base w-5 flex-shrink-0 mt-0.5 ${getRoleColor(msg.role)}`}>
                {getRoleIcon(msg.role)}
              </span>
              <div class="flex-1 min-w-0">
                <div class="flex items-baseline gap-3 mb-2">
                  <span class={`font-mono text-xs uppercase tracking-wider font-semibold ${getRoleColor(msg.role)}`}>
                    {msg.role}
                  </span>
                  <span class="font-mono text-xs text-zinc-600">
                    {formatTimestamp(msg.timestamp)}
                  </span>
                  <Show when={msg.tool_name}>
                    <span class="font-mono text-xs text-zinc-500 bg-neutral-900 px-2 py-0.5 border border-neutral-800">
                      {msg.tool_name}
                    </span>
                  </Show>
                </div>
                <div class="font-mono text-sm text-zinc-400 whitespace-pre-wrap break-words leading-relaxed">
                  {msg.content}
                </div>
              </div>
            </div>
          </div>
        )}
      </For>
    </div>
  );
};

const SessionChat: Component = () => {
  const params = useParams<{ sessionId: string }>();
  const [messages, setMessages] = createSignal<ChatMessage[]>([]);
  const [error, setError] = createSignal<string | null>(null);
  const [loading, setLoading] = createSignal(true);
  const [responseFormat, setResponseFormat] = createSignal<"json" | "xml">("xml");

  const [sessionInfo] = createResource(() => params.sessionId, async (sessionId) => {
    try {
      const baseUrl = await getBaseUrl();
      const res = await fetch(`${baseUrl}/api/session/${sessionId}`, {
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return null;
      return JSON.parse(await res.text()) as SessionInfo;
    } catch {
      return null;
    }
  });

  createEffect(() => {
    const sessionId = params.sessionId;
    if (!sessionId) return;

    setMessages([]);
    setError(null);
    setLoading(true);

    const fetchMessages = async () => {
      try {
        const format = responseFormat();
        const baseUrl = await getBaseUrl();
        const url = `${baseUrl}/api/session/${sessionId}/messages?format=${format}`;
        const res = await fetch(url, {
          headers: { Accept: format === "xml" ? "text/xml" : "application/json" },
        });

        if (!res.ok) throw new Error(`HTTP ${res.status}`);

        const text = await res.text();
        if (format === "xml") {
          setMessages(parseMessages(text).map(normalizeMessage));
        } else {
          const data = JSON.parse(text) as { messages?: Record<string, unknown>[] };
          setMessages((data.messages || []).map(normalizeJsonMessage));
        }
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setLoading(false);
      }
    };

    fetchMessages();
  });

  const toggleFormat = () => {
    setResponseFormat((prev) => (prev === "xml" ? "json" : "xml"));
  };

  const sessionName = () => {
    const info = sessionInfo();
    if (!info) return null;
    if (info.session_name) return info.session_name;
    if (info.session_id) return info.session_id.slice(0, 8);
    return null;
  };

  const sessionAgent = () => sessionInfo()?.agent || "default";
  const sessionId = () => sessionInfo()?.session_id?.slice(0, 8);

  return (
    <div class="h-full flex flex-col bg-neutral-950 font-mono">
      {/* Session Header */}
      <div class="border-b border-neutral-800 pb-6 mb-6 flex-shrink-0">
        <div class="flex items-center justify-between">
          <div>
            <Show when={sessionName()} fallback={
              <h1 class="text-2xl font-semibold text-zinc-200 mb-2">
                Session {params.sessionId?.slice(0, 8)}...
              </h1>
            }>
              <h1 class="text-2xl font-semibold text-zinc-200 mb-2">
                {sessionName()}
              </h1>
            </Show>
            <div class="flex items-center gap-4 text-xs text-zinc-600">
              <span>Agent: {sessionAgent()}</span>
              <Show when={sessionId()}>
                <span class="text-neutral-800">·</span>
                <span>ID: {sessionId()}...</span>
              </Show>
            </div>
          </div>

          <button
            onClick={toggleFormat}
            class="px-3 py-1.5 text-xs bg-neutral-900 border border-neutral-800 hover:border-yellow-400 hover:text-yellow-400 transition-colors"
          >
            <span class="text-zinc-500">Format:</span>{" "}
            <span class={responseFormat() === "xml" ? "text-yellow-400" : "text-zinc-200"}>
              {responseFormat() === "xml" ? "XML" : "JSON"}
            </span>
          </button>
        </div>
      </div>

      {/* Messages */}
      <div class="flex-1 min-h-0">
        <Show when={loading()}>
          <div class="flex items-center justify-center h-full">
            <span class="text-zinc-600 text-sm animate-pulse">Loading messages...</span>
          </div>
        </Show>

        <Show when={error()}>
          <div class="flex items-center justify-center h-full">
            <div class="text-center">
              <div class="text-red-500 text-lg mb-2">Error</div>
              <div class="text-zinc-600 text-sm">{error()}</div>
            </div>
          </div>
        </Show>

        <Show when={!loading() && !error() && messages().length === 0}>
          <div class="flex items-center justify-center h-full">
            <div class="text-center">
              <div class="text-zinc-600 text-lg mb-2">No messages yet</div>
              <div class="text-zinc-700 text-sm">Start a conversation to see messages here</div>
            </div>
          </div>
        </Show>

        <Show when={!loading() && !error() && messages().length > 0}>
          <MessageList messages={messages()} />
        </Show>
      </div>
    </div>
  );
};

export default SessionChat;
