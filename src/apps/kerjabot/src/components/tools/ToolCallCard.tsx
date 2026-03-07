/**
 * ToolCallCard - Displays tool call with name and status
 */

import type { Component } from 'solid-js';
import { Show, createSignal } from 'solid-js';
import { Terminal, ChevronDown, ChevronUp, Loader2, CheckCircle, XCircle } from 'lucide-solid';
import type { ToolCallState } from '~/types';
import { ToolCallStatus } from '~/types';
import { formatDuration } from '~/utils';

interface ToolCallCardProps {
  readonly toolCall: ToolCallState;
}

export const ToolCallCard: Component<ToolCallCardProps> = (props) => {
  const [expanded, setExpanded] = createSignal(false);

  const getStatusIcon = () => {
    switch (props.toolCall.status) {
      case ToolCallStatus.Pending:
        return <div class="w-4 h-4 rounded-full border-2 border-gray-300" />;
      case ToolCallStatus.Executing:
        return <Loader2 class="w-4 h-4 text-blue-500 animate-spin" />;
      case ToolCallStatus.Completed:
        return <CheckCircle class="w-4 h-4 text-green-500" />;
      case ToolCallStatus.Failed:
        return <XCircle class="w-4 h-4 text-red-500" />;
      case ToolCallStatus.Cancelled:
        return <XCircle class="w-4 h-4 text-gray-400" />;
      default:
        return null;
    }
  };

  const getStatusColor = () => {
    switch (props.toolCall.status) {
      case ToolCallStatus.Pending:
        return 'bg-gray-50 dark:bg-gray-800 border-gray-200 dark:border-gray-700';
      case ToolCallStatus.Executing:
        return 'bg-blue-50 dark:bg-blue-900/20 border-blue-200 dark:border-blue-800';
      case ToolCallStatus.Completed:
        return 'bg-green-50 dark:bg-green-900/20 border-green-200 dark:border-green-800';
      case ToolCallStatus.Failed:
        return 'bg-red-50 dark:bg-red-900/20 border-red-200 dark:border-red-800';
      case ToolCallStatus.Cancelled:
        return 'bg-gray-50 dark:bg-gray-800 border-gray-200 dark:border-gray-700';
      default:
        return 'bg-gray-50 dark:bg-gray-800';
    }
  };

  const formatArgs = () => {
    try {
      return JSON.stringify(props.toolCall.call.arguments, null, 2);
    } catch {
      return String(props.toolCall.call.arguments);
    }
  };

  return (
    <div
      class={`rounded-lg border p-3 transition-all ${getStatusColor()}`}
    >
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <Terminal class="w-4 h-4 text-gray-500" />
          <span class="font-medium text-sm text-gray-900 dark:text-white">
            {props.toolCall.call.name}
          </span>
          <span class="text-xs text-gray-500 dark:text-gray-400">
            ({props.toolCall.status})
          </span>
        </div>
        <div class="flex items-center gap-2">
          {getStatusIcon()}
          <Show when={props.toolCall.result}>
            <span class="text-xs text-gray-500 dark:text-gray-400">
              {formatDuration(props.toolCall.result!.duration)}
            </span>
          </Show>
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
        </div>
      </div>

      <Show when={expanded()}>
        <div class="mt-3 space-y-2">
          <div>
            <p class="text-xs text-gray-500 dark:text-gray-400 mb-1">Arguments:</p>
            <pre class="text-xs bg-gray-100 dark:bg-gray-900 p-2 rounded overflow-x-auto text-gray-700 dark:text-gray-300">
              {formatArgs()}
            </pre>
          </div>

          <Show when={props.toolCall.result}>
            <div>
              <p class="text-xs text-gray-500 dark:text-gray-400 mb-1">Result:</p>
              <pre class="text-xs bg-gray-100 dark:bg-gray-900 p-2 rounded overflow-x-auto text-gray-700 dark:text-gray-300 max-h-32 overflow-y-auto">
                {props.toolCall.result?.output || props.toolCall.result?.error || 'No output'}
              </pre>
            </div>
          </Show>
        </div>
      </Show>
    </div>
  );
};
