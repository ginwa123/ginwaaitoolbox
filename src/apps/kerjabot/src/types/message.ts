/**
 * Message type definitions for Kerjabot
 * Defines message structures for conversations between users and agents
 */

import type { ToolCall, ToolResult } from './tool';

/** Message role types */
export enum Role {
  User = 'user',
  Assistant = 'assistant',
  System = 'system',
  Tool = 'tool',
}

/** Base message interface with common properties */
export interface BaseMessage {
  readonly id: string;
  readonly role: Role;
  readonly timestamp: Date;
  readonly sessionId: string;
}

/** User message sent by the human user */
export interface UserMessage extends BaseMessage {
  readonly role: Role.User;
  readonly content: string;
  readonly attachments?: readonly Attachment[];
}

/** Assistant message from the AI agent */
export interface AssistantMessage extends BaseMessage {
  readonly role: Role.Assistant;
  readonly content: string;
  readonly reasoning?: string;
  readonly toolCalls?: readonly ToolCall[];
  readonly isStreaming?: boolean;
  readonly model?: string;
  readonly tokenCount?: TokenCount;
}

/** System message for notifications or status updates */
export interface SystemMessage extends BaseMessage {
  readonly role: Role.System;
  readonly content: string;
  readonly level: SystemMessageLevel;
}

/** Tool message containing tool execution results */
export interface ToolMessage extends BaseMessage {
  readonly role: Role.Tool;
  readonly toolCallId: string;
  readonly toolName: string;
  readonly result: ToolResult;
}

/** Discriminated union of all message types */
export type Message = UserMessage | AssistantMessage | SystemMessage | ToolMessage;

/** System message severity levels */
export enum SystemMessageLevel {
  Info = 'info',
  Warning = 'warning',
  Error = 'error',
  Success = 'success',
}

/** File attachment for user messages */
export interface Attachment {
  readonly id: string;
  readonly name: string;
  readonly type: string;
  readonly size: number;
  readonly content?: string;
}

/** Token count information */
export interface TokenCount {
  readonly prompt: number;
  readonly completion: number;
  readonly total: number;
}

/** Message stream chunk for streaming responses */
export interface MessageStreamChunk {
  readonly id: string;
  readonly content?: string;
  readonly reasoning?: string;
  readonly toolCall?: ToolCall;
  readonly isComplete: boolean;
}

/** Generate unique message ID */
function generateMessageId(): string {
  return `msg_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
}

/** Message creation helpers */
export const createUserMessage = (
  content: string,
  sessionId: string,
  id?: string
): UserMessage => ({
  id: id ?? generateMessageId(),
  role: Role.User,
  content,
  timestamp: new Date(),
  sessionId,
});

export const createAssistantMessage = (
  content: string,
  sessionId: string,
  id?: string
): AssistantMessage => ({
  id: id ?? generateMessageId(),
  role: Role.Assistant,
  content,
  timestamp: new Date(),
  sessionId,
});

export const createSystemMessage = (
  content: string,
  sessionId: string,
  level: SystemMessageLevel = SystemMessageLevel.Info,
  id?: string
): SystemMessage => ({
  id: id ?? generateMessageId(),
  role: Role.System,
  content,
  level,
  timestamp: new Date(),
  sessionId,
});

export const createToolMessage = (
  toolCallId: string,
  toolName: string,
  result: ToolResult,
  sessionId: string,
  id?: string
): ToolMessage => ({
  id: id ?? generateMessageId(),
  role: Role.Tool,
  toolCallId,
  toolName,
  result,
  timestamp: new Date(),
  sessionId,
});
