/**
 * MessageInput - Textarea with send button for message entry
 */

import type { Component } from 'solid-js';
import { createSignal, Show } from 'solid-js';
import { Send, Loader2 } from 'lucide-solid';

interface MessageInputProps {
  readonly onSend: (message: string) => void;
  readonly isLoading?: boolean;
  readonly placeholder?: string;
  readonly disabled?: boolean;
}

export const MessageInput: Component<MessageInputProps> = (props) => {
  const [message, setMessage] = createSignal('');
  let textareaRef: HTMLTextAreaElement | undefined;

  const handleSend = () => {
    const content = message().trim();
    if (!content || props.isLoading || props.disabled) return;
    
    props.onSend(content);
    setMessage('');
    
    // Reset textarea height
    if (textareaRef) {
      textareaRef.style.height = 'auto';
    }
  };

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  const handleInput = () => {
    if (textareaRef) {
      textareaRef.style.height = 'auto';
      textareaRef.style.height = `${Math.min(textareaRef.scrollHeight, 200)}px`;
    }
  };

  const isEmpty = () => message().trim().length === 0;

  return (
    <div class="border-t border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-4">
      <div class="flex items-end gap-2 max-w-4xl mx-auto">
        <div class="flex-1 relative">
          <textarea
            ref={textareaRef}
            value={message()}
            onInput={(e) => {
              setMessage(e.currentTarget.value);
              handleInput();
            }}
            onKeyDown={handleKeyDown}
            placeholder={props.placeholder || 'Type a message...'}
            disabled={props.disabled}
            rows={1}
            class="w-full px-4 py-3 pr-12 bg-gray-100 dark:bg-gray-700 border-0 rounded-xl resize-none focus:ring-2 focus:ring-blue-500 focus:bg-white dark:focus:bg-gray-600 transition-all text-gray-900 dark:text-white placeholder-gray-500 dark:placeholder-gray-400 disabled:opacity-50 disabled:cursor-not-allowed"
            style={{ 'min-height': '48px', 'max-height': '200px' }}
          />
          <div class="absolute right-3 bottom-3 text-xs text-gray-400 dark:text-gray-500 pointer-events-none">
            <Show when={!isEmpty()}>
              <span>Enter to send</span>
            </Show>
          </div>
        </div>
        
        <button
          onClick={handleSend}
          disabled={isEmpty() || props.isLoading || props.disabled}
          class="flex-shrink-0 w-12 h-12 flex items-center justify-center bg-blue-600 hover:bg-blue-700 disabled:bg-gray-300 dark:disabled:bg-gray-600 disabled:cursor-not-allowed text-white rounded-xl transition-colors"
        >
          <Show
            when={props.isLoading}
            fallback={<Send class="w-5 h-5" />}
          >
            <Loader2 class="w-5 h-5 animate-spin" />
          </Show>
        </button>
      </div>
    </div>
  );
};
