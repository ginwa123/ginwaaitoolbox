/**
 * SetAgentPropertiesToolDisplay - Display for set_agent_properties tool calls
 */

import type { Component } from 'solid-js';
import { Show } from 'solid-js';
import { Sliders, Brain, Thermometer } from 'lucide-solid';
import type { ToolCall, ToolResult } from '~/types';

interface SetAgentPropertiesToolDisplayProps {
  readonly toolCall: ToolCall;
  readonly result?: ToolResult;
}

export const SetAgentPropertiesToolDisplay: Component<SetAgentPropertiesToolDisplayProps> = (props) => {
  const temperature = () => (props.toolCall.arguments.temperature as number | null);
  const isThinking = () => (props.toolCall.arguments.is_thinking as boolean | null);

  const temperatureLabel = () => {
    const temp = temperature();
    if (temp === null || temp === undefined) return null;
    if (temp <= 0.4) return 'LOW';
    if (temp <= 0.7) return 'MEDIUM';
    return 'HIGH';
  };

  return (
    <div class="rounded-lg border border-purple-200 dark:border-purple-800 bg-purple-50 dark:bg-purple-900/20 p-4">
      <div class="flex items-center gap-3">
        <div class="w-10 h-10 rounded-full bg-purple-500 flex items-center justify-center">
          <Sliders class="w-5 h-5 text-white" />
        </div>
        <div class="flex-1">
          <p class="font-medium text-gray-900 dark:text-white">
            Adjusting Agent Properties
          </p>
          <div class="flex gap-4 mt-1">
            <Show when={temperature() !== null && temperature() !== undefined}>
              <div class="flex items-center gap-1 text-sm">
                <Thermometer class="w-4 h-4 text-gray-500" />
                <span class="text-gray-600 dark:text-gray-400">
                  Temperature: <span class="font-medium">{temperatureLabel()}</span> ({temperature()})
                </span>
              </div>
            </Show>
            <Show when={isThinking() !== null && isThinking() !== undefined}>
              <div class="flex items-center gap-1 text-sm">
                <Brain class="w-4 h-4 text-gray-500" />
                <span class="text-gray-600 dark:text-gray-400">
                  Deep Reasoning: <span class="font-medium">{isThinking() ? 'ON' : 'OFF'}</span>
                </span>
              </div>
            </Show>
          </div>
        </div>
        <Show when={props.result?.success}>
          <div class="w-8 h-8 rounded-full bg-green-500 flex items-center justify-center">
            <Sliders class="w-4 h-4 text-white" />
          </div>
        </Show>
      </div>
    </div>
  );
};
