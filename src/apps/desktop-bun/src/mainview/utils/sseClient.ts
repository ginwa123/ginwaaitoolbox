/**
 * SSE Client for receiving real-time updates from the backend
 */

export interface SSEMessage {
  type: 'message' | 'tool_result' | 'status' | 'error' | 'ping' | 'done' | 'step' | 'connected';
  content?: string;
  tool_name?: string;
  finish_reason?: string;
  session_id?: string;
  message_id?: string;
  role?: string;
  timestamp?: string;
}

export type SSEMessageHandler = (event: SSEMessage) => void;

/**
 * Parse XML content to extract SSE message data
 */
function parseSseXml(xmlData: string): SSEMessage {
  // Check for different response types in XML
  if (xmlData.includes('<response>')) {
    // Extract content from <content> tag
    const contentMatch = xmlData.match(/<content><!\[CDATA\[([\s\S]*?)\]\]><\/content>|<content>([\s\S]*?)<\/content>/);
    const content = contentMatch ? (contentMatch[1] || contentMatch[2] || '') : undefined;
    
    // Extract finish_reason
    const finishReasonMatch = xmlData.match(/<finish_reason>([\s\S]*?)<\/finish_reason>/);
    const finish_reason = finishReasonMatch ? finishReasonMatch[1].trim() : undefined;
    
    // Extract session_id
    const sessionIdMatch = xmlData.match(/<session_id>([\s\S]*?)<\/session_id>/);
    const session_id = sessionIdMatch ? sessionIdMatch[1].trim() : undefined;
    
    // Extract role
    const roleMatch = xmlData.match(/<role>([\s\S]*?)<\/role>/);
    const role = roleMatch ? roleMatch[1].trim() : 'assistant';
    
    // Check if this is a final chunk (has finish_reason)
    const type = finish_reason ? 'done' : 'message';
    
    return {
      type,
      content,
      finish_reason,
      session_id,
      role: role as SSEMessage['role'],
    };
  }
  
  if (xmlData.includes('<tool_result>')) {
    return { type: 'tool_result' };
  }
  
  // Default to message type
  return { type: 'message', content: xmlData };
}

export class SSEClient {
  private eventSource: EventSource | null = null;
  private handlers: SSEMessageHandler[] = [];
  private sessionId: string | null = null;
  private reconnectAttempts = 0;
  private maxReconnectAttempts = 5;
  private reconnectDelay = 1000;
  private baseUrl: string;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl;
  }

  /**
   * Check if currently connected to a session
   */
  isConnected(): boolean {
    return this.eventSource !== null && this.sessionId !== null;
  }

  /**
   * Get the current session ID
   */
  getSessionId(): string | null {
    return this.sessionId;
  }

  /**
   * Disconnect and notify server to clean up SSE connection
   */
  async disconnectWithNotification(): Promise<void> {
    const sessionId = this.sessionId;
    
    // Disconnect locally first (always succeeds)
    this.disconnect();
    
    // Then notify server (non-blocking, ignore failures)
    if (sessionId) {
      console.log('[SSEClient] Notifying server of disconnect:', sessionId);
      fetch(`${this.baseUrl}/api/stream/${encodeURIComponent(sessionId)}/disconnect`, {
        method: 'POST',
      }).catch((err) => {
        console.warn('[SSEClient] Server disconnect notification failed (ignoring):', err);
      });
    }
  }

  connect(sessionId: string): void {
    this.disconnect();
    this.sessionId = sessionId;
    this.reconnectAttempts = 0;

    const url = `${this.baseUrl}/api/stream/${encodeURIComponent(sessionId)}`;
    console.log('[SSEClient] Connecting to:', url);

    try {
      this.eventSource = new EventSource(url);

      this.eventSource.onopen = () => {
        console.log('[SSEClient] Connected to SSE stream');
        this.reconnectAttempts = 0;
      };

      this.eventSource.onerror = (error) => {
        console.error('[SSEClient] SSE error:', error);
        this.handleError();
      };

      // Listen for 'connected' event (sent by server as JSON)
      this.eventSource.addEventListener('connected', (event: MessageEvent) => {
        try {
          const data = JSON.parse(event.data) as SSEMessage;
          data.type = 'connected';
          console.log('[SSEClient] Received connected:', data);
          this.notifyHandlers(data);
        } catch (err) {
          console.error('[SSEClient] Failed to parse connected event:', err);
        }
      });

      // Listen for 'message' event (default SSE event type - all unnamed events come through here)
      this.eventSource.addEventListener('message', (event: MessageEvent) => {
        try {
          console.log('[SSEClient] Received raw message:', event.data);
          // Parse XML content to determine message type
          const data = parseSseXml(event.data);
          console.log('[SSEClient] Parsed message:', data);
          this.notifyHandlers(data);
        } catch (err) {
          console.error('[SSEClient] Failed to parse message event:', err);
        }
      });
    } catch (err) {
      console.error('[SSEClient] Failed to create EventSource:', err);
    }
  }

  disconnect(): void {
    if (this.eventSource) {
      console.log('[SSEClient] Disconnecting SSE stream');
      this.eventSource.close();
      this.eventSource = null;
    }
    this.sessionId = null;
  }

  addHandler(handler: SSEMessageHandler): () => void {
    this.handlers.push(handler);
    return () => {
      this.handlers = this.handlers.filter((h) => h !== handler);
    };
  }

  removeHandler(handler: SSEMessageHandler): void {
    this.handlers = this.handlers.filter((h) => h !== handler);
  }

  clearHandlers(): void {
    this.handlers = [];
  }

  private notifyHandlers(event: SSEMessage): void {
    this.handlers.forEach((handler) => {
      try {
        handler(event);
      } catch (err) {
        console.error('[SSEClient] Handler error:', err);
      }
    });
  }

  private handleError(): void {
    if (!this.sessionId) return;

    if (this.reconnectAttempts < this.maxReconnectAttempts) {
      this.reconnectAttempts++;
      const delay = this.reconnectDelay * this.reconnectAttempts;
      console.log(`[SSEClient] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts})`);
      setTimeout(() => {
        if (this.sessionId) {
          this.connect(this.sessionId);
        }
      }, delay);
    } else {
      console.error('[SSEClient] Max reconnect attempts reached');
    }
  }
}
