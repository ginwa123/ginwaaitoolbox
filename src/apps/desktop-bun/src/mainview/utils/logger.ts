/**
 * Logger utility - sends logs to Bun console via RPC
 * 
 * Usage:
 *   import { log } from '../utils/logger';
 *   log.info('Hello');
 *   log.warn('Warning');
 *   log.error('Error');
 */

import { electroview } from '../main';

type LogLevel = 'info' | 'warn' | 'error';

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
  info: (text: string) => sendToBun(text, 'info'),
  warn: (text: string) => sendToBun(text, 'warn'),
  error: (text: string) => sendToBun(text, 'error'),
  
  // Generic log with optional level
  log: (text: string, level?: LogLevel) => sendToBun(text, level || 'info'),
};
