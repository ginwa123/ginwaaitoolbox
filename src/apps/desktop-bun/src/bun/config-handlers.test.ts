import { afterEach, describe, expect, it } from 'vitest';
import { deleteConfig, getConfig, listConfig, setConfig } from './config-handlers';

describe('Config Handlers', () => {
  const testKey = 'test_config_key';
  const testValue = 'test_config_value';
  const SESSION_DIR_KEY = 'session_dir';

  afterEach(async () => {
    // Cleanup test data
    await deleteConfig(testKey);
    await deleteConfig(`${testKey}_2`);
  });

  it('should set and get config value', async () => {
    await setConfig(testKey, testValue);
    const result = await getConfig(testKey);
    expect(result.value).toBe(testValue);
  });

  it('should return null for non-existent key', async () => {
    const result = await getConfig('non_existent_key_xyz');
    expect(result.value).toBeNull();
  });

  it('should update existing config value', async () => {
    await setConfig(testKey, testValue);
    await setConfig(testKey, 'updated_value');
    const result = await getConfig(testKey);
    expect(result.value).toBe('updated_value');
  });

  it('should delete config entry', async () => {
    await setConfig(testKey, testValue);
    await deleteConfig(testKey);
    const result = await getConfig(testKey);
    expect(result.value).toBeNull();
  });

  it('should list all config entries', async () => {
    await setConfig(testKey, testValue);
    await setConfig(`${testKey}_2`, 'value_2');
    const result = await listConfig();
    expect(result.entries.length).toBeGreaterThanOrEqual(2);
    expect(result.entries.some((e) => e.key === testKey && e.value === testValue)).toBe(true);
    expect(result.entries.some((e) => e.key === `${testKey}_2` && e.value === 'value_2')).toBe(
      true
    );
  });

  it('should persist and retrieve session directory', async () => {
    const testPath = '/home/user/projects';

    // Set session dir
    await setConfig(SESSION_DIR_KEY, testPath);

    // Get session dir
    const result = await getConfig(SESSION_DIR_KEY);
    expect(result.value).toBe(testPath);
  });

  it('should return null for non-existent session directory', async () => {
    // First ensure it's deleted
    await deleteConfig(SESSION_DIR_KEY);

    const result = await getConfig(SESSION_DIR_KEY);
    expect(result.value).toBeNull();
  });
});
