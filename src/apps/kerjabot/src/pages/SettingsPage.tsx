/**
 * SettingsPage - Application settings and configuration
 */

import type { Component } from 'solid-js';
import { createSignal } from 'solid-js';
import { 
  Moon, 
  Sun, 
  Server, 
  Key, 
  Bell, 
  Save,
  RotateCcw
} from 'lucide-solid';

export const SettingsPage: Component = () => {
  const [darkMode, setDarkMode] = createSignal(false);
  const [apiEndpoint, setApiEndpoint] = createSignal('http://localhost:3000');
  const [apiKey, setApiKey] = createSignal('');
  const [notifications, setNotifications] = createSignal(true);
  const [autoSave, setAutoSave] = createSignal(true);

  const handleSave = () => {
    // Save settings to localStorage or API
    localStorage.setItem('kerjabot:settings', JSON.stringify({
      darkMode: darkMode(),
      apiEndpoint: apiEndpoint(),
      notifications: notifications(),
      autoSave: autoSave(),
    }));
    alert('Settings saved!');
  };

  const handleReset = () => {
    setDarkMode(false);
    setApiEndpoint('http://localhost:3000');
    setApiKey('');
    setNotifications(true);
    setAutoSave(true);
  };

  return (
    <div class="max-w-2xl mx-auto">
      <h1 class="text-2xl font-bold text-gray-900 dark:text-white mb-6">
        Settings
      </h1>

      <div class="space-y-6">
        {/* Appearance */}
        <section class="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-6">
          <h2 class="text-lg font-semibold text-gray-900 dark:text-white mb-4 flex items-center gap-2">
            {darkMode() ? <Moon class="w-5 h-5" /> : <Sun class="w-5 h-5" />}
            Appearance
          </h2>
          
          <div class="flex items-center justify-between">
            <div>
              <p class="font-medium text-gray-700 dark:text-gray-300">Dark Mode</p>
              <p class="text-sm text-gray-500 dark:text-gray-400">
                Toggle between light and dark themes
              </p>
            </div>
            <button
              onClick={() => setDarkMode(!darkMode())}
              class={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
                darkMode() ? 'bg-blue-600' : 'bg-gray-200 dark:bg-gray-700'
              }`}
            >
              <span
                class={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                  darkMode() ? 'translate-x-6' : 'translate-x-1'
                }`}
              />
            </button>
          </div>
        </section>

        {/* API Configuration */}
        <section class="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-6">
          <h2 class="text-lg font-semibold text-gray-900 dark:text-white mb-4 flex items-center gap-2">
            <Server class="w-5 h-5" />
            API Configuration
          </h2>
          
          <div class="space-y-4">
            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                API Endpoint
              </label>
              <input
                type="text"
                value={apiEndpoint()}
                onInput={(e) => setApiEndpoint(e.currentTarget.value)}
                class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                placeholder="http://localhost:3000"
              />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1 flex items-center gap-1">
                <Key class="w-4 h-4" />
                API Key
              </label>
              <input
                type="password"
                value={apiKey()}
                onInput={(e) => setApiKey(e.currentTarget.value)}
                class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                placeholder="Enter your API key"
              />
            </div>
          </div>
        </section>

        {/* Preferences */}
        <section class="bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-6">
          <h2 class="text-lg font-semibold text-gray-900 dark:text-white mb-4 flex items-center gap-2">
            <Bell class="w-5 h-5" />
            Preferences
          </h2>
          
          <div class="space-y-4">
            <div class="flex items-center justify-between">
              <div>
                <p class="font-medium text-gray-700 dark:text-gray-300">Notifications</p>
                <p class="text-sm text-gray-500 dark:text-gray-400">
                  Receive notifications for new messages
                </p>
              </div>
              <button
                onClick={() => setNotifications(!notifications())}
                class={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
                  notifications() ? 'bg-blue-600' : 'bg-gray-200 dark:bg-gray-700'
                }`}
              >
                <span
                  class={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                    notifications() ? 'translate-x-6' : 'translate-x-1'
                  }`}
                />
              </button>
            </div>

            <div class="flex items-center justify-between">
              <div>
                <p class="font-medium text-gray-700 dark:text-gray-300">Auto-save</p>
                <p class="text-sm text-gray-500 dark:text-gray-400">
                  Automatically save conversation history
                </p>
              </div>
              <button
                onClick={() => setAutoSave(!autoSave())}
                class={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
                  autoSave() ? 'bg-blue-600' : 'bg-gray-200 dark:bg-gray-700'
                }`}
              >
                <span
                  class={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                    autoSave() ? 'translate-x-6' : 'translate-x-1'
                  }`}
                />
              </button>
            </div>
          </div>
        </section>

        {/* Actions */}
        <div class="flex items-center justify-end gap-3">
          <button
            onClick={handleReset}
            class="flex items-center gap-2 px-4 py-2 text-gray-600 dark:text-gray-400 hover:text-gray-800 dark:hover:text-gray-200 transition-colors"
          >
            <RotateCcw class="w-4 h-4" />
            Reset to Defaults
          </button>
          <button
            onClick={handleSave}
            class="flex items-center gap-2 px-6 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-medium transition-colors"
          >
            <Save class="w-4 h-4" />
            Save Settings
          </button>
        </div>
      </div>
    </div>
  );
};
