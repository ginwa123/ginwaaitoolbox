/**
 * StreamingIndicator - Animated typing indicator for streaming responses
 */

import type { Component } from 'solid-js';

export const StreamingIndicator: Component = () => {
  return (
    <div class="flex items-center gap-1 px-3 py-2">
      <div
        class="w-2 h-2 rounded-full bg-gray-400 dark:bg-gray-500 animate-bounce"
        style={{ 'animation-delay': '0ms' }}
      />
      <div
        class="w-2 h-2 rounded-full bg-gray-400 dark:bg-gray-500 animate-bounce"
        style={{ 'animation-delay': '150ms' }}
      />
      <div
        class="w-2 h-2 rounded-full bg-gray-400 dark:bg-gray-500 animate-bounce"
        style={{ 'animation-delay': '300ms' }}
      />
    </div>
  );
};
