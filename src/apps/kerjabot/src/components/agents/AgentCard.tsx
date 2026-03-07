/**
 * AgentCard - Displays a single agent with icon and description
 */

import type { Component } from 'solid-js';
import { For } from 'solid-js';
import { Bot, Search, Map, Code, CheckCircle, BookOpen, Minimize2 } from 'lucide-solid';
import type { AgentConfig } from '~/types';
import { AgentType } from '~/types';

interface AgentCardProps {
  readonly agent: AgentConfig;
  readonly isSelected: boolean;
  readonly onSelect: () => void;
}

export const AgentCard: Component<AgentCardProps> = (props) => {
  const getIcon = () => {
    switch (props.agent.type) {
      case AgentType.General:
        return <Bot class="w-6 h-6" />;
      case AgentType.Exploration:
        return <Search class="w-6 h-6" />;
      case AgentType.Planning:
        return <Map class="w-6 h-6" />;
      case AgentType.Executing:
        return <Code class="w-6 h-6" />;
      case AgentType.Review:
        return <CheckCircle class="w-6 h-6" />;
      case AgentType.Knowledge:
        return <BookOpen class="w-6 h-6" />;
      case AgentType.Compaction:
        return <Minimize2 class="w-6 h-6" />;
      default:
        return <Bot class="w-6 h-6" />;
    }
  };

  const getColorClass = () => {
    switch (props.agent.type) {
      case AgentType.General:
        return 'from-blue-500 to-blue-600 border-blue-200 dark:border-blue-800';
      case AgentType.Exploration:
        return 'from-purple-500 to-purple-600 border-purple-200 dark:border-purple-800';
      case AgentType.Planning:
        return 'from-amber-500 to-amber-600 border-amber-200 dark:border-amber-800';
      case AgentType.Executing:
        return 'from-emerald-500 to-emerald-600 border-emerald-200 dark:border-emerald-800';
      case AgentType.Review:
        return 'from-rose-500 to-rose-600 border-rose-200 dark:border-rose-800';
      case AgentType.Knowledge:
        return 'from-cyan-500 to-cyan-600 border-cyan-200 dark:border-cyan-800';
      case AgentType.Compaction:
        return 'from-indigo-500 to-indigo-600 border-indigo-200 dark:border-indigo-800';
      default:
        return 'from-gray-500 to-gray-600 border-gray-200 dark:border-gray-700';
    }
  };

  return (
    <button
      onClick={props.onSelect}
      class={`relative p-5 rounded-xl border-2 text-left transition-all duration-200 ${
        props.isSelected
          ? `border-blue-500 bg-blue-50 dark:bg-blue-900/20 shadow-lg shadow-blue-500/20`
          : `border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 hover:border-gray-300 dark:hover:border-gray-600 hover:shadow-md`
      }`}
    >
      {/* Selection indicator */}
      {props.isSelected && (
        <div class="absolute top-3 right-3 w-5 h-5 rounded-full bg-blue-500 flex items-center justify-center">
          <CheckCircle class="w-3 h-3 text-white" />
        </div>
      )}

      {/* Icon */}
      <div
        class={`w-12 h-12 rounded-xl bg-gradient-to-br ${getColorClass()} flex items-center justify-center text-white mb-4`}
      >
        {getIcon()}
      </div>

      {/* Content */}
      <h3 class="font-semibold text-gray-900 dark:text-white mb-1">
        {props.agent.name}
      </h3>
      <p class="text-sm text-gray-500 dark:text-gray-400 line-clamp-2">
        {props.agent.description}
      </p>

      {/* Skills tags */}
      <div class="flex flex-wrap gap-1 mt-3">
        <For each={props.agent.skills.slice(0, 3)}>
          {(skill) => (
            <span class="text-xs px-2 py-0.5 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300">
              {skill}
            </span>
          )}
        </For>
        {props.agent.skills.length > 3 && (
          <span class="text-xs px-2 py-0.5 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-500 dark:text-gray-400">
            +{props.agent.skills.length - 3}
          </span>
        )}
      </div>
    </button>
  );
};
