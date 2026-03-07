/**
 * BashToolDisplay - Specialized display for bash tool calls
 */

import type { Component } from 'solid-js';
import { Show, createSignal } from 'solid-js';
import { Terminal, ChevronDown, ChevronUp, Copy, Check } from 'lucide-solid';
import type { ToolCall, ToolResult } from '~/types';

interface BashToolDisplayProps {
  readonly toolCall: ToolCall;
  readonly result?: ToolResult;
}

export const BashToolDisplay: Component<BashToolDisplayProps> = (props) => {
  const [expanded, setExpanded] = createSignal(true);
  const [copied, setCopied] = createSignal(false);

  const command = () => (props.toolCall.arguments.command as string) || '';
  const cwd = () => (props.toolCall.arguments.cwd as string) || '';

  const copyCommand = async () => {
    try {
      await navigator.clipboard.writeText(command());
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Ignore copy errors
    }
  };

  return (
    <div class="rounded-lg border border-gray-200 dark:border-gray-700 overflow-hidden">
      {/* Header */}
      <div class="flex items-center justify-between px-3 py-2 bg-gray-100 dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700">
        <div class="flex items-center gap-2">
          <Terminal class="w-4 h-4 text-gray-500" />
          <span class="text-sm font-medium text-gray-700 dark:text-gray-300">bash</span>
          <Show when={cwd()}>
            <span class="text-xs text-gray-500 dark:text-gray-400">in {cwd()}</span>
          </Show>
        </div>
        <div class="flex items-center gap-1">
          <button
            onClick={copyCommand}
            class="p-1 hover:bg-gray-200 dark:hover:bg-gray-700 rounded transition-colors"
            title="Copy command"
          >
            {copied() ? (
              <Check class="w-4 h-4 text-green-500" />
            ) : (
              <Copy class="w-4 h-4 text-gray-500" />
            )}
          </button>
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

      {/* Command */}
      <Show when={expanded()}>
        <div class="bg-gray-900 p-3">
          <code class="text-sm text-gray-100 font-mono whitespace-pre-wrap">
            $ {command()}
          </code>
        </div>

        {/* Output */}
        <Show when={props.result}>
          <div class="border-t border-gray-200 dark:border-gray-700">
            <Show when={props.result!.output}>
              <div class="p-3 bg-gray-50 dark:bg-gray-800/50">
                <p class="text-xs text-gray-500 dark:text-gray-400 mb-1">Output:</p>
                <pre class="text-sm text-gray-700 dark:text-gray-300 font-mono whitespace-pre-wrap overflow-x-auto max-h-64 overflow-y-auto">
                  {props.result!.output}
                </pre>
              </div>
            </Show>

            <Show when={props.result!.error}>
              <div class="p-3 bg-red-50 dark:bg-red-900/20 border-t border-red-200 dark:border-red-800">
                <p class="text-xs text-red-600 dark:text-red-400 mb-1">Error:</p>
                <pre class="text-sm text-red-700 dark:text-red-300 font-mono whitespace-pre-wrap">
                  {props.result!.error}
                </pre>
              </div>
            </Show>

            <Show when={props.result!.exitCode !== undefined}>
              <div class="px-3 py-1 bg-gray-100 dark:bg-gray-800 text-xs text-gray-500 dark:text-gray-400">
                Exit code: {props.result!.exitCode}
              </div>
            </Show>
          </div>
        </Show>
      </Show>
    </div>
  );
};
