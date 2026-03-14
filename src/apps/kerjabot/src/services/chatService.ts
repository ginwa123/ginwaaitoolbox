/**
 * Chat service with real backend integration
 * Uses SSE for streaming responses from the Zig backend
 */

import type { MessageStreamChunk, ToolCall, ToolResult } from '~/types';
import { backendApi } from './backendApi';

/** Stream callback type */
type StreamCallback = (chunk: MessageStreamChunk) => void;

/**
 * Stream a message response from the backend
 */
export const streamMessage = async (
  sessionId: string,
  content: string,
  onChunk: StreamCallback,
  options?: { cwd?: string }
): Promise<void> => {
  const cwd = options?.cwd || '';
  
  await backendApi.streamMessage(sessionId, content, onChunk, cwd);
};

/**
 * Send a message without streaming (for simple requests)
 */
export const sendMessage = async (
  sessionId: string,
  content: string,
  cwd?: string
): Promise<{ content: string; toolCalls?: ToolCall[] }> => {
  return new Promise((resolve, reject) => {
    let fullContent = '';
    const toolCalls: ToolCall[] = [];

    backendApi.streamMessage(
      sessionId,
      content,
      (chunk) => {
        if (chunk.content) {
          fullContent += chunk.content;
        }
        if (chunk.toolCall) {
          toolCalls.push(chunk.toolCall);
        }
        if (chunk.isComplete) {
          resolve({
            content: fullContent,
            toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
          });
        }
      },
      cwd
    ).catch(reject);
  });
};

/**
 * Execute a tool (for tool calls from the backend)
 */
export const executeTool = async (toolCall: ToolCall): Promise<ToolResult> => {
  return backendApi.executeTool(toolCall);
};

/**
 * Cancel an ongoing stream
 */
export const cancelStream = (sessionId: string): void => {
  backendApi.cancelRequest(sessionId);
};

/**
 * Create a new session
 */
export const createSession = async (agentType?: string): Promise<{ sessionId: string }> => {
  return backendApi.createSession(agentType);
};

/**
 * Get all sessions
 */
export const getSessions = async (): Promise<{ sessions: any[] }> => {
  return backendApi.getSessions();
};

/**
 * Check if backend is available
 */
export const checkBackend = async (): Promise<boolean> => {
  return backendApi.checkBackend();
};

/**
 * Ping session to keep alive
 */
export const pingSession = async (sessionId: string): Promise<boolean> => {
  return backendApi.pingSession(sessionId);
};

/**
 * Chat service API
 */
export const chatService = {
  streamMessage,
  sendMessage,
  executeTool,
  cancelStream,
  createSession,
  getSessions,
  checkBackend,
  pingSession,
};
