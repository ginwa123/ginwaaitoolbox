/**
 * SSE Client for receiving real-time updates from the backend
 *
 * Request tracking: 1 request = 1 GUID, all related logs share this ID
 */
import { log } from './logger';
import { end, generateRequestId, log as requestLog, start } from './requestTracker';
import { decodeXmlEntities, getTagValue, parseMessages } from './xmlParser';

export interface SSEMessage {
  type: 'message' | 'tool_result' | 'status' | 'error' | 'ping' | 'done' | 'step' | 'connected';
  content?: string;
  parsedContent?: ParsedContent;
  tool_name?: string;
  finish_reason?: string;
  session_id?: string;
  message_id?: string;
  role?: string;
  timestamp?: string;
}

/**
 * Parsed inner content from the model's response format.
 * The model wraps its content in <markdown>, <plain>, or <think> tags.
 */
export interface ParsedContent {
  /** Raw content string (unparsed) */
  raw: string;
  /** Markdown-formatted response, if the model used <markdown> tags */
  markdown?: string;
  /** Plain text response, if the model used <plain> tags */
  plain?: string;
  /** Internal reasoning / thinking, if the model used <think> tags */
  thinking?: string;
}

/**
 * Raw SSE message from server
 */
interface RawSSEEvent {
  session_id?: string;
  model?: string;
  cwd?: string;
  content?: string;
  parsed_content?: ParsedContent;
  reasoning_content?: string;
  role?: string;
  finish_reason?: string;
  tool_calls?: Array<{
    id: string;
    name: string;
    arguments: string;
  }>;
  tool_call_id?: string;
  tool_name?: string;
  agent_name?: string;
  session_name?: string;
  loop_index?: number;
  temperature?: number;
  is_thinking?: boolean;
  is_input?: boolean;
  is_output?: boolean;
  parent_session_id?: string;
  parent_id?: string;
}

export type SSEMessageHandler = (event: SSEMessage) => void;

/**
 * Extract text content from an XML tag, supporting nested tags inside.
 * Uses [\s\S]*? (lazy dot-all) instead of [^<]* so it can match across
 * nested tags like <think>...</think> or <markdown>...</markdown>.
 */

/**
 * Parse the inner content field produced by the model.
 *
 * The model is prompted to wrap its output in one of:
 *   <markdown>…</markdown>   – for markdown responses
 *   <plain>…</plain>         – for plain-text responses
 *   <think>…</think>         – for internal reasoning (may appear alongside the above)
 *
 * All three tags may be present in the same content string.
 *
 * NOTE: <think> uses special markdown-style notation (not standard XML tags),
 * so we need regex to match it properly.
 */
export function parseContentField(content: string): ParsedContent {
  // Helper to extract content from <think>...</think> style tags (markdown notation)
  // NOTE: The closing tag is </think> (not </think>) so we must match it correctly
  const extractThinkContent = (text: string): string | undefined => {
    const match = text.match(/<think>([\s\S]*?)<\/think>/i);
    if (match) return match[1].trim();

    // Also try matching with </think> as closing tag
    const match2 = text.match(/<think>([\s\S]*?)<\/think>/i);
    return match2 ? match2[1].trim() : undefined;
  };

  // Helper to convert empty string to undefined (getTagValue returns '' if not found)
  const fromTag = (tag: string): string | undefined => {
    const val = getTagValue(content, tag);
    return val || undefined;
  };

  return {
    raw: content,
    thinking: extractThinkContent(content),
    markdown: fromTag('markdown'),
    plain: fromTag('plain'),
  };
}

/**
 * Parse XML content to extract SSE message data
 */
export function parseSseXml(xmlData: string): RawSSEEvent {
  const result: RawSSEEvent = {};

  // Skip empty data
  if (!xmlData || xmlData.trim().length === 0) {
    log.warn('[SSEClient] parseSseXml: empty XML data');
    return result;
  }

  // Check if this is a <response> tag (the main event format)
  if (xmlData.includes('<response>')) {
    // Extract all known fields from XML
    result.session_id = getTagValue(xmlData, 'session_id') || undefined;
    result.model = getTagValue(xmlData, 'model') || undefined;
    result.cwd = getTagValue(xmlData, 'cwd') || undefined;

    // Extract raw content (supports nested tags like <think>, <markdown>, <plain>)
    const rawContent = getTagValue(xmlData, 'content');
    if (rawContent) {
      // Decode XML entities in content
      result.content = decodeXmlEntities(rawContent);
      result.parsed_content = parseContentField(result.content);
    }

    result.reasoning_content = getTagValue(xmlData, 'reasoning_content') || undefined;
    result.role = getTagValue(xmlData, 'role') || 'assistant';
    result.finish_reason = getTagValue(xmlData, 'finish_reason') || undefined;
    result.tool_call_id = getTagValue(xmlData, 'tool_call_id') || undefined;
    result.tool_name = getTagValue(xmlData, 'tool_name') || undefined;
    result.agent_name = getTagValue(xmlData, 'agent_name') || undefined;
    result.session_name = getTagValue(xmlData, 'session_name') || undefined;

    const loopIndex = getTagValue(xmlData, 'loop_index');
    result.loop_index = loopIndex ? Number.parseInt(loopIndex, 10) : undefined;

    const temp = getTagValue(xmlData, 'temperature');
    result.temperature = temp ? Number.parseFloat(temp) : undefined;

    result.is_thinking = getTagValue(xmlData, 'is_thinking') === 'true';
    result.is_input = getTagValue(xmlData, 'is_input') === 'true';
    result.is_output = getTagValue(xmlData, 'is_output') === 'true';

    result.parent_session_id = getTagValue(xmlData, 'parent_session_id') || undefined;
    result.parent_id = getTagValue(xmlData, 'parent_id') || undefined;

    // Parse tool_calls if present
    const toolCallsMatch = xmlData.match(/<tool_calls>([\s\S]*?)<\/tool_calls>/);
    if (toolCallsMatch) {
      const toolCallsXml = toolCallsMatch[1];
      const toolCallMatches = toolCallsXml.matchAll(/<tool_call>([\s\S]*?)<\/tool_call>/g);
      result.tool_calls = [];
      for (const tcMatch of toolCallMatches) {
        const tcContent = tcMatch[1];
        result.tool_calls.push({
          id: getTagValue(tcContent, 'id') || '',
          name: getTagValue(tcContent, 'name') || '',
          // Decode XML entities in arguments
          arguments: decodeXmlEntities(getTagValue(tcContent, 'arguments')),
        });
      }
    }

    // Handle streaming chunk format: <chunk index="0"><content>...</content></chunk>
    const chunkMatch = xmlData.match(/<chunk[^>]*index="(\d+)"[^>]*>([\s\S]*?)<\/chunk>/);
    if (chunkMatch) {
      const chunkContent = chunkMatch[2];

      // Extract content from chunk (may itself contain <markdown>/<plain>/<think>)
      const chunkContentMatch = chunkContent.match(/<content>([\s\S]*?)<\/content>/);
      if (chunkContentMatch) {
        const chunkRawContent = chunkContentMatch[1];
        result.content = decodeXmlEntities(chunkRawContent);
        result.parsed_content = parseContentField(result.content);
      }

      // Extract reasoning from chunk
      const chunkReasoningMatch = chunkContent.match(
        /<reasoning_content>([\s\S]*?)<\/reasoning_content>/
      );
      if (chunkReasoningMatch) {
        result.reasoning_content = chunkReasoningMatch[1];
      }

      // Check if this is the final chunk (has final="true" or has usage)
      if (xmlData.includes('final="true"') || xmlData.includes('<usage>')) {
        result.finish_reason = 'stop';
      }
    }
  }

  return result;
}

/**
 * Determine event type from parsed XML data
 */
function determineEventType(data: RawSSEEvent): SSEMessage['type'] {
  if (data.finish_reason) {
    // Has finish_reason means this is a final/done message
    return 'done';
  }
  if (data.tool_call_id || data.tool_name) {
    // Has tool info means this is a tool result
    return 'tool_result';
  }
  return 'message';
}

export class SSEClient {
  private eventSource: EventSource | null = null;
  private handlers: SSEMessageHandler[] = [];
  private sessionId: string | null = null;
  private reconnectAttempts = 0;
  private maxReconnectAttempts = 5;
  private reconnectDelay = 1000;
  private baseUrl: string;
  private isIntentionalDisconnect = false;

  // Request tracking: 1 request = 1 GUID
  private requestId: string | null = null;
  private eventIndex = 0;

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
   * Get the current request ID (1 request = 1 GUID)
   */
  getRequestId(): string | null {
    return this.requestId;
  }

  /**
   * Start a new request tracking session
   */
  startRequest(): string {
    if (!this.sessionId) {
      log.warn('[SSEClient] Cannot start request without active session');
      return '';
    }
    this.requestId = generateRequestId();
    this.eventIndex = 0;
    start(this.requestId, this.sessionId);
    log.info(`[SSEClient] Started request tracking: ${this.requestId}`);
    return this.requestId;
  }

  /**
   * Track an event with the current request
   */
  trackEvent(_type: string, _content?: string): { requestId: string; eventIndex: number } {
    this.eventIndex++;
    return { requestId: this.requestId || 'none', eventIndex: this.eventIndex };
  }

  /**
   * End the current request tracking session
   */
  endRequest(): void {
    if (this.requestId) {
      log.info(
        `[SSEClient] Ending request tracking: ${this.requestId} (${this.eventIndex} events)`
      );
      end(this.requestId);
      this.requestId = null;
      this.eventIndex = 0;
    }
  }

  /**
   * Disconnect and notify server to clean up SSE connection
   */
  async disconnectWithNotification(): Promise<void> {
    const sessionId = this.sessionId;
    this.isIntentionalDisconnect = true;

    // Disconnect locally first (always succeeds)
    this.disconnect();

    // Then notify server (non-blocking, ignore failures)
    if (sessionId) {
      log.info('[SSEClient] Notifying server of disconnect:', sessionId);
      fetch(`${this.baseUrl}/api/stream/${encodeURIComponent(sessionId)}/disconnect`, {
        method: 'POST',
      }).catch((err) => {
        log.warn('[SSEClient] Server disconnect notification failed (ignoring):', err);
      });
    }
  }

  connect(sessionId: string): void {
    // Skip if already connected to the same session
    if (this.eventSource && this.sessionId === sessionId) {
      log.info('[SSEClient] Already connected to session:', sessionId);
      return;
    }

    // Reset intentional disconnect flag
    this.isIntentionalDisconnect = false;

    // Disconnect any existing connection first
    this.disconnect();

    this.sessionId = sessionId;
    this.reconnectAttempts = 0;

    // Start request tracking for this session
    this.requestId = generateRequestId();
    this.eventIndex = 0;
    start(this.requestId, sessionId);

    const url = `${this.baseUrl}/api/stream/${encodeURIComponent(sessionId)}`;
    log.info(`[SSEClient] Connecting to: ${url}`, { id: this.requestId });

    try {
      this.eventSource = new EventSource(url);

      this.eventSource.onopen = () => {
        log.info('[SSEClient] Connected to SSE stream', { id: this.requestId || undefined });
        this.reconnectAttempts = 0;
        // Send connected event
        this.notifyHandlers({ type: 'connected', session_id: sessionId });
      };

      this.eventSource.onerror = (error) => {
        log.error('[SSEClient] SSE error:', {
          id: this.requestId || undefined,
          extra: JSON.stringify(error),
        });
        if (!this.isIntentionalDisconnect) {
          this.handleError();
        }
      };

      // Listen for 'message' event (default SSE event type)
      this.eventSource.addEventListener('message', (event: MessageEvent) => {
        try {
          const rawData = event.data;

          // Skip empty or keepalive data
          if (!rawData || rawData.trim().length === 0) {
            return;
          }

          // Track event
          this.eventIndex++;
          const eventInfo = { requestId: this.requestId || 'none', eventIndex: this.eventIndex };
          requestLog(
            eventInfo.requestId,
            'info',
            `Event #${eventInfo.eventIndex} received`,
            `type=${event.type}, len=${rawData.length}`
          );

          // logging raw data
          requestLog(eventInfo.requestId, 'info', `Raw data: ${rawData}`);

          const parsed = parseMessages(rawData);

          requestLog(
            eventInfo.requestId,
            'info',
            `Event #${eventInfo.eventIndex} parsed`,
            `type=${determineEventType(parsed)}, hasContent=${!!parsed.content}`
          );

          const sseMsg: SSEMessage = {
            type: determineEventType(parsed),
            content: parsed.content,
            parsedContent: parsed.parsed_content,
            finish_reason: parsed.finish_reason,
            session_id: parsed.session_id,
            role: parsed.role,
            tool_name: parsed.tool_name,
            timestamp: parsed.session_id ? String(Date.now()) : undefined,
          };
          this.notifyHandlers(sseMsg);

          // Log completion of request
          if (sseMsg.type === 'done') {
            requestLog(
              eventInfo.requestId,
              'info',
              'Request completed',
              `finish_reason=${sseMsg.finish_reason}`
            );
          }
        } catch (err) {
          requestLog(
            this.requestId || 'none',
            'error',
            'Failed to parse message event',
            String(err)
          );
        }
      });
    } catch (err) {
      log.error('[SSEClient] Failed to create EventSource:', {
        id: this.requestId || undefined,
        extra: String(err),
      });
    }
  }

  disconnect(): void {
    // End request tracking first
    this.endRequest();

    if (this.eventSource) {
      log.info('[SSEClient] Disconnecting SSE stream', { id: this.requestId || undefined });
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
    for (const handler of this.handlers) {
      try {
        handler(event);
      } catch (err) {
        log.error('[SSEClient] Handler error:', err);
      }
    }
  }

  private handleError(): void {
    if (!this.sessionId || this.isIntentionalDisconnect) return;

    if (this.reconnectAttempts < this.maxReconnectAttempts) {
      this.reconnectAttempts++;
      const delay = this.reconnectDelay * this.reconnectAttempts;
      log.info(`[SSEClient] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts})`);
      setTimeout(() => {
        if (this.sessionId && !this.isIntentionalDisconnect) {
          this.connect(this.sessionId);
        }
      }, delay);
    } else {
      log.error('[SSEClient] Max reconnect attempts reached');
    }
  }
}
