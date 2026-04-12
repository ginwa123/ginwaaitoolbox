/**
 * Logger utility - sends logs to Bun console via RPC with GUID for tracing
 *
 * Usage:
 *   import { log } from '../utils/logger';
 *   log.info('Hello');
 *   log.warn('Warning');
 *   log.error('Error');
 *
 * With custom ID for tracing:
 *   log.info('Processing', { id: 'auth-001' });
 *   log.error('Failed', { id: 'auth-001', extra: 'invalid token' });
 */

import { electroview } from '../main';

type LogLevel = 'info' | 'warn' | 'error';

/**
 * Generate a short GUID (8 chars) for tracing
 */
function generateGUID(): string {
  const timestamp = Date.now().toString(36);
  const randomPart = Math.random().toString(36).substring(2, 6);
  const randomPart2 = Math.random().toString(36).substring(2, 6);
  return `${timestamp}-${randomPart}${randomPart2}`.toUpperCase();
}

/**
 * Format log entry with GUID and optional metadata
 */
function formatLog(
  text: string,
  options?: { id?: string; extra?: string }
): { text: string; guid: string } {
  const guid = options?.id || generateGUID();
  const prefix = options?.extra ? `[${guid}] ${text} | ${options.extra}` : `[${guid}] ${text}`;
  return { text: prefix, guid };
}

/**
 * Send a log message to Bun console
 */
function sendToBun(text: string, level: LogLevel = 'info'): void {
  try {
    if (electroview?.rpc?.send?.logMessage) {
      electroview.rpc.send.logMessage({ text, level });
    }
  } catch {
    // Silently fail if RPC is not available
  }
}

export const log = {
  info: (text: string, options?: { id?: string; extra?: string }) => {
    const { text: formatted, guid } = formatLog(text, options);
    sendToBun(formatted, 'info');
    return guid;
  },
  warn: (text: string, options?: { id?: string; extra?: string }) => {
    const { text: formatted, guid } = formatLog(text, options);
    sendToBun(formatted, 'warn');
    return guid;
  },
  error: (text: string, options?: { id?: string; extra?: string }) => {
    const { text: formatted, guid } = formatLog(text, options);
    sendToBun(formatted, 'error');
    return guid;
  },

  // Generic log with optional level
  log: (text: string, level?: LogLevel, options?: { id?: string; extra?: string }) => {
    const { text: formatted, guid } = formatLog(text, options);
    sendToBun(formatted, level || 'info');
    return guid;
  },

  // Create a tracking context - returns functions that auto-include the ID
  createTracker: (id: string) => ({
    info: (text: string, extra?: string) => log.info(text, { id, extra }),
    warn: (text: string, extra?: string) => log.warn(text, { id, extra }),
    error: (text: string, extra?: string) => log.error(text, { id, extra }),
    log: (text: string, level?: LogLevel, extra?: string) => log.log(text, level, { id, extra }),
  }),

  // Get a new unique GUID
  newGuid: generateGUID,
};
