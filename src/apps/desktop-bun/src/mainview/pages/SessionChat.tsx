import { useParams } from '@solidjs/router';
import { createInfiniteQuery, useQueryClient } from '@tanstack/solid-query';
import {
  type Component,
  For,
  Show,
  createEffect,
  createMemo,
  createResource,
  createSignal,
  onCleanup,
} from 'solid-js';
import { type ChatMessage, SessionMessagesResponse } from '../../shared/rpc';
import ChatInput from '../components/ChatInput';
import { FolderPicker } from '../components/FolderPicker';
import { baseUrl } from '../utils/baseUrl';
import { log } from '../utils/logger';
import { SSEClient, type SSEMessage } from '../utils/sseClient';
import { type XmlMessage, decodeXmlEntities, parseMessages } from '../utils/xmlParser';

// Shared SSE client for all session chat instances
log.info(`[SessionChat] Module loaded, baseUrl: ${baseUrl()}`);
const sharedSseClient = new SSEClient(baseUrl());
log.info('[SessionChat] SSEClient created');

interface SessionInfo {
  session_id: string;
  session_dir: string;
  created_at: string;
  agent: string;
  session_name: string;
}

/**
 * Normalize an XML message to ChatMessage format
 */
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

/**
 * Create a ChatMessage from an SSE event
 */
function sseToChatMessage(event: SSEMessage): ChatMessage {
  return {
    id: event.message_id || `sse_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
    role: (event.role || 'assistant') as ChatMessage['role'],
    content: event.content || '',
    timestamp: event.timestamp || String(Date.now()),
    is_input: false,
    is_output: true,
    tool_name: event.tool_name,
    finish_reason: event.finish_reason ?? '',
  } as ChatMessage;
}

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
          <span
            class={`font-mono text-sm w-5 flex-shrink-0 mt-0.5 ${getRoleColor(props.message.role)}`}
          >
            {getRoleIcon(props.message.role)}
          </span>
          <div class="flex-1 min-w-0">
            <div class="flex items-baseline gap-3 mb-2">
              <span
                class={`font-mono text-xs uppercase tracking-wider font-semibold ${getRoleColor(props.message.role)}`}
              >
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
  const queryClient = useQueryClient();
  let scrollRef: HTMLDivElement | undefined;
  const [streaming, setStreaming] = createSignal(false);

  // FolderPicker state
  const [folderPickerOpen, setFolderPickerOpen] = createSignal(false);
  const [sessionDir, setSessionDir] = createSignal<string | null>(null);

  // Check if this is a "new" session placeholder
  const isNewSession = () => params.sessionId === 'new';

  // Load session directory when sessionInfo changes
  createEffect(() => {
    const info = sessionInfo();
    if (info?.session_dir) {
      setSessionDir(info.session_dir);
    }
  });

  // Handle folder selection
  const handleFolderSelect = (path: string) => {
    console.log('[SessionChat] Folder selected:', path);
    setSessionDir(path);
    setFolderPickerOpen(false);
    // TODO: Optionally update session with new directory via API
  };

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

  // Track SSE messages with optimistic updates
  const [sseMessages, setSseMessages] = createSignal<ChatMessage[]>([]);
  log.info(`[SessionChat] Component mounted, sessionId: ${params.sessionId}`);

  // Single source of truth: use messagesQuery for all message data
  const messagesQuery = createInfiniteQuery(() => ({
    queryKey: ['session-messages', params.sessionId],
    queryFn: async ({ pageParam }: { pageParam?: string }) => {
      const url = new URL(`${baseUrl()}/api/session/${params.sessionId}/messages`);
      url.searchParams.set('limit', '50');

      if (pageParam !== undefined) {
        // Pagination: load older messages
        url.searchParams.set('cursor', pageParam);
        url.searchParams.set('direction', 'asc');
      } else {
        // First load: get latest messages (newest at bottom)
        url.searchParams.set('direction', 'desc');
      }

      const res = await fetch(url.toString(), {
        headers: { Accept: 'text/xml' },
      });

      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const text = await res.text();
      const parsed = parseMessages(text);
      const msgs = parsed.map(normalizeMessage);

      return {
        messages: msgs,
        has_more: msgs.length === 50,
        next_cursor: msgs.length > 0 ? msgs[msgs.length - 1].id : null,
      } as SessionMessagesResponse;
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage: SessionMessagesResponse) => lastPage.next_cursor ?? undefined,
    enabled: !!params.sessionId && params.sessionId !== 'new',
    staleTime: 0,
  }));

  // Collect all messages from pages + SSE messages
  const allMessages = createMemo(() => {
    const pages = messagesQuery.data?.pages ?? [];

    // Collect all messages from pages
    let msgs: ChatMessage[] = [];
    for (const page of pages) {
      msgs = msgs.concat(page.messages);
    }

    // Add SSE messages that aren't already in the list (optimistic updates)
    const sseMsgs = sseMessages();
    const existingIds = new Set(msgs.map((m) => m.id));

    for (const sseMsg of sseMsgs) {
      if (!existingIds.has(sseMsg.id)) {
        msgs.push(sseMsg);
      }
    }

    // Sort by timestamp (ascending - oldest first, newest at bottom)
    msgs.sort((a, b) => {
      const tsA = Number(a.timestamp) || 0;
      const tsB = Number(b.timestamp) || 0;
      if (tsA !== tsB) return tsA - tsB;
      return a.id.localeCompare(b.id);
    });

    return msgs;
  });

  console.log('[SessionChat] messagesQuery:', messagesQuery);
  console.log('[SessionChat] allMessages count:', allMessages().length);

  // Shared SSE handler reference for cleanup
  let currentHandler: ((event: SSEMessage) => void) | null = null;

  // Connect to SSE stream when session changes
  createEffect(() => {
    const sessionId = params.sessionId;

    // If no valid session, disconnect
    if (!sessionId || sessionId === 'new') {
      console.log('[SessionChat] No valid session, disconnecting SSE');
      sharedSseClient.disconnectWithNotification();
      setStreaming(false);
      setSseMessages([]);
      return;
    }

    // Session switching: disconnect from previous session first
    const currentSessionId = sharedSseClient.getSessionId();
    if (currentSessionId && currentSessionId !== sessionId) {
      console.log('[SessionChat] Switching sessions:', currentSessionId, '->', sessionId);
      sharedSseClient.disconnectWithNotification();
      setSseMessages([]);
      setTimeout(() => connectToSession(sessionId), 100);
    } else if (!currentSessionId) {
      console.log('[SessionChat] Connecting to SSE stream for session:', sessionId);
      connectToSession(sessionId);
    } else {
      console.log('[SessionChat] Already connected to session:', sessionId);
    }

    function connectToSession(sid: string) {
      // Remove old handler if exists
      if (currentHandler) {
        sharedSseClient.removeHandler(currentHandler);
        currentHandler = null;
      }

      // Create new handler for this session
      currentHandler = (event: SSEMessage) => {
        log.info(`[SessionChat] SSE event received, type: ${event.type}`);

        // Set streaming indicator
        if (event.type === 'message' && !streaming()) {
          setStreaming(true);
        }

        // Convert SSE event to ChatMessage
        const chatMsg = sseToChatMessage(event);
        log.info(`[SessionChat] Converted message id: ${chatMsg.id}`);

        // Add as optimistic update if it has content
        if (chatMsg.content) {
          log.info(
            `[SessionChat] Adding to sseMessages: ${chatMsg.id} - ${chatMsg.content.substring(0, 50)}`
          );
          setSseMessages((prev) => {
            log.info(`[SessionChat] Current sseMessages count: ${prev.length}`);
            // Check if already exists
            const exists = prev.some((m) => m.id === chatMsg.id);
            if (exists) {
              // Update existing message (for streaming updates)
              return prev.map((m) => (m.id === chatMsg.id ? { ...chatMsg } : m));
            }
            // Add new message
            return [...prev, chatMsg];
          });
          log.info('[SessionChat] SSE messages updated');
        } else {
          log.info('[SessionChat] No content in message, skipping optimistic update');
        }

        // Invalidate query to sync with backend
        queryClient.invalidateQueries({ queryKey: ['session-messages', sid] });

        // Stop streaming indicator on done
        if (event.type === 'done') {
          log.info('[SessionChat] SSE stream done');
          setStreaming(false);
          // Clear SSE messages after a short delay (let DB sync)
          setTimeout(() => {
            setSseMessages([]);
          }, 500);
        }
      };

      sharedSseClient.addHandler(currentHandler);
      sharedSseClient.connect(sid);
    }
  });

  // Cleanup on component unmount
  onCleanup(() => {
    log.info('[SessionChat] Component unmounting, disconnecting SSE');
    if (currentHandler) {
      sharedSseClient.removeHandler(currentHandler);
      currentHandler = null;
    }
    sharedSseClient.disconnectWithNotification();
    setStreaming(false);
    setSseMessages([]);
  });

  // Scroll to bottom on initial load
  createEffect(() => {
    const messages = allMessages();
    const isPending = messagesQuery.isPending;

    // When messages are loaded (not pending anymore), scroll to bottom
    if (!isPending && messages.length > 0 && scrollRef) {
      // Use requestAnimationFrame to ensure DOM is rendered
      requestAnimationFrame(() => {
        if (scrollRef) {
          scrollRef.scrollTop = scrollRef.scrollHeight;
        }
      });
    }
  });

  // Scroll to bottom when streaming or when new messages arrive
  createEffect(() => {
    const messages = allMessages();
    const isStreaming = streaming();

    if (messages.length > 0 && scrollRef && isStreaming) {
      setTimeout(() => {
        if (scrollRef) {
          scrollRef.scrollTop = scrollRef.scrollHeight;
        }
      }, 50);
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
              when={isNewSession()}
              fallback={
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
              }
            >
              <h1 class="text-xl font-semibold text-[#fafafa] mb-1 tracking-tight">New Chat</h1>
            </Show>
            <div class="flex items-center gap-3 text-xs text-[#52525b] uppercase tracking-widest">
              <Show when={!isNewSession()}>
                <span>
                  Agent: <span class="text-[#71717a]">{sessionAgent()}</span>
                </span>
                <Show when={sessionId()}>
                  <span class="text-[#27272a]">·</span>
                  <span>
                    ID: <span class="text-[#71717a]">{sessionId()}</span>...
                  </span>
                </Show>
                <Show when={streaming()}>
                  <span class="text-[#34d399]">●</span>
                  <span class="text-[#34d399]">Streaming</span>
                </Show>
              </Show>
              <Show when={isNewSession()}>
                <span class="text-[#71717a]">Start a conversation</span>
              </Show>
            </div>
          </div>

          {/* Folder Picker Button */}
        </div>
        <div class="border-b-2 border-[#27272a] mt-4" />
      </div>

      {/* Messages */}
      <div class="flex-1 min-h-0 flex flex-col mt-4 border border-[#18181b] bg-[#0a0a0a]">
        <Show
          when={!isNewSession() && !messagesQuery.isPending && allMessages().length > 0}
          fallback={
            <div class="flex-1 flex items-center justify-center">
              <Show when={isNewSession()}>
                <div class="text-center">
                  <div class="text-[#52525b] text-sm mb-1 uppercase tracking-wider">
                    Ready to chat
                  </div>
                  <div class="text-[#3f3f46] text-xs">Type a message below to start</div>
                </div>
              </Show>
              <Show when={!isNewSession() && messagesQuery.isPending}>
                <span class="text-[#52525b] text-xs uppercase tracking-widest animate-pulse">
                  Loading messages... ({allMessages().length})
                </span>
              </Show>
              <Show when={!isNewSession() && messagesQuery.isError}>
                <div class="text-center">
                  <div class="text-[#ef4444] text-sm mb-1 uppercase tracking-wider">Error</div>
                  <div class="text-[#52525b] text-xs">{String(messagesQuery.error)}</div>
                </div>
              </Show>
              <Show
                when={
                  !isNewSession() &&
                  !messagesQuery.isPending &&
                  !messagesQuery.isError &&
                  allMessages().length === 0
                }
              >
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
            ref={(el) => {
              scrollRef = el;
            }}
            class="flex-1 overflow-y-auto"
            onScroll={handleScroll}
          >
            <For each={allMessages()}>{(message, _index) => <MessageRow message={message} />}</For>
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
        <ChatInput sessionId={params.sessionId !== 'new' ? params.sessionId : undefined} />
      </div>

      {/* Folder Picker Modal */}
      <FolderPicker
        isOpen={folderPickerOpen()}
        initialPath={sessionDir() || undefined}
        onSelect={handleFolderSelect}
        onClose={() => setFolderPickerOpen(false)}
      />
    </div>
  );
};

export default SessionChat;
