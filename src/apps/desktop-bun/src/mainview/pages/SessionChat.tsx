import { useParams } from '@solidjs/router';
import {
  type Component,
  For,
  Show,
  createEffect,
  createResource,
  createSignal,
  onMount,
} from 'solid-js';
import ChatInput from '../components/ChatInput';
import { baseUrl } from '../utils/baseUrl';
import { type XmlMessage, decodeXmlEntities, parseMessages } from '../utils/xmlParser';

interface ChatMessage {
  id: string;
  role: 'user' | 'assistant' | 'system' | 'tool';
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
  id: msg?.id || '',
  role: (msg?.role || 'unknown') as ChatMessage['role'],
  content: decodeXmlEntities(msg?.content),
  timestamp: msg?.timestamp || '',
  is_input: msg?.is_input,
  is_output: msg?.is_output,
  tool_name: msg?.tool_name,
  finish_reason: msg?.finish_reason,
});

const normalizeJsonMessage = (msg: Record<string, unknown>): ChatMessage => ({
  id: String(msg.id || ''),
  role: String(msg.role || 'unknown') as ChatMessage['role'],
  content: String(msg.content || ''),
  timestamp: String(msg.timestamp || ''),
  is_input: String(msg.is_input || '0'),
  is_output: String(msg.is_output || '0'),
  tool_name: String(msg.tool_name || ''),
  finish_reason: String(msg.finish_reason || ''),
});

const MessageList: Component<{ messages: ChatMessage[] }> = (props) => {
  let containerRef: HTMLDivElement | undefined;

  onMount(() => {
    if (containerRef) {
      containerRef.scrollTop = containerRef.scrollHeight;
    }
  });

  createEffect(() => {
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
      const date = Number.isNaN(numericTs) ? new Date(ts) : new Date(numericTs);
      if (Number.isNaN(date.getTime())) return '';
      return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    } catch {
      return '';
    }
  };

  const getRoleColor = (role: string) => {
    switch (role) {
      case 'user':
        return 'text-[#38bdf8]';
      case 'assistant':
        return 'text-[#fbbf24]';
      case 'system':
        return 'text-[#a78bfa]';
      case 'tool':
        return 'text-[#34d399]';
      default:
        return 'text-[#71717a]';
    }
  };

  const getRoleIcon = (role: string) => {
    switch (role) {
      case 'user':
        return '▸';
      case 'assistant':
        return '◆';
      case 'system':
        return '★';
      case 'tool':
        return '▣';
      default:
        return '·';
    }
  };

  return (
    <div ref={containerRef} class="flex-1 overflow-y-auto">
      <For each={props.messages}>
        {(msg) => (
          <div class="group border-l-2 border-l-transparent hover:border-l-[#fbbf24] transition-colors">
            <div class="px-6 py-4 border-b border-[#1a1a1a]">
              <div class="flex gap-4">
                <span
                  class={`font-mono text-sm w-5 flex-shrink-0 mt-0.5 ${getRoleColor(msg.role)}`}
                >
                  {getRoleIcon(msg.role)}
                </span>
                <div class="flex-1 min-w-0">
                  <div class="flex items-baseline gap-3 mb-2">
                    <span
                      class={`font-mono text-[10px] uppercase tracking-[0.2em] font-semibold ${getRoleColor(msg.role)}`}
                    >
                      {msg.role}
                    </span>
                    <span class="font-mono text-[10px] text-[#3f3f46]">
                      {formatTimestamp(msg.timestamp)}
                    </span>
                    <Show when={msg.tool_name}>
                      <span class="font-mono text-[10px] text-[#52525b] bg-[#18181b] px-2 py-0.5 border border-[#27272a] uppercase tracking-wider">
                        {msg.tool_name}
                      </span>
                    </Show>
                  </div>
                  <div class="font-mono text-[13px] text-[#a1a1aa] whitespace-pre-wrap break-words leading-relaxed">
                    {msg.content}
                  </div>
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
  const [responseFormat, setResponseFormat] = createSignal<'json' | 'xml'>('xml');

  const [sessionInfo] = createResource(
    () => params.sessionId,
    async (sessionId) => {
      try {
        const res = await fetch(`${baseUrl()}/api/session/${sessionId}`, {
          headers: { Accept: 'application/json' },
        });
        if (!res.ok) return null;
        return JSON.parse(await res.text()) as SessionInfo;
      } catch {
        return null;
      }
    }
  );

  createEffect(() => {
    const sessionId = params.sessionId;
    if (!sessionId) return;

    setMessages([]);
    setError(null);
    setLoading(true);

    const fetchMessages = async () => {
      try {
        const format = responseFormat();
        const url = `${baseUrl()}/api/session/${sessionId}/messages?format=${format}`;
        const res = await fetch(url, {
          headers: { Accept: format === 'xml' ? 'text/xml' : 'application/json' },
        });

        if (!res.ok) throw new Error(`HTTP ${res.status}`);

        const text = await res.text();
        if (format === 'xml') {
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
    setResponseFormat((prev) => (prev === 'xml' ? 'json' : 'xml'));
  };

  const sessionName = () => {
    const info = sessionInfo();
    if (!info) return null;
    if (info.session_name) return info.session_name;
    if (info.session_id) return info.session_id.slice(0, 8);
    return null;
  };

  const sessionAgent = () => sessionInfo()?.agent || 'default';
  const sessionId = () => sessionInfo()?.session_id?.slice(0, 8);

  return (
    <div class="h-full flex flex-col">
      {/* Session Header */}
      <div class="border-b-2 border-[#27272a] pb-4 flex-shrink-0">
        <div class="flex items-center justify-between">
          <div>
            <Show
              when={sessionName()}
              fallback={
                <h1 class="text-xl font-semibold text-[#fafafa] mb-1 tracking-tight">
                  Session {params.sessionId?.slice(0, 8)}...
                </h1>
              }
            >
              <h1 class="text-xl font-semibold text-[#fafafa] mb-1 tracking-tight">
                {sessionName()}
              </h1>
            </Show>
            <div class="flex items-center gap-3 text-[10px] text-[#52525b] uppercase tracking-widest">
              <span>
                Agent: <span class="text-[#71717a]">{sessionAgent()}</span>
              </span>
              <Show when={sessionId()}>
                <span class="text-[#27272a]">·</span>
                <span>
                  ID: <span class="text-[#71717a]">{sessionId()}</span>...
                </span>
              </Show>
            </div>
          </div>

          <button
            onClick={toggleFormat}
            class="px-3 py-1.5 text-[10px] bg-[#09090b] border border-[#27272a] hover:border-[#fbbf24] hover:text-[#fbbf24] transition-colors uppercase tracking-wider"
          >
            <span class="text-[#52525b]">Fmt:</span>{' '}
            <span class={responseFormat() === 'xml' ? 'text-[#fbbf24]' : 'text-[#a1a1aa]'}>
              {responseFormat() === 'xml' ? 'XML' : 'JSON'}
            </span>
          </button>
        </div>
      </div>

      {/* Messages */}
      <div class="flex-1 min-h-0 mt-4 border border-[#18181b] bg-[#0a0a0a]">
        <Show when={loading()}>
          <div class="h-full flex items-center justify-center">
            <span class="text-[#52525b] text-xs uppercase tracking-widest animate-pulse">
              Loading messages...
            </span>
          </div>
        </Show>

        <Show when={error()}>
          <div class="h-full flex items-center justify-center">
            <div class="text-center">
              <div class="text-[#ef4444] text-sm mb-1 uppercase tracking-wider">Error</div>
              <div class="text-[#52525b] text-xs">{error()}</div>
            </div>
          </div>
        </Show>

        <Show when={!loading() && !error() && messages().length === 0}>
          <div class="h-full flex items-center justify-center">
            <div class="text-center">
              <div class="text-[#52525b] text-sm mb-1 uppercase tracking-wider">
                No messages yet
              </div>
              <div class="text-[#3f3f46] text-xs">Start a conversation</div>
            </div>
          </div>
        </Show>

        <Show when={!loading() && !error() && messages().length > 0}>
          <MessageList messages={messages()} />
        </Show>
      </div>

      {/* Chat Input */}
      <div class="pt-4 flex-shrink-0">
        <ChatInput onSend={(msg) => console.log('Send:', msg)} />
      </div>
    </div>
  );
};

export default SessionChat;
