import { electroview } from '../main';

// Config keys
const CONFIG_KEY_SESSION_DIR = 'session_dir';
const DEFAULT_SESSION_DIR = '/';

/**
 * Get the selected session directory from config
 * Falls back to '/' if not set
 */
export async function getSessionDir(): Promise<string> {
  try {
    const result = await electroview.rpc.request.getConfig({ key: CONFIG_KEY_SESSION_DIR });
    return result.value ?? DEFAULT_SESSION_DIR;
  } catch (err) {
    console.warn('[Config] Failed to get session_dir, using default:', err);
    return DEFAULT_SESSION_DIR;
  }
}

/**
 * Set the selected session directory in config
 */
export async function setSessionDir(path: string): Promise<void> {
  try {
    await electroview.rpc.request.setConfig({ key: CONFIG_KEY_SESSION_DIR, value: path });
  } catch (err) {
    console.error('[Config] Failed to set session_dir:', err);
    throw err;
  }
}

/**
 * Get a config value by key
 */
export async function getConfig(key: string): Promise<string | null> {
  const result = await electroview.rpc.request.getConfig({ key });
  return result.value;
}

/**
 * Set a config value
 */
export async function setConfig(key: string, value: string): Promise<void> {
  const result = await electroview.rpc.request.setConfig({ key, value });
  if (!result.success) {
    throw new Error('Failed to set config');
  }
}

/**
 * Delete a config entry
 */
export async function deleteConfig(key: string): Promise<void> {
  const result = await electroview.rpc.request.deleteConfig({ key });
  if (!result.success) {
    throw new Error('Failed to delete config');
  }
}

/**
 * List all config entries
 */
export async function listConfig(): Promise<Array<{ key: string; value: string }>> {
  const result = await electroview.rpc.request.listConfig();
  return result.entries;
}
