/**
 * ToolMessage - Tool result display component
 */

import type { Component } from 'solid-js';
import { Show, createSignal } from 'solid-js';
import { Terminal, ChevronDown, ChevronUp, CheckCircle, XCircle } from 'lucide-solid';
import type { ToolMessage as ToolMessageType } from '~/types';
import { MessageBubble } from './MessageBubble';
import { formatDuration } from '~/utils';

interface ToolMessageProps {
  readonly message: ToolMessageType;
}

export const ToolMessage: Component<ToolMessageProps> = (props) => {
  const [expanded, setExpanded] = createSignal(false);

  const result = () => props.message.result;
  const hasOutput = () => !!result().output && result().output!.length > 0;
  const hasError = () => !!result().error;

  return (
    <div class="flex items-start gap-3">
      <div class="w-8 h-8 rounded-full bg-amber-500 flex items-center justify-center flex-shrink-0">
        <Terminal class="w-4 h-4 text-white" />
      </div>
      <div class="flex-1 min-w-0">
        <MessageBubble role={props.message.role}>
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <span class="font-medium text-gray-900 dark:text-white">
                {props.message.toolName}
              </span>
              {result().success ? (
                <CheckCircle class="w-4 h-4 text-green-500" />
              ) : (
                <XCircle class="w-4 h-4 text-red-500" />
              )}
            </div>
            <div class="flex items-center gap-2">
              <span class="text-xs text-gray-500 dark:text-gray-400">
                {formatDuration(result().duration)}
              </span>
              <Show when={hasOutput() || hasError()}>
                <button
                  onClick={() => setExpanded(!expanded())}
                  class="p-1 hover:bg-gray-200 dark:hover:bg-gray-700 rounded transition-colors"
                >
                  {expanded() ? (
                    <ChevronUp class="w-4 h-4 text-gray-500" />
                  ) : (
                    <ChevronDown class="w-4 h-4 text-gray-500" />
                  )}
                </button>
              </Show>
            </div>
          </div>

          <Show when={expanded()}>
            <div class="mt-3 space-y-2">
              <Show when={hasOutput()}>
                <div class="bg-gray-900 rounded-lg overflow-hidden">
                  <div class="px-3 py-1 bg-gray-800 text-xs text-gray-400 uppercase">
                    Output
                  </div>
                  <pre class="p-3 text-sm text-gray-100 font-mono overflow-x-auto max-h-64 overflow-y-auto">
                    {result().output}
                  </pre>
                </div>
              </Show>

              <Show when={hasError()}>
                <div class="bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg overflow-hidden">
                  <div class="px-3 py-1 bg-red-100 dark:bg-red-900/40 text-xs text-red-600 dark:text-red-400 uppercase">
                    Error
                  </div>
                  <pre class="p-3 text-sm text-red-700 dark:text-red-300 font-mono overflow-x-auto">
                    {result().error}
                  </pre>
                </div>
              </Show>

              <Show when={result().exitCode !== undefined}>
                <div class="text-xs text-gray-500 dark:text-gray-400">
                  Exit code: {result().exitCode}
                </div>
              </Show>
            </div>
          </Show>
        </MessageBubble>
      </div>
    </div>
  );
};
