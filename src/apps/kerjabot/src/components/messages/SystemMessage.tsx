/**
 * SystemMessage - System message display for notifications
 */

import type { Component } from 'solid-js';
import { Info, AlertTriangle, XCircle, CheckCircle } from 'lucide-solid';
import type { SystemMessage as SystemMessageType } from '~/types';
import { SystemMessageLevel } from '~/types';

interface SystemMessageProps {
  readonly message: SystemMessageType;
}

export const SystemMessage: Component<SystemMessageProps> = (props) => {
  const getIcon = () => {
    switch (props.message.level) {
      case SystemMessageLevel.Info:
        return <Info class="w-4 h-4 text-blue-500" />;
      case SystemMessageLevel.Warning:
        return <AlertTriangle class="w-4 h-4 text-amber-500" />;
      case SystemMessageLevel.Error:
        return <XCircle class="w-4 h-4 text-red-500" />;
      case SystemMessageLevel.Success:
        return <CheckCircle class="w-4 h-4 text-green-500" />;
      default:
        return <Info class="w-4 h-4 text-blue-500" />;
    }
  };

  const getBorderColor = () => {
    switch (props.message.level) {
      case SystemMessageLevel.Info:
        return 'border-blue-200 dark:border-blue-800';
      case SystemMessageLevel.Warning:
        return 'border-amber-200 dark:border-amber-800';
      case SystemMessageLevel.Error:
        return 'border-red-200 dark:border-red-800';
      case SystemMessageLevel.Success:
        return 'border-green-200 dark:border-green-800';
      default:
        return 'border-gray-200 dark:border-gray-700';
    }
  };

  return (
    <div class="flex justify-center my-4">
      <div
        class={`flex items-center gap-2 px-4 py-2 rounded-full border ${getBorderColor()} bg-white dark:bg-gray-800 shadow-sm`}
      >
        {getIcon()}
        <span class="text-sm text-gray-700 dark:text-gray-300">
          {props.message.content}
        </span>
      </div>
    </div>
  );
};
