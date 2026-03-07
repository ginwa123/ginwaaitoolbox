/**
 * Chat service with streaming message simulation
 * Mock implementation for frontend-only development
 */

import type { MessageStreamChunk, ToolCall, ToolResult } from '~/types';
import { ToolType, createToolCall, createToolResult } from '~/types';

/** Stream callback type */
type StreamCallback = (chunk: MessageStreamChunk) => void;

/** Mock response generator */
const generateMockResponse = (userMessage: string): string => {
  const responses = [
    `I understand you're asking about "${userMessage}". Let me help you with that.`,
    `That's an interesting question about "${userMessage}". Here's what I think...`,
    `I'll analyze "${userMessage}" and provide you with a comprehensive response.`,
    `Regarding "${userMessage}", I can offer the following insights.`,
    `Let me process your request about "${userMessage}" and get back to you.`,
  ];
  return responses[Math.floor(Math.random() * responses.length)];
};

/** Simulate streaming response */
export const streamMessage = async (
  userMessage: string,
  onChunk: StreamCallback,
  options?: { delay?: number; includeToolCalls?: boolean }
): Promise<void> => {
  const delay = options?.delay ?? 50;
  const includeToolCalls = options?.includeToolCalls ?? Math.random() > 0.7;

  const response = generateMockResponse(userMessage);
  const words = response.split(' ');

  // Stream content word by word
  for (let i = 0; i < words.length; i++) {
    await sleep(delay);
    onChunk({
      id: `chunk_${i}`,
      content: (i > 0 ? ' ' : '') + words[i],
      isComplete: false,
    });
  }

  // Occasionally include a tool call
  if (includeToolCalls) {
    await sleep(delay * 2);
    const toolCall = createToolCall(
      ToolType.Bash,
      'bash',
      { command: 'echo "Hello from mock tool"' }
    );
    onChunk({
      id: 'chunk_tool',
      toolCall,
      isComplete: false,
    });

    // Simulate tool execution
    await sleep(delay * 3);
    onChunk({
      id: 'chunk_complete',
      content: '\n\n[Tool executed successfully]',
      isComplete: true,
    });
  } else {
    onChunk({
      id: 'chunk_complete',
      isComplete: true,
    });
  }
};

/** Simulate tool execution */
export const executeTool = async (
  toolCall: ToolCall
): Promise<ToolResult> => {
  const startTime = Date.now();

  // Simulate network delay
  await sleep(500 + Math.random() * 1000);

  const duration = Date.now() - startTime;

  // Mock tool execution results
  switch (toolCall.type) {
    case ToolType.Bash:
      return createToolResult(
        true,
        duration,
        `Executed: ${JSON.stringify(toolCall.arguments)}\nOutput: Mock bash output`,
        undefined,
        0
      );

    case ToolType.ReadFile:
      return createToolResult(
        true,
        duration,
        `// Mock file content\nconst example = "Hello World";`,
        undefined,
        0
      );

    case ToolType.ListDir:
      return createToolResult(
        true,
        duration,
        `file1.ts\nfile2.ts\nfolder/`,
        undefined,
        0
      );

    case ToolType.GetSkill:
      return createToolResult(
        true,
        duration,
        '# Skill Content\n\nThis is mock skill content.',
        undefined,
        0
      );

    default:
      return createToolResult(
        true,
        duration,
        `Mock result for ${toolCall.name}`,
        undefined,
        0
      );
  }
};

/** Send message without streaming */
export const sendMessage = async (
  message: string
): Promise<{ content: string; toolCalls?: ToolCall[] }> => {
  await sleep(1000);
  return {
    content: generateMockResponse(message),
  };
};

/** Cancel ongoing stream (mock) */
export const cancelStream = (): void => {
  // In a real implementation, this would abort the fetch request
  console.log('Stream cancelled');
};

/** Utility sleep function */
const sleep = (ms: number): Promise<void> => {
  return new Promise((resolve) => setTimeout(resolve, ms));
};

/** Chat service API */
export const chatService = {
  streamMessage,
  executeTool,
  sendMessage,
  cancelStream,
};
