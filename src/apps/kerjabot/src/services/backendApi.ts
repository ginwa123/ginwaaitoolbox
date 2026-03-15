/**
 * Backend API service for kerjabot web app
 * Connects to the Zig backend via HTTP/SSE
 */

import type { MessageStreamChunk, ToolCall, ToolResult } from '~/types';

/** EventSource for SSE */
let eventSource: EventSource | null = null;

/** Stream callback type */
type StreamCallback = (chunk: MessageStreamChunk) => void;

/**
 * Create a new session
 */
export const createSession = async (agentType: string = 'general'): Promise<{ sessionId: string }> => {
  const response = await fetch('/api/session/create', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      agent_type: agentType,
    }),
  });

  if (!response.ok) {
    throw new Error(`Failed to create session: ${response.status}`);
  }

  return response.json();
};

/**
 * Get all sessions
 */
export const getSessions = async (): Promise<{ sessions: any[] }> => {
  const response = await fetch('/api/command', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      app_type: 'web',
      command_type: 'get_sessions',
    }),
  });

  if (!response.ok) {
    throw new Error(`Failed to get sessions: ${response.status}`);
  }

  return response.json();
};

/**
 * Send a message and stream response via SSE
 */
export const streamMessage = async (
  sessionId: string,
  content: string,
  callback: StreamCallback,
  cwd?: string
): Promise<void> => {
  // Close existing EventSource if any
  closeStream();

  // Create new EventSource for SSE
  const eventSourceUrl = `/api/stream/${sessionId}`;
  eventSource = new EventSource(eventSourceUrl);

  eventSource.onopen = async () => {
    console.log('SSE connected, sending message...');
    
    // Send the message via POST
    const response = await fetch('/api/command', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        app_type: 'web',
        command_type: 'run_llm',
        session_id: sessionId,
        content: content,
        cwd_session: cwd || '',
      }),
    });

    if (!response.ok) {
      console.error('Failed to send message:', response.status);
      callback({
        id: `error_${Date.now()}`,
        content: `Error: Failed to send message (${response.status})`,
        isComplete: true,
      });
      closeStream();
    }
  };

  eventSource.onmessage = (event) => {
    try {
      const data = event.data;
      
      // Skip empty data
      if (!data || data.trim() === '') {
        return;
      }

      // Parse SSE format: "data: {...}"
      if (data.startsWith('data: ')) {
        const jsonStr = data.slice(6); // Remove "data: " prefix
        
        // Check for connected event
        if (jsonStr.includes('"event":"connected"')) {
          console.log('SSE received connected event');
          return;
        }

        try {
          const parsed = JSON.parse(jsonStr);
          
          // Handle different event types
          if (parsed.event === 'connected') {
            console.log('Session connected');
            return;
          }

          if (parsed.content) {
            callback({
              id: parsed.id || `chunk_${Date.now()}`,
              content: parsed.content,
              isComplete: parsed.is_complete || parsed.done || false,
              reasoning: parsed.reasoning,
            });
          }

          // Handle tool calls
          if (parsed.tool_call) {
            callback({
              id: parsed.id || `tool_${Date.now()}`,
              toolCall: parsed.tool_call,
              isComplete: false,
            });
          }

          // Check if complete
          if (parsed.is_complete || parsed.done) {
            callback({
              id: parsed.id || `complete_${Date.now()}`,
              content: '',
              isComplete: true,
            });
            closeStream();
          }
        } catch (e) {
          // Not JSON, treat as plain content
          callback({
            id: `chunk_${Date.now()}`,
            content: jsonStr,
            isComplete: false,
          });
        }
      }
    } catch (e) {
      console.error('Error parsing SSE data:', e);
    }
  };

  eventSource.onerror = (error) => {
    console.error('SSE error:', error);
    callback({
      id: `error_${Date.now()}`,
      content: '\n\n[Connection closed]',
      isComplete: true,
    });
    closeStream();
  };
};

/**
 * Close the SSE stream
 */
export const closeStream = (): void => {
  if (eventSource) {
    eventSource.close();
    eventSource = null;
  }
};

/**
 * Cancel ongoing request
 */
export const cancelRequest = async (sessionId: string): Promise<void> => {
  closeStream();

  await fetch('/api/command', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      app_type: 'web',
      command_type: 'cancel',
      session_id: sessionId,
    }),
  });
};

/**
 * Send ping to keep session alive
 */
export const pingSession = async (sessionId: string): Promise<boolean> => {
  try {
    // Use the new synchronous ping endpoint
    const response = await fetch(`/api/ping/${sessionId}`);

    if (!response.ok) {
      return false;
    }

    const data = await response.json();
    return data.reconnect === true;
  } catch {
    return false;
  }
};

/**
 * Execute a tool directly (for when backend sends tool call)
 */
export const executeTool = async (toolCall: ToolCall): Promise<ToolResult> => {
  // This would be handled by the backend, but we can provide
  // a client-side fallback for some tools
  const startTime = Date.now();
  const timestamp = new Date();

  switch (toolCall.type) {
    case 'bash': {
      const { command: _command } = toolCall.arguments as { command: string };
      // Note: Bash execution should be done server-side for security
      // This is just a placeholder
      return {
        success: false,
        duration: Date.now() - startTime,
        output: 'Bash execution must be done server-side',
        error: 'Cannot execute bash from browser',
        timestamp,
      };
    }

    default:
      return {
        success: false,
        duration: Date.now() - startTime,
        output: '',
        error: `Unknown tool type: ${toolCall.type}`,
        timestamp,
      };
  }
};

/**
 * Check if backend is available
 */
export const checkBackend = async (): Promise<boolean> => {
  try {
    // Use the ping endpoint with empty session_id to check if server is up
    const response = await fetch('/api/ping/health-check');
    return response.ok;
  } catch {
    return false;
  }
};

/**
 * Backend API service
 */
export const backendApi = {
  createSession,
  getSessions,
  streamMessage,
  closeStream,
  cancelRequest,
  pingSession,
  executeTool,
  checkBackend,
};
