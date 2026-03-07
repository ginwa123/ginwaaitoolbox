/**
 * AgentBadge - Small badge showing current agent
 */

import type { Component } from 'solid-js';
import { Bot, Search, Map, Code, CheckCircle, BookOpen, Minimize2 } from 'lucide-solid';
import type { AgentConfig } from '~/types';
import { AgentType } from '~/types';

interface AgentBadgeProps {
  readonly agent: AgentConfig;
  readonly size?: 'sm' | 'md' | 'lg';
  readonly showName?: boolean;
}

export const AgentBadge: Component<AgentBadgeProps> = (props) => {
  const sizeClasses = () => {
    switch (props.size) {
      case 'sm':
        return { container: 'w-6 h-6', icon: 'w-3 h-3', text: 'text-xs' };
      case 'lg':
        return { container: 'w-10 h-10', icon: 'w-5 h-5', text: 'text-base' };
      case 'md':
      default:
        return { container: 'w-8 h-8', icon: 'w-4 h-4', text: 'text-sm' };
    }
  };

  const getIcon = () => {
    const iconClass = sizeClasses().icon;
    switch (props.agent.type) {
      case AgentType.General:
        return <Bot class={iconClass} />;
      case AgentType.Exploration:
        return <Search class={iconClass} />;
      case AgentType.Planning:
        return <Map class={iconClass} />;
      case AgentType.Executing:
        return <Code class={iconClass} />;
      case AgentType.Review:
        return <CheckCircle class={iconClass} />;
      case AgentType.Knowledge:
        return <BookOpen class={iconClass} />;
      case AgentType.Compaction:
        return <Minimize2 class={iconClass} />;
      default:
        return <Bot class={iconClass} />;
    }
  };

  const getColorClass = () => {
    switch (props.agent.type) {
      case AgentType.General:
        return 'bg-blue-500';
      case AgentType.Exploration:
        return 'bg-purple-500';
      case AgentType.Planning:
        return 'bg-amber-500';
      case AgentType.Executing:
        return 'bg-emerald-500';
      case AgentType.Review:
        return 'bg-rose-500';
      case AgentType.Knowledge:
        return 'bg-cyan-500';
      case AgentType.Compaction:
        return 'bg-indigo-500';
      default:
        return 'bg-gray-500';
    }
  };

  return (
    <div class="flex items-center gap-2">
      <div
        class={`${sizeClasses().container} rounded-full ${getColorClass()} flex items-center justify-center text-white`}
      >
        {getIcon()}
      </div>
      {props.showName && (
        <span class={`${sizeClasses().text} font-medium text-gray-900 dark:text-white`}>
          {props.agent.name}
        </span>
      )}
    </div>
  );
};
