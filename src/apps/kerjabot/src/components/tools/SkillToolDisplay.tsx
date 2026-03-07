/**
 * SkillToolDisplay - Display for get_skill tool calls
 */

import type { Component } from 'solid-js';
import { Show, createSignal } from 'solid-js';
import { BookOpen, ChevronDown, ChevronUp } from 'lucide-solid';
import type { ToolCall, ToolResult } from '~/types';

interface SkillToolDisplayProps {
  readonly toolCall: ToolCall;
  readonly result?: ToolResult;
}

export const SkillToolDisplay: Component<SkillToolDisplayProps> = (props) => {
  const [expanded, setExpanded] = createSignal(false);

  const skillName = () => (props.toolCall.arguments.skillName as string) || '';

  return (
    <div class="rounded-lg border border-cyan-200 dark:border-cyan-800 bg-cyan-50 dark:bg-cyan-900/20 overflow-hidden">
      {/* Header */}
      <button
        onClick={() => setExpanded(!expanded())}
        class="w-full flex items-center justify-between px-4 py-3 hover:bg-cyan-100 dark:hover:bg-cyan-900/30 transition-colors"
      >
        <div class="flex items-center gap-3">
          <div class="w-8 h-8 rounded-full bg-cyan-500 flex items-center justify-center">
            <BookOpen class="w-4 h-4 text-white" />
          </div>
          <div class="text-left">
            <p class="font-medium text-gray-900 dark:text-white">
              Loaded Skill: <span class="text-cyan-600 dark:text-cyan-400">{skillName()}</span>
            </p>
            <p class="text-xs text-gray-500 dark:text-gray-400">
              Click to view skill content
            </p>
          </div>
        </div>
        {expanded() ? (
          <ChevronUp class="w-5 h-5 text-gray-500" />
        ) : (
          <ChevronDown class="w-5 h-5 text-gray-500" />
        )}
      </button>

      {/* Content */}
      <Show when={expanded() && props.result?.output}>
        <div class="border-t border-cyan-200 dark:border-cyan-800">
          <div class="p-4 bg-white dark:bg-gray-800">
            <pre class="text-sm text-gray-700 dark:text-gray-300 font-mono whitespace-pre-wrap overflow-x-auto max-h-96 overflow-y-auto">
              {props.result!.output}
            </pre>
          </div>
        </div>
      </Show>
    </div>
  );
};
