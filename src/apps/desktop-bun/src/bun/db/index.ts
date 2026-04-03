import { Database } from 'bun:sqlite';
import { existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { configTable } from './config-schema';

const CONFIG_DIR = join(process.env.HOME || '', '.config', 'nalar-desktop');
const CONFIG_DB_PATH = join(CONFIG_DIR, 'config.db');

/**
 * Ensure config directory exists
 */
function ensureConfigDir(): void {
  if (!existsSync(CONFIG_DIR)) {
    mkdirSync(CONFIG_DIR, { recursive: true });
    console.log(`[Config] Created config directory: ${CONFIG_DIR}`);
  }
}

/**
 * Initialize database connection and create tables
 */
function createDatabase(): Database {
  ensureConfigDir();

  const db = new Database(CONFIG_DB_PATH);

  // Create config table if not exists
  db.exec(`
    CREATE TABLE IF NOT EXISTS config (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      key TEXT NOT NULL UNIQUE,
      value TEXT NOT NULL
    )
  `);

  // Create index on key for faster lookups
  db.exec(`
    CREATE INDEX IF NOT EXISTS idx_config_key ON config(key)
  `);

  console.log(`[Config] Database initialized at: ${CONFIG_DB_PATH}`);

  return db;
}

// Singleton database instance
let _db: Database | null = null;

export function getDatabase(): Database {
  if (!_db) {
    _db = createDatabase();
  }
  return _db;
}

export function closeDatabase(): void {
  if (_db) {
    _db.close();
    _db = null;
    console.log('[Config] Database connection closed');
  }
}

// Re-export schema for convenience
export { configTable } from './config-schema';

/**
 * Get a config value by key
 */
export function dbGetConfig(key: string): string | null {
  const db = getDatabase();
  const stmt = db.prepare('SELECT value FROM config WHERE key = ?');
  const result = stmt.get(key) as { value: string } | undefined;
  return result?.value ?? null;
}

/**
 * Set a config value (upsert)
 */
export function dbSetConfig(key: string, value: string): void {
  const db = getDatabase();
  db.prepare(
    'INSERT INTO config (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?'
  ).run(key, value, value);
}

/**
 * Delete a config entry by key
 */
export function dbDeleteConfig(key: string): void {
  const db = getDatabase();
  db.prepare('DELETE FROM config WHERE key = ?').run(key);
}

/**
 * List all config entries
 */
export function dbListConfig(): Array<{ key: string; value: string }> {
  const db = getDatabase();
  const stmt = db.prepare('SELECT key, value FROM config ORDER BY key');
  return stmt.all() as Array<{ key: string; value: string }>;
}
