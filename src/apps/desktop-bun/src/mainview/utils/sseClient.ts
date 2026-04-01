/**
 * SSE Client for receiving real-time updates from the backend
 */

export interface SSEMessage {
  type: 'message' | 'tool_result' | 'status' | 'error' | 'ping' | 'done' | 'step';
  content?: string;
  tool_name?: string;
  finish_reason?: string;
  session_id?: string;
  message_id?: string;
  role?: string;
  timestamp?: string;
}

export type SSEMessageHandler = (event: SSEMessage) => void;

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
    if (this.sessionId) {
      console.log('[SSEClient] Notifying server of disconnect:', this.sessionId);
      try {
        await fetch(`${this.baseUrl}/api/stream/${encodeURIComponent(this.sessionId)}/disconnect`, {
          method: 'POST',
          signal: AbortSignal.timeout(2000),
        });
      } catch (err) {
        console.warn('[SSEClient] Failed to notify server of disconnect:', err);
      }
    }
    this.disconnect();
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

      // Listen for all message types
      const eventTypes = ['message', 'tool_result', 'status', 'error', 'done', 'step', 'ping'];
      eventTypes.forEach((type) => {
        this.eventSource?.addEventListener(type, (event: MessageEvent) => {
          try {
            const data = JSON.parse(event.data) as SSEMessage;
            data.type = type as SSEMessage['type'];
            console.log(`[SSEClient] Received ${type}:`, data);
            this.notifyHandlers(data);
          } catch (err) {
            console.error(`[SSEClient] Failed to parse ${type} event:`, err);
          }
        });
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
