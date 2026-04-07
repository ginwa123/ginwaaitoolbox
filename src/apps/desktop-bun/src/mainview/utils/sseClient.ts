/**
 * SSE Client for receiving real-time updates from the backend
 */
import { log } from './logger';

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
function extractXmlTag(xml: string, tag: string): string | undefined {
  const escapedTag = tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const regex = new RegExp(`<${escapedTag}>([\\s\\S]*?)<\\/${escapedTag}>`, 'i');
  const match = xml.match(regex);
  return match ? match[1].trim() : undefined;
}

/**
 * Parse the inner content field produced by the model.
 *
 * The model is prompted to wrap its output in one of:
 *   <markdown>…</markdown>   – for markdown responses
 *   <plain>…</plain>         – for plain-text responses
 *   <think>…</think>         – for internal reasoning (may appear alongside the above)
 *
 * All three tags may be present in the same content string.
 */
export function parseContentField(content: string): ParsedContent {
  return {
    raw: content,
    thinking: extractXmlTag(content, 'think'),
    markdown: extractXmlTag(content, 'markdown'),
    plain: extractXmlTag(content, 'plain'),
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
    result.session_id = extractXmlTag(xmlData, 'session_id');
    result.model = extractXmlTag(xmlData, 'model');
    result.cwd = extractXmlTag(xmlData, 'cwd');

    // Extract raw content (supports nested tags like <think>, <markdown>, <plain>)
    const rawContent = extractXmlTag(xmlData, 'content');
    if (rawContent) {
      result.content = rawContent;
      result.parsed_content = parseContentField(rawContent);
    }

    result.reasoning_content = extractXmlTag(xmlData, 'reasoning_content');
    result.role = extractXmlTag(xmlData, 'role') || 'assistant';
    result.finish_reason = extractXmlTag(xmlData, 'finish_reason');
    result.tool_call_id = extractXmlTag(xmlData, 'tool_call_id');
    result.tool_name = extractXmlTag(xmlData, 'tool_name');
    result.agent_name = extractXmlTag(xmlData, 'agent_name');
    result.session_name = extractXmlTag(xmlData, 'session_name');

    const loopIndex = extractXmlTag(xmlData, 'loop_index');
    result.loop_index = loopIndex ? Number.parseInt(loopIndex, 10) : undefined;

    const temp = extractXmlTag(xmlData, 'temperature');
    result.temperature = temp ? Number.parseFloat(temp) : undefined;

    result.is_thinking = extractXmlTag(xmlData, 'is_thinking') === 'true';
    result.is_input = extractXmlTag(xmlData, 'is_input') === 'true';
    result.is_output = extractXmlTag(xmlData, 'is_output') === 'true';

    result.parent_session_id = extractXmlTag(xmlData, 'parent_session_id');
    result.parent_id = extractXmlTag(xmlData, 'parent_id');

    // Parse tool_calls if present
    const toolCallsMatch = xmlData.match(/<tool_calls>([\s\S]*?)<\/tool_calls>/);
    if (toolCallsMatch) {
      const toolCallsXml = toolCallsMatch[1];
      const toolCallMatches = toolCallsXml.matchAll(/<tool_call>([\s\S]*?)<\/tool_call>/g);
      result.tool_calls = [];
      for (const tcMatch of toolCallMatches) {
        const tcContent = tcMatch[1];
        result.tool_calls.push({
          id: extractXmlTag(tcContent, 'id') || '',
          name: extractXmlTag(tcContent, 'name') || '',
          arguments: extractXmlTag(tcContent, 'arguments') || '',
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
        result.content = chunkContentMatch[1];
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

    const url = `${this.baseUrl}/api/stream/${encodeURIComponent(sessionId)}`;
    log.info('[SSEClient] Connecting to:', url);

    try {
      this.eventSource = new EventSource(url);

      this.eventSource.onopen = () => {
        log.info('[SSEClient] Connected to SSE stream');
        this.reconnectAttempts = 0;
        // Send connected event
        this.notifyHandlers({ type: 'connected', session_id: sessionId });
      };

      this.eventSource.onerror = (error) => {
        log.error('[SSEClient] SSE error:', error);
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

          log.info(`[SSEClient] Received message: ${rawData}`);

          const parsed = parseSseXml(rawData);

          log.info(`[SSEClient] Parsed message: ${JSON.stringify(parsed)}`);

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
        } catch (err) {
          log.error('[SSEClient] Failed to parse message event:', err, err.stack);
        }
      });
    } catch (err) {
      log.error('[SSEClient] Failed to create EventSource:', err);
    }
  }

  disconnect(): void {
    if (this.eventSource) {
      log.info('[SSEClient] Disconnecting SSE stream');
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
