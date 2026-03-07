/**
 * AssistantMessage - Assistant message with content and reasoning sections
 */

import type { Component } from 'solid-js';
import { Show, For } from 'solid-js';
import { Bot, ChevronDown, ChevronUp } from 'lucide-solid';
import { createSignal } from 'solid-js';
import type { AssistantMessage as AssistantMessageType } from '~/types';
import { MessageBubble } from './MessageBubble';
import { formatDateTime } from '~/utils';
import { extractCodeBlocks } from '~/utils';

interface AssistantMessageProps {
  readonly message: AssistantMessageType;
}

export const AssistantMessage: Component<AssistantMessageProps> = (props) => {
  const [showReasoning, setShowReasoning] = createSignal(false);

  const codeBlocks = () => extractCodeBlocks(props.message.content);

  const renderContent = () => {
    let content = props.message.content;
    
    // Replace code blocks with placeholders for rendering
    const blocks = codeBlocks();
    blocks.forEach((block, idx) => {
      content = content.replace(
        '```' + (block.language || '') + '\n' + block.code + '```',
        `[CODE_BLOCK_${idx}]`
      );
    });

    const parts = content.split(/\[CODE_BLOCK_(\d+)\]/);

    return (
      <>
        <For each={parts}>
          {(part) => {
            const blockIndex = parseInt(part);
            if (!isNaN(blockIndex) && blocks[blockIndex]) {
              const block = blocks[blockIndex];
              return (
                <div class="my-3 rounded-lg overflow-hidden bg-gray-900">
                  {block.language && (
                    <div class="px-3 py-1 bg-gray-800 text-xs text-gray-400 uppercase">
                      {block.language}
                    </div>
                  )}
                  <pre class="p-3 overflow-x-auto">
                    <code class="text-sm text-gray-100 font-mono">{block.code}</code>
                  </pre>
                </div>
              );
            }
            return part ? <p class="whitespace-pre-wrap">{part}</p> : null;
          }}
        </For>
      </>
    );
  };

  return (
    <div class="flex items-start gap-3">
      <div class="w-8 h-8 rounded-full bg-gradient-to-br from-purple-500 to-blue-600 flex items-center justify-center flex-shrink-0">
        <Bot class="w-4 h-4 text-white" />
      </div>
      <div class="flex-1 min-w-0">
        <MessageBubble role={props.message.role}>
          <div class="text-gray-900 dark:text-gray-100">
            {renderContent()}
          </div>

          {/* Reasoning section */}
          <Show when={props.message.reasoning}>
            <div class="mt-3 pt-3 border-t border-gray-200 dark:border-gray-600">
              <button
                onClick={() => setShowReasoning(!showReasoning())}
                class="flex items-center gap-1 text-xs text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-300"
              >
                {showReasoning() ? (
                  <ChevronUp class="w-3 h-3" />
                ) : (
                  <ChevronDown class="w-3 h-3" />
                )}
                Reasoning
              </button>
              <Show when={showReasoning()}>
                <div class="mt-2 p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg text-sm text-gray-600 dark:text-gray-400 italic">
                  {props.message.reasoning}
                </div>
              </Show>
            </div>
          </Show>

          {/* Token count */}
          <Show when={props.message.tokenCount}>
            <div class="mt-2 flex items-center gap-2 text-xs text-gray-400 dark:text-gray-500">
              <span>{props.message.tokenCount?.total} tokens</span>
              <Show when={props.message.model}>
                <span>· {props.message.model}</span>
              </Show>
            </div>
          </Show>
        </MessageBubble>
        <div class="mt-1">
          <span class="text-xs text-gray-400 dark:text-gray-500">
            {formatDateTime(props.message.timestamp)}
          </span>
        </div>
      </div>
    </div>
  );
};
