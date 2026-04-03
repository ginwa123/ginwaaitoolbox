import { dbDeleteConfig, dbGetConfig, dbListConfig, dbSetConfig } from './db';

/**
 * Get a config value by key
 * @returns The value if found, null if not found
 */
export async function getConfig(key: string): Promise<{ value: string | null }> {
  const value = dbGetConfig(key);
  return { value };
}

/**
 * Set a config value (insert or update)
 */
export async function setConfig(key: string, value: string): Promise<{ success: boolean }> {
  dbSetConfig(key, value);
  return { success: true };
}

/**
 * Delete a config entry by key
 */
export async function deleteConfig(key: string): Promise<{ success: boolean }> {
  dbDeleteConfig(key);
  return { success: true };
}

/**
 * List all config entries
 */
export async function listConfig(): Promise<{ entries: Array<{ key: string; value: string }> }> {
  const entries = dbListConfig();
  return { entries };
}
