/**
 * Shared RPC Schema - Defines what can be called between Bun and Webview
 *
 * This file is imported by BOTH sides, ensuring type safety!
 */
import { RPCSchema } from 'electrobun/bun';

// ============================================================================
// Shared Types
// ============================================================================

export interface ChatMessage {
  id: string;
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  timestamp: string;
  is_input?: string;
  is_output?: string;
  tool_name?: string;
  finish_reason?: string;
}

export interface SessionMessagesResponse {
  messages: ChatMessage[];
  has_more: boolean;
  next_cursor: string | null;
}

// =============================================================================
// Session Creation
// =============================================================================

export interface CreateSessionRequest {
  name?: string;
  session_id?: string;
  queue_message?: string;
  cwd_session?: string;
}

export interface CreateSessionResponse {
  id: string;
  name: string;
  status: string;
}

// ============================================================================
// Full-Duplex RPC Schema
// ============================================================================
//
// The schema has TWO sides:
// - "bun": What BUN handles (webview calls these)
// - "webview": What WEBVIEW handles (bun calls these)
//
// Each side has:
// - "requests": Functions you CALL and WAIT for a response
// - "messages": One-way messages you FIRE and FORGET

export type DemoRPCType = {
  // -----------------------------------------------------------------
  // BUN SIDE - Functions that run in Bun's main process
  // Webview calls these via: electroview.rpc.request.*
  // Webview sends to these via: electroview.rpc.send.*
  // -----------------------------------------------------------------
  bun: RPCSchema<{
    requests: {
      // Add two numbers
      addNumbers: {
        params: { a: number; b: number };
        response: number;
      };

      // Get system information
      getSystemInfo: {
        params: undefined;
        response: {
          platform: string;
          arch: string;
          version: string;
        };
      };

      // Echo back text (for testing)
      echo: {
        params: { text: string };
        response: string;
      };

      // === PORT PASSING (Pull approach) ===
      // Webview calls this to get the backend port
      getBackendPort: {
        params: undefined;
        response: number;
      };

      // Webview calls this to get the full backend URL
      getBackendUrl: {
        params: undefined;
        response: string;
      };
    };

    messages: {
      // Log a message (no response needed)
      logMessage: { text: string; level: 'info' | 'warn' | 'error' };
    };
  }>;

  // -----------------------------------------------------------------
  // WEBVIEW SIDE - Functions that run in the browser
  // Bun calls these via: webview.rpc.request.*
  // Bun sends to these via: webview.rpc.send.*
  // -----------------------------------------------------------------
  webview: RPCSchema<{
    requests: {
      // Multiply two numbers (in browser)
      multiplyNumbers: {
        params: { a: number; b: number };
        response: number;
      };

      // Get page title
      getPageTitle: {
        params: undefined;
        response: string;
      };
    };

    messages: {
      // Notify browser of something
      notifyBrowser: { title: string; body: string };

      // Update UI counter
      updateCounter: { value: number };

      // === PORT PASSING (Push approach) ===
      // Bun pushes the backend info to webview
      backendPortUpdate: { port: number; url: string };
    };
  }>;
};
