/**
 * NewSessionButton - Button to create a new session
 */

import type { Component } from 'solid-js';
import { Plus } from 'lucide-solid';

interface NewSessionButtonProps {
  readonly onClick: () => void;
  readonly variant?: 'primary' | 'secondary' | 'ghost';
  readonly size?: 'sm' | 'md' | 'lg';
  readonly fullWidth?: boolean;
}

export const NewSessionButton: Component<NewSessionButtonProps> = (props) => {
  const getVariantClasses = () => {
    switch (props.variant) {
      case 'primary':
        return 'bg-blue-600 hover:bg-blue-700 text-white';
      case 'secondary':
        return 'bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700 text-gray-700 dark:text-gray-200';
      case 'ghost':
      default:
        return 'hover:bg-gray-100 dark:hover:bg-gray-700 text-gray-600 dark:text-gray-300';
    }
  };

  const getSizeClasses = () => {
    switch (props.size) {
      case 'sm':
        return 'px-3 py-1.5 text-sm';
      case 'lg':
        return 'px-6 py-3 text-lg';
      case 'md':
      default:
        return 'px-4 py-2 text-base';
    }
  };

  return (
    <button
      onClick={props.onClick}
      class={`inline-flex items-center justify-center gap-2 rounded-lg font-medium transition-colors ${
        getVariantClasses()
      } ${getSizeClasses()} ${props.fullWidth ? 'w-full' : ''}`}
    >
      <Plus class="w-5 h-5" />
      <span>New Session</span>
    </button>
  );
};
