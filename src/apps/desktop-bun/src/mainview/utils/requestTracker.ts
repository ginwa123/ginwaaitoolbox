/**
 * Request Tracker - correlates logs for a single request across the stream
 *
 * 1 request = 1 GUID, all related logs (SSE events, tool results, etc.) share this ID
 *
 * Usage:
 *   import { requestTracker } from './requestTracker';
 *
 *   // When starting a request
 *   const id = requestTracker.start('auth-001', sessionId);
 *
 *   // In SSE handler
 *   requestTracker.log(sseMsg.id, 'info', 'Received message');
 *
 *   // When request ends
 *   requestTracker.end(sseMsg.id);
 */

import { log as baseLog } from './logger';

// ============================================================================
// Types
// ============================================================================

export interface RequestContext {
  id: string;
  sessionId: string;
  startTime: number;
  eventCount: number;
}

// ============================================================================
// Request Context Store
// ============================================================================

/**
 * Active request contexts keyed by request GUID
 */
const activeRequests = new Map<string, RequestContext>();

/**
 * Generate a request GUID from timestamp + random
 */
export function generateRequestId(): string {
  const timestamp = Date.now().toString(36);
  const randomPart = Math.random().toString(36).substring(2, 6);
  const randomPart2 = Math.random().toString(36).substring(2, 6);
  return `REQ-${timestamp}-${randomPart}${randomPart2}`.toUpperCase();
}

/**
 * Start tracking a new request
 */
export function start(requestId: string, sessionId: string): RequestContext {
  const context: RequestContext = {
    id: requestId,
    sessionId,
    startTime: Date.now(),
    eventCount: 0,
  };
  activeRequests.set(requestId, context);
  baseLog.info(`[Request:${requestId}] Started request`, {
    id: requestId,
    extra: `session=${sessionId}`,
  });
  return context;
}

/**
 * Get current request context
 */
export function getRequestContext(requestId: string): RequestContext | undefined {
  return activeRequests.get(requestId);
}

/**
 * Log with request context
 */
export function log(
  requestId: string,
  level: 'info' | 'warn' | 'error',
  text: string,
  extra?: string
): void {
  const context = activeRequests.get(requestId);
  const eventNum = context ? ++context.eventCount : 0;
  const formatted = `[REQ:${requestId}][E${eventNum}] ${text}`;

  if (level === 'error') {
    baseLog.error(formatted, {
      id: requestId,
      extra: extra ? `${extra} (event #${eventNum})` : `event #${eventNum}`,
    });
  } else if (level === 'warn') {
    baseLog.warn(formatted, { id: requestId, extra });
  } else {
    baseLog.info(formatted, { id: requestId, extra });
  }
}

/**
 * End tracking a request
 */
export function end(requestId: string): void {
  const context = activeRequests.get(requestId);
  if (context) {
    const duration = Date.now() - context.startTime;
    baseLog.info(`[Request:${requestId}] Ended request`, {
      id: requestId,
      extra: `${context.eventCount} events, ${duration}ms`,
    });
    activeRequests.delete(requestId);
  }
}

// ============================================================================
// Convenience Methods
// ============================================================================

/**
 * Create a tracker for a specific request
 */
export function createRequestTracker(requestId: string) {
  return {
    info: (text: string, extra?: string) => log(requestId, 'info', text, extra),
    warn: (text: string, extra?: string) => log(requestId, 'warn', text, extra),
    error: (text: string, extra?: string) => log(requestId, 'error', text, extra),
    end: () => end(requestId),
    getContext: () => getRequestContext(requestId),
  };
}

/**
 * SSE Client wrapper with request tracking
 */
export interface TrackedSSEEvent {
  type: string;
  requestId: string;
  eventIndex: number;
  content?: string;
  tool_name?: string;
}

export class RequestTrackingSSEClient {
  private requestId: string | null = null;
  private eventIndex = 0;

  /**
   * Start tracking a new request session
   */
  startRequestSession(sessionId: string): string {
    this.requestId = generateRequestId();
    this.eventIndex = 0;
    startRequest(this.requestId, sessionId);
    return this.requestId;
  }

  /**
   * Track an SSE event
   */
  trackEvent(event: { type: string; content?: string; tool_name?: string }): TrackedSSEEvent {
    this.eventIndex++;
    return {
      type: event.type,
      requestId: this.requestId || 'unknown',
      eventIndex: this.eventIndex,
      content: event.content,
      tool_name: event.tool_name,
    };
  }

  /**
   * Log with current request context
   */
  log(level: 'info' | 'warn' | 'error', text: string, extra?: string): void {
    if (this.requestId) {
      logWithRequest(this.requestId, level, text, extra);
    } else {
      if (level === 'error') baseLog.error(text);
      else if (level === 'warn') baseLog.warn(text);
      else baseLog.info(text);
    }
  }

  /**
   * End current request session
   */
  endRequestSession(): void {
    if (this.requestId) {
      endRequest(this.requestId);
      this.requestId = null;
      this.eventIndex = 0;
    }
  }

  /**
   * Get current request ID
   */
  getRequestId(): string | null {
    return this.requestId;
  }
}
