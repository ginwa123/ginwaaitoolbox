/**
 * Message store using SolidJS signals
 * Manages message state with streaming support
 */

import { createSignal, createMemo, batch } from 'solid-js';
import type {
  Message,
  UserMessage,
  AssistantMessage,
  MessageStreamChunk,
  ToolResult,
} from '~/types';
import {
  Role,
  SystemMessageLevel,
  createUserMessage,
  createAssistantMessage,
  createSystemMessage,
  createToolMessage,
} from '~/types';

// Store state
const [messages, setMessages] = createSignal<Message[]>([], { equals: false });
const [streamingMessageId, setStreamingMessageId] = createSignal<string | null>(null);
const [isStreaming, setIsStreaming] = createSignal(false);

// Derived state
const messagesBySession = (sessionId: string) =>
  createMemo(() =>
    messages().filter((m) => m.sessionId === sessionId)
  );

const lastMessage = createMemo(() => {
  const msgs = messages();
  return msgs.length > 0 ? msgs[msgs.length - 1] : null;
});

const streamingMessage = createMemo(() => {
  const id = streamingMessageId();
  if (!id) return null;
  const msg = messages().find(
    (m): m is AssistantMessage => m.id === id && m.role === Role.Assistant
  );
  return msg ?? null;
});

// Actions
const addUserMessage = (content: string, sessionId: string): UserMessage => {
  const message = createUserMessage(content, sessionId);
  const current = messages();
  setMessages([...current, message as Message]);
  return message;
};

const startAssistantMessage = (sessionId: string): AssistantMessage => {
  const message = createAssistantMessage('', sessionId);
  batch(() => {
    const current = messages();
    setMessages([...current, message as Message]);
    setStreamingMessageId(message.id);
    setIsStreaming(true);
  });
  return message;
};

const appendToStreamingMessage = (chunk: MessageStreamChunk): void => {
  const streamId = streamingMessageId();
  if (!streamId) return;

  const current = messages();
  const updated = current.map((m) => {
    if (m.id !== streamId || m.role !== Role.Assistant) return m;

    const assistantMsg = m as AssistantMessage;
    const updatedMsg: AssistantMessage = {
      ...assistantMsg,
      content: chunk.content
        ? assistantMsg.content + chunk.content
        : assistantMsg.content,
      reasoning: chunk.reasoning
        ? (assistantMsg.reasoning ?? '') + chunk.reasoning
        : assistantMsg.reasoning,
      toolCalls: chunk.toolCall
        ? [...(assistantMsg.toolCalls ?? []), chunk.toolCall]
        : assistantMsg.toolCalls,
    };
    return updatedMsg as Message;
  });
  setMessages(updated);

  if (chunk.isComplete) {
    batch(() => {
      setStreamingMessageId(null);
      setIsStreaming(false);
    });
  }
};

const addSystemMessage = (
  content: string,
  sessionId: string,
  level: SystemMessageLevel = SystemMessageLevel.Info
): void => {
  const message = createSystemMessage(content, sessionId, level);
  const current = messages();
  setMessages([...current, message as Message]);
};

const addToolMessage = (
  toolCallId: string,
  toolName: string,
  result: ToolResult,
  sessionId: string
): void => {
  const message = createToolMessage(toolCallId, toolName, result, sessionId);
  const current = messages();
  setMessages([...current, message as Message]);
};

const clearSessionMessages = (sessionId: string): void => {
  setMessages((prev) => prev.filter((m) => m.sessionId !== sessionId));
};

const updateMessage = (id: string, updates: Partial<Message>): void => {
  setMessages((prev) =>
    prev.map((m) => (m.id === id ? { ...m, ...updates } : m))
  );
};

const removeMessage = (id: string): void => {
  setMessages((prev) => prev.filter((m) => m.id !== id));
};

const cancelStreaming = (): void => {
  batch(() => {
    setStreamingMessageId(null);
    setIsStreaming(false);
  });
};

// Export store API
export const messageStore = {
  // State
  messages,
  streamingMessageId,
  isStreaming,
  lastMessage,
  streamingMessage,

  // Derived
  messagesBySession,

  // Actions
  addUserMessage,
  startAssistantMessage,
  appendToStreamingMessage,
  addSystemMessage,
  addToolMessage,
  clearSessionMessages,
  updateMessage,
  removeMessage,
  cancelStreaming,
};
