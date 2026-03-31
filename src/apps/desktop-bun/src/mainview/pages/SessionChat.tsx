import { useParams } from '@solidjs/router';
import {
  type Component,
  For,
  Show,
  createEffect,
  createMemo,
  createResource,
  createSignal,
} from 'solid-js';
import { createInfiniteQuery } from '@tanstack/solid-query';
import ChatInput from '../components/ChatInput';
import { baseUrl } from '../utils/baseUrl';
import { type XmlMessage, decodeXmlEntities, parseMessages } from '../utils/xmlParser';
import { type ChatMessage, SessionMessagesResponse } from '../../shared/rpc';

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

const MessageRow: Component<{ message: ChatMessage }> = (props) => {
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
    <div class="group border-l-2 border-l-transparent hover:border-l-[#fbbf24] transition-colors">
      <div class="px-6 py-4 border-b border-[#1a1a1a]">
        <div class="flex gap-4">
          <span class={`font-mono text-sm w-5 flex-shrink-0 mt-0.5 ${getRoleColor(props.message.role)}`}>
            {getRoleIcon(props.message.role)}
          </span>
          <div class="flex-1 min-w-0">
            <div class="flex items-baseline gap-3 mb-2">
              <span class={`font-mono text-xs uppercase tracking-wider font-semibold ${getRoleColor(props.message.role)}`}>
                {props.message.role}
              </span>
              <span class="font-mono text-xs text-[#3f3f46]">
                {formatTimestamp(props.message.timestamp)}
              </span>
              <Show when={props.message.tool_name}>
                <span class="font-mono text-xs text-[#52525b] bg-[#18181b] px-2 py-0.5 border border-[#27272a] uppercase tracking-wider">
                  {props.message.tool_name}
                </span>
              </Show>
            </div>
            <div class="font-mono text-sm text-[#a1a1aa] whitespace-pre-wrap break-words leading-relaxed">
              {props.message.content}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

const SessionChat: Component = () => {
  const params = useParams<{ sessionId: string }>();
  let scrollRef: HTMLDivElement | undefined;
  const [responseFormat, setResponseFormat] = createSignal<'json' | 'xml'>('json');

  const [sessionInfo] = createResource(
    () => params.sessionId,
    async (sessionId: string) => {
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

  // Single source of truth: use messagesQuery for all message data
  const messagesQuery = createInfiniteQuery(() => ({
    queryKey: ['session-messages', params.sessionId, responseFormat()],
    queryFn: async ({ pageParam }: { pageParam?: string }) => {
      const format = responseFormat();
      const url = new URL(`${baseUrl()}/api/session/${params.sessionId}/messages`);
      url.searchParams.set('format', format);
      url.searchParams.set('limit', '50');

      if (pageParam !== undefined) {
        url.searchParams.set('cursor', pageParam);
        url.searchParams.set('direction', 'asc');
      } else {
        // First load: get latest messages
        url.searchParams.set('direction', 'desc');
      }

      const res = await fetch(url.toString(), {
        headers: { Accept: format === 'xml' ? 'text/xml' : 'application/json' },
      });

      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      if (format === 'xml') {
        const text = await res.text();
        const parsed = parseMessages(text);
        const msgs = parsed.map(normalizeMessage);
        return {
          messages: msgs,
          has_more: msgs.length === 50,
          next_cursor: msgs.length > 0 ? msgs[msgs.length - 1].id : null,
        } as SessionMessagesResponse;
      } else {
        const data = await res.json() as SessionMessagesResponse;
        return data;
      }
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage: SessionMessagesResponse) => lastPage.next_cursor ?? undefined,
    enabled: !!params.sessionId,
    staleTime: 0,
  }));

  // Flatten all pages into single messages array
  const allMessages = createMemo(() =>
    messagesQuery.data?.pages.flatMap((p) => p.messages) ?? []
  );

  console.log('[SessionChat] messagesQuery:', messagesQuery);
  console.log('[SessionChat] allMessages:', allMessages());

  // Scroll to bottom when messages change
  createEffect(() => {
    const messages = allMessages();
    if (messages.length > 0 && scrollRef) {
      // Use setTimeout to ensure DOM is rendered
      setTimeout(() => {
        if (scrollRef) {
          scrollRef.scrollTop = scrollRef.scrollHeight;
        }
      }, 100);
    }
  });

  const handleScroll = () => {
    if (!scrollRef) return;

    // Trigger load more when scrolled near top
    if (
      scrollRef.scrollTop < 300 &&
      messagesQuery.hasNextPage &&
      !messagesQuery.isFetchingNextPage
    ) {
      messagesQuery.fetchNextPage();
    }
  };

  const toggleFormat = () => {
    setResponseFormat((prev) => (prev === 'json' ? 'xml' : 'json'));
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
      <div class="flex-shrink-0 pb-4">
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
            <div class="flex items-center gap-3 text-xs text-[#52525b] uppercase tracking-widest">
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
            class="px-3 py-1.5 text-xs bg-[#09090b] border border-[#27272a] hover:border-[#fbbf24] hover:text-[#fbbf24] transition-colors uppercase tracking-wider"
          >
            <span class="text-[#52525b]">Fmt:</span>{' '}
            <span class={responseFormat() === 'xml' ? 'text-[#fbbf24]' : 'text-[#a1a1aa]'}>
              {responseFormat() === 'xml' ? 'XML' : 'JSON'}
            </span>
          </button>
        </div>
        <div class="border-b-2 border-[#27272a] mt-4" />
      </div>

      {/* Messages */}
      <div class="flex-1 min-h-0 flex flex-col mt-4 border border-[#18181b] bg-[#0a0a0a]">
        <Show
          when={!messagesQuery.isPending && allMessages().length > 0}
          fallback={
            <div class="flex-1 flex items-center justify-center">
              <Show when={messagesQuery.isPending}>
                <span class="text-[#52525b] text-xs uppercase tracking-widest animate-pulse">
                  Loading messages... ({allMessages().length})
                </span>
              </Show>
              <Show when={messagesQuery.isError}>
                <div class="text-center">
                  <div class="text-[#ef4444] text-sm mb-1 uppercase tracking-wider">Error</div>
                  <div class="text-[#52525b] text-xs">{String(messagesQuery.error)}</div>
                </div>
              </Show>
              <Show when={!messagesQuery.isPending && !messagesQuery.isError && allMessages().length === 0}>
                <div class="text-center">
                  <div class="text-[#52525b] text-sm mb-1 uppercase tracking-wider">
                    No messages yet
                  </div>
                  <div class="text-[#3f3f46] text-xs">Start a conversation</div>
                </div>
              </Show>
            </div>
          }
        >
          <div
            ref={(el) => { scrollRef = el; console.log('[SessionChat] scrollRef set:', el); }}
            class="flex-1 overflow-y-auto"
            onScroll={handleScroll}
          >
            <For each={allMessages()}>
              {(message, index) => {
                console.log('[SessionChat] Rendering message', index(), message.id);
                return <MessageRow message={message} />;
              }}
            </For>
          </div>

          <Show when={messagesQuery.isFetchingNextPage}>
            <div class="p-2 text-center text-sm text-[#52525b] uppercase tracking-widest animate-pulse">
              Loading older messages...
            </div>
          </Show>
        </Show>
      </div>

      {/* Chat Input */}
      <div class="flex-shrink-0 pt-4">
        <ChatInput onSend={(msg) => console.log('Send:', msg)} />
      </div>
    </div>
  );
};

export default SessionChat;
