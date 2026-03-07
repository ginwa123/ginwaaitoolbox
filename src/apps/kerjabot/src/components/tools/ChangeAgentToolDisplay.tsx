/**
 * ChangeAgentToolDisplay - Display for change_agent tool calls
 */

import type { Component } from 'solid-js';
import { Show } from 'solid-js';
import { ArrowRightLeft, Bot } from 'lucide-solid';
import type { ToolCall, ToolResult } from '~/types';

interface ChangeAgentToolDisplayProps {
  readonly toolCall: ToolCall;
  readonly result?: ToolResult;
}

export const ChangeAgentToolDisplay: Component<ChangeAgentToolDisplayProps> = (props) => {
  const agent = () => (props.toolCall.arguments.agent as string) || '';
  const message = () => (props.toolCall.arguments.message as string) || '';

  return (
    <div class="rounded-lg border border-purple-200 dark:border-purple-800 bg-purple-50 dark:bg-purple-900/20 p-4">
      <div class="flex items-center gap-3">
        <div class="w-10 h-10 rounded-full bg-purple-500 flex items-center justify-center">
          <ArrowRightLeft class="w-5 h-5 text-white" />
        </div>
        <div class="flex-1">
          <p class="font-medium text-gray-900 dark:text-white">
            Switching to <span class="text-purple-600 dark:text-purple-400">{agent()}</span>
          </p>
          <Show when={message()}>
            <p class="text-sm text-gray-600 dark:text-gray-400 mt-1">
              "{message()}"
            </p>
          </Show>
        </div>
        <Show when={props.result?.success}>
          <div class="w-8 h-8 rounded-full bg-green-500 flex items-center justify-center">
            <Bot class="w-4 h-4 text-white" />
          </div>
        </Show>
      </div>
    </div>
  );
};
