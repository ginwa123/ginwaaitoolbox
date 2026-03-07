/**
 * ChatPage - Main chat interface
 */

import type { Component } from 'solid-js';
import { Show, createEffect } from 'solid-js';
import { useParams, useNavigate } from '@solidjs/router';
import { ConversationView } from '~/components/messages';
import { MessageInput } from '~/components/input';
import { sessionStore } from '~/store/sessionStore';
import { messageStore } from '~/store/messageStore';
import { getAgentByType, streamMessage } from '~/services';

export const ChatPage: Component = () => {
  const params = useParams();
  const navigate = useNavigate();
  const sessionId = () => params.id;

  // Get session and messages
  const session = () => {
    const id = sessionId();
    return sessionStore.sessions().find((s) => s.id === id) || null;
  };

  const messages = () => {
    const id = sessionId();
    return messageStore.messages().filter((m) => m.sessionId === id);
  };

  const agent = () => {
    const s = session();
    if (!s) return null;
    return getAgentByType(s.agentType);
  };

  // Select this session when loaded
  createEffect(() => {
    const id = sessionId();
    if (id) {
      sessionStore.selectSession(id);
    }
  });

  // Redirect if session not found
  createEffect(() => {
    if (session() === null && sessionId()) {
      navigate('/', { replace: true });
    }
  });

  const handleSendMessage = async (content: string) => {
    const id = sessionId();
    if (!id) return;

    // Add user message
    messageStore.addUserMessage(content, id);
    sessionStore.incrementMessageCount(id);

    // Start assistant message
    messageStore.startAssistantMessage(id);

    // Stream response
    await streamMessage(
      content,
      (chunk) => {
        messageStore.appendToStreamingMessage(chunk);
      },
      { delay: 30, includeToolCalls: true }
    );
  };

  return (
    <Show
      when={session()}
      fallback={
        <div class="flex items-center justify-center h-full">
          <div class="text-center">
            <div class="w-12 h-12 border-4 border-blue-200 border-t-blue-600 rounded-full animate-spin mx-auto mb-4" />
            <p class="text-gray-600 dark:text-gray-400">Loading session...</p>
          </div>
        </div>
      }
    >
      <div class="flex flex-col h-full">
        {/* Messages */}
        <div class="flex-1 overflow-hidden">
          <ConversationView
            messages={messages()}
            isStreaming={messageStore.isStreaming()}
          />
        </div>

        {/* Input */}
        <MessageInput
          onSend={handleSendMessage}
          isLoading={messageStore.isStreaming()}
          placeholder={`Message ${agent()?.name || 'assistant'}...`}
        />
      </div>
    </Show>
  );
};
