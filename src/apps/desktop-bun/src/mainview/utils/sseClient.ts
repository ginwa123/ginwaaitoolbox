/**
 * SSE Client for real-time communication with the backend
 *
 * Handles Server-Sent Events (SSE) for streaming responses and tool call updates.
 * Supports both JSON format (primary) and legacy XML format (backwards compatibility).
 */
import { log, requestLog, start, end } from '../../shared/rpc';
import { detectFormat, parseMessages } from './messageParser';

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
 * Raw SSE message from server (JSON format)
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

export interface SSEMessage {
  type: 'message' | 'tool_result' | 'done' | 'connected' | 'error';
  content?: string;
  parsedContent?: ParsedContent;
  finish_reason?: string;
  session_id?: string;
  role?: string;
  tool_name?: string;
  timestamp?: string;
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
 *
 * NOTE: <think> uses special markdown-style notation (not standard XML tags),
 * so we need regex to match it properly.
 */
export function parseContentField(content: string): ParsedContent {
  // Helper to extract content from <think>...</think> style tags (markdown notation)
  const extractThinkContent = (text: string): string | undefined => {
    const match = text.match(/<think>([\s\S]*?)<\/think>/i);
    if (match) return match[1].trim();
    return undefined;
  };

  // Helper to convert empty string to undefined
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
 * Extract text content from an XML tag, supporting nested tags inside.
 */
function getTagValue(content: string, tag: string): string {
  const escapedTag = tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const regex = new RegExp(
    `<${escapedTag}>([^<]*(?:<(?!/${escapedTag}>)[^<]*)*)<\\/${escapedTag}>`,
    'i'
  );
  const match = content.match(regex);
  return match ? match[1].trim() : '';
}

/**
 * Decode XML entities
 */
function decodeXmlEntities(str: string | undefined | null): string {
  if (!str) return '';
  return str
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
}

/**
 * Parse JSON data to extract SSE message data
 */
function parseSseJson(data: unknown): RawSSEEvent {
  const result: RawSSEEvent = {};

  if (!data || typeof data !== 'object') {
    log.warn('[SSEClient] parseSseJson: invalid data');
    return result;
  }

  const obj = data as Record<string, unknown>;

  // Extract all known fields from JSON
  result.session_id = typeof obj.session_id === 'string' ? obj.session_id : undefined;
  result.model = typeof obj.model === 'string' ? obj.model : undefined;
  result.cwd = typeof obj.cwd === 'string' ? obj.cwd : undefined;

  // Content may still contain XML-style tags for markdown/plain/thinking
  if (typeof obj.content === 'string' && obj.content) {
    result.content = obj.content;
    result.parsed_content = parseContentField(obj.content);
  }

  result.reasoning_content = typeof obj.reasoning_content === 'string' ? obj.reasoning_content : undefined;
  result.role = typeof obj.role === 'string' ? obj.role : 'assistant';
  result.finish_reason = typeof obj.finish_reason === 'string' ? obj.finish_reason : undefined;
  result.tool_call_id = typeof obj.tool_call_id === 'string' ? obj.tool_call_id : undefined;
  result.tool_name = typeof obj.tool_name === 'string' ? obj.tool_name : undefined;
  result.agent_name = typeof obj.agent_name === 'string' ? obj.agent_name : undefined;
  result.session_name = typeof obj.session_name === 'string' ? obj.session_name : undefined;

  if (typeof obj.loop_index === 'number') {
    result.loop_index = obj.loop_index;
  }

  if (typeof obj.temperature === 'number') {
    result.temperature = obj.temperature;
  }

  if (typeof obj.is_thinking === 'boolean') {
    result.is_thinking = obj.is_thinking;
  }

  if (typeof obj.is_input === 'boolean') {
    result.is_input = obj.is_input;
  }

  if (typeof obj.is_output === 'boolean') {
    result.is_output = obj.is_output;
  }

  result.parent_session_id = typeof obj.parent_session_id === 'string' ? obj.parent_session_id : undefined;
  result.parent_id = typeof obj.parent_id === 'string' ? obj.parent_id : undefined;

  // Parse tool_calls array
  if (Array.isArray(obj.tool_calls)) {
    result.tool_calls = obj.tool_calls.map((tc) => {
      const toolCall = tc as Record<string, unknown>;
      return {
        id: typeof toolCall.id === 'string' ? toolCall.id : '',
        name: typeof toolCall.name === 'string' ? toolCall.name : '',
        arguments: typeof toolCall.arguments === 'string' ? toolCall.arguments : '',
      };
    });
  }

  return result;
}

/**
 * Legacy: Parse XML data to extract SSE message data
 */
function parseSseXml(xmlData: string): RawSSEEvent {
  const result: RawSSEEvent = {};

  if (!xmlData || xmlData.trim().length === 0) {
    log.warn('[SSEClient] parseSseXml: empty XML data');
    return result;
  }

  if (!xmlData.includes('<response>')) {
    return result;
  }

  result.session_id = getTagValue(xmlData, 'session_id') || undefined;
  result.model = getTagValue(xmlData, 'model') || undefined;
  result.cwd = getTagValue(xmlData, 'cwd') || undefined;

  const rawContent = getTagValue(xmlData, 'content');
  if (rawContent) {
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
        arguments: decodeXmlEntities(getTagValue(tcContent, 'arguments')),
      });
    }
  }

  return result;
}

/**
 * Determine event type from parsed data
 */
function determineEventType(data: RawSSEEvent): SSEMessage['type'] {
  if (data.finish_reason) {
    return 'done';
  }
  if (data.tool_call_id || data.tool_name) {
    return 'tool_result';
  }
  return 'message';
}

/**
 * Generate a short request ID for tracing
 */
function generateRequestId(): string {
  const timestamp = Date.now().toString(36);
  const randomPart = Math.random().toString(36).substring(2, 6);
  const randomPart2 = Math.random().toString(36).substring(2, 6);
  return `REQ-${timestamp}-${randomPart}${randomPart2}`.toUpperCase();
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

  private requestId: string | null = null;
  private eventIndex = 0;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl;
  }

  isConnected(): boolean {
    return this.eventSource !== null && this.sessionId !== null;
  }

  getSessionId(): string | null {
    return this.sessionId;
  }

  getRequestId(): string | null {
    return this.requestId;
  }

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

  trackEvent(_type: string, _content?: string): { requestId: string; eventIndex: number } {
    this.eventIndex++;
    return { requestId: this.requestId || 'none', eventIndex: this.eventIndex };
  }

  endRequest(): void {
    if (this.requestId) {
      log.info(`[SSEClient] Ending request tracking: ${this.requestId} (${this.eventIndex} events)`);
      end(this.requestId);
      this.requestId = null;
      this.eventIndex = 0;
    }
  }

  async disconnectWithNotification(): Promise<void> {
    const sessionId = this.sessionId;
    this.isIntentionalDisconnect = true;

    this.disconnect();

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
    if (this.eventSource && this.sessionId === sessionId) {
      log.info('[SSEClient] Already connected to session:', sessionId);
      return;
    }

    this.isIntentionalDisconnect = false;
    this.disconnect();

    this.sessionId = sessionId;
    this.reconnectAttempts = 0;

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

      this.eventSource.addEventListener('message', (event: MessageEvent) => {
        try {
          const rawData = event.data;

          if (!rawData || rawData.trim().length === 0) {
            return;
          }

          this.eventIndex++;
          const eventInfo = { requestId: this.requestId || 'none', eventIndex: this.eventIndex };
          requestLog(
            eventInfo.requestId,
            'info',
            `Event #${eventInfo.eventIndex} received`,
            `type=${event.type}, len=${rawData.length}`
          );

          requestLog(eventInfo.requestId, 'info', `Raw data: ${rawData}`);

          // Detect format and parse accordingly
          const format = detectFormat(rawData);
          let parsed: RawSSEEvent = {};

          if (format === 'json') {
            try {
              const jsonData = JSON.parse(rawData);
              parsed = parseSseJson(jsonData);
            } catch {
              log.warn('[SSEClient] Failed to parse JSON, falling back to XML');
              parsed = parseSseXml(rawData);
            }
          } else if (format === 'xml') {
            parsed = parseSseXml(rawData);
          }

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
