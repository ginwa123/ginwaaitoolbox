/**
 * ConversationView - Scrollable message list with auto-scroll
 */

import type { Component } from 'solid-js';
import { For, Show, createEffect } from 'solid-js';
import { createSignal } from 'solid-js';
import type { Message } from '~/types';
import { Role } from '~/types';
import { UserMessage } from './UserMessage';
import { AssistantMessage } from './AssistantMessage';
import { SystemMessage } from './SystemMessage';
import { ToolMessage } from './ToolMessage';
import { StreamingIndicator } from './StreamingIndicator';

interface ConversationViewProps {
  readonly messages: readonly Message[];
  readonly isStreaming: boolean;
}

export const ConversationView: Component<ConversationViewProps> = (props) => {
  let scrollContainerRef: HTMLDivElement | undefined;
  const [userScrolled, setUserScrolled] = createSignal(false);

  const scrollToBottom = () => {
    if (scrollContainerRef && !userScrolled()) {
      scrollContainerRef.scrollTop = scrollContainerRef.scrollHeight;
    }
  };

  // Auto-scroll when messages change or streaming
  createEffect(() => {
    props.messages; // Track messages
    props.isStreaming; // Track streaming state
    scrollToBottom();
  });

  const handleScroll = () => {
    if (!scrollContainerRef) return;
    const { scrollTop, scrollHeight, clientHeight } = scrollContainerRef;
    const isAtBottom = scrollHeight - scrollTop - clientHeight < 50;
    setUserScrolled(!isAtBottom);
  };

  const renderMessage = (message: Message) => {
    switch (message.role) {
      case Role.User:
        return <UserMessage message={message} />;
      case Role.Assistant:
        return <AssistantMessage message={message} />;
      case Role.System:
        return <SystemMessage message={message} />;
      case Role.Tool:
        return <ToolMessage message={message} />;
      default:
        return null;
    }
  };

  return (
    <div
      ref={scrollContainerRef}
      onScroll={handleScroll}
      class="flex-1 overflow-y-auto space-y-4 p-4"
    >
      <Show
        when={props.messages.length > 0}
        fallback={
          <div class="flex flex-col items-center justify-center h-full text-gray-400 dark:text-gray-500">
            <div class="w-16 h-16 rounded-full bg-gray-100 dark:bg-gray-800 flex items-center justify-center mb-4">
              <svg
                class="w-8 h-8"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width={2}
                  d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"
                />
              </svg>
            </div>
            <p class="text-lg font-medium">No messages yet</p>
            <p class="text-sm">Start a conversation by typing a message below</p>
          </div>
        }
      >
        <For each={props.messages}>
          {(message) => (
            <div class="animate-fade-in">{renderMessage(message)}</div>
          )}
        </For>

        <Show when={props.isStreaming}>
          <div class="flex items-start gap-3">
            <div class="w-8 h-8 rounded-full bg-gradient-to-br from-purple-500 to-blue-600 flex items-center justify-center flex-shrink-0">
              <svg
                class="w-4 h-4 text-white"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width={2}
                  d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
                />
              </svg>
            </div>
            <div class="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-2xl px-4 py-3">
              <StreamingIndicator />
            </div>
          </div>
        </Show>
      </Show>

      {/* Scroll to bottom button */}
      <Show when={userScrolled()}>
        <button
          onClick={() => {
            setUserScrolled(false);
            scrollToBottom();
          }}
          class="fixed bottom-24 right-8 p-2 bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-full shadow-lg hover:shadow-xl transition-shadow"
        >
          <svg
            class="w-5 h-5 text-gray-600 dark:text-gray-400"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width={2}
              d="M19 14l-7 7m0 0l-7-7m7 7V3"
            />
          </svg>
        </button>
      </Show>
    </div>
  );
};
