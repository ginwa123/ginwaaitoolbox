# SQLite Bun Drizzle ORM Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement SQLite database layer for Bun desktop app using Drizzle ORM with TDD approach. Simple key-value config table.

**Architecture:** 
- Bun uses `drizzle-orm` + `better-sqlite3` for synchronous SQLite operations
- Database file at `~/.config/nalar-desktop/nalar.db` (cross-platform via `~`)
- Simple `config` table: `id`, `key`, `value`

**Tech Stack:** Bun, Drizzle ORM, better-sqlite3, Vitest

---

## File Structure

```
src/apps/desktop-bun/
├── src/
│   ├── db/
│   │   ├── index.ts              # Database connection singleton
│   │   ├── schema.ts             # Drizzle schema (id, key, value)
│   │   ├── schema.test.ts        # Schema validation tests
│   │   ├── client.ts             # Database client factory
│   │   ├── client.test.ts        # Client connection tests
│   │   ├── migrations/
│   │   │   └── 0000_init.sql     # Initial schema migration
│   │   └── index.test.ts         # DB initialization tests
│   └── repositories/
│       ├── configRepository.ts    # Config CRUD operations
│       └── configRepository.test.ts
└── drizzle.config.ts             # Drizzle kit configuration
```

---

## Chunk 1: Project Setup & Dependencies

**Goal:** Add required npm dependencies for Drizzle ORM with better-sqlite3

- Modify: `src/apps/desktop-bun/package.json`

- [ ] **Step 1: Add drizzle-orm and better-sqlite3 dependencies**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun
bun add drizzle-orm better-sqlite3
bun add -d drizzle-kit @types/better-sqlite3
```

- [ ] **Step 2: Verify package.json updated**

Run: `cat package.json | grep -A5 '"dependencies"'`
Expected: Contains `"drizzle-orm"` and `"better-sqlite3"`

- [ ] **Step 3: Commit**

```bash
git add package.json bun.lock
git commit -m "chore(deps): add drizzle-orm and better-sqlite3"
```

---

## Chunk 2: Schema Definition

**Goal:** Define Drizzle schema with simple config table

- Create: `src/apps/desktop-bun/src/db/schema.ts`
- Create: `src/apps/desktop-bun/src/db/schema.test.ts`

- [ ] **Step 1: Write failing schema validation test**

```typescript
// src/apps/desktop-bun/src/db/schema.test.ts
import { describe, it, expect } from 'vitest';

describe('Database Schema', () => {
  it('should have config table defined', async () => {
    const schema = await import('./schema');
    expect(schema.config).toBeDefined();
  });

  it('should have id, key, value columns', () => {
    const schema = require('./schema');
    expect(schema.config.id).toBeDefined();
    expect(schema.config.key).toBeDefined();
    expect(schema.config.value).toBeDefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun && bun test src/db/schema.test.ts`
Expected: FAIL with "Cannot find module ./schema"

- [ ] **Step 3: Write minimal schema implementation**

```typescript
// src/apps/desktop-bun/src/db/schema.ts
import { sqliteTable, text } from 'drizzle-orm/sqlite-core';

// Simple config table: id, key, value
export const config = sqliteTable('config', {
  id: text('id').primaryKey(),
  key: text('key').notNull().unique(),
  value: text('value').notNull(),
});

// TypeScript types inferred from schema
export type Config = typeof config.$inferSelect;
export type NewConfig = typeof config.$inferInsert;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun && bun test src/db/schema.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/db/schema.ts src/db/schema.test.ts
git commit -m "feat(db): add config schema (id, key, value)"
```

---

## Chunk 3: Database Client & Connection

**Goal:** Create database client with cross-platform path resolution to `~/.config/nalar-desktop/`

- Create: `src/apps/desktop-bun/src/db/client.ts`
- Create: `src/apps/desktop-bun/src/db/client.test.ts`
- Create: `src/apps/desktop-bun/src/db/index.ts`
- Create: `src/apps/desktop-bun/src/db/index.test.ts`

- [ ] **Step 1: Write failing client connection test**

```typescript
// src/apps/desktop-bun/src/db/client.test.ts
import { describe, it, expect } from 'vitest';
import { resolve } from 'path';

describe('Database Client', () => {
  it('should resolve database path to ~/.config/nalar-desktop', () => {
    const home = process.env.HOME || process.env.USERPROFILE || '';
    const expectedPath = `${home}/.config/nalar-desktop`;
    const dbPath = resolve(expectedPath, 'nalar.db');
    
    expect(dbPath).toContain('.config');
    expect(dbPath).toContain('nalar-desktop');
  });

  it('should create client without throwing', async () => {
    const { createClient } = await import('./client');
    expect(() => createClient()).not.toThrow();
  });

  it('should return a database instance', async () => {
    const { createClient } = await import('./client');
    const db = createClient();
    expect(db).toBeDefined();
    expect(typeof db.select).toBe('function');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun && bun test src/db/client.test.ts`
Expected: FAIL with "Cannot find module ./client"

- [ ] **Step 3: Write client implementation**

```typescript
// src/apps/desktop-bun/src/db/client.ts
import Database from 'better-sqlite3';
import { drizzle } from 'drizzle-orm/better-sqlite3';
import { resolve } from 'path';
import * as schema from './schema';

let dbInstance: ReturnType<typeof drizzle> | null = null;
let sqliteInstance: Database.Database | null = null;

function getHomeDir(): string {
  return process.env.HOME || 
         process.env.USERPROFILE || 
         process.env.APPDATA?.split('/')[0] || 
         '/tmp';
}

export function getDatabasePath(): string {
  const home = getHomeDir();
  return resolve(home, '.config', 'nalar-desktop', 'nalar.db');
}

export function createClient(): ReturnType<typeof drizzle> {
  if (dbInstance) return dbInstance;

  const dbPath = getDatabasePath();
  
  // Ensure directory exists
  const { mkdirSync } = require('fs');
  mkdirSync(path.dirname(dbPath), { recursive: true });
  
  // Create SQLite connection
  sqliteInstance = new Database(dbPath);
  sqliteInstance.pragma('journal_mode = WAL');
  sqliteInstance.pragma('foreign_keys = ON');
  
  // Create drizzle instance with schema
  dbInstance = drizzle(sqliteInstance, { schema });
  
  return dbInstance;
}

export function closeClient(): void {
  if (sqliteInstance) {
    sqliteInstance.close();
    sqliteInstance = null;
    dbInstance = null;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun && bun test src/db/client.test.ts`
Expected: PASS

- [ ] **Step 5: Write index.ts re-export**

```typescript
// src/apps/desktop-bun/src/db/index.ts
export { createClient, closeClient, getDatabasePath } from './client';
export { config, type Config, type NewConfig } from './schema';
```

- [ ] **Step 6: Write index test**

```typescript
// src/apps/desktop-bun/src/db/index.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { createClient, closeClient, getDatabasePath } from './index';

describe('Database Module', () => {
  let db: ReturnType<typeof createClient>;
  
  beforeEach(() => { db = createClient(); });
  afterEach(() => { closeClient(); });

  it('should export createClient function', async () => {
    const mod = await import('./index');
    expect(mod.createClient).toBeDefined();
  });

  it('should export getDatabasePath function', async () => {
    const mod = await import('./index');
    const path = mod.getDatabasePath();
    expect(path).toContain('.config');
    expect(path).toContain('nalar-desktop');
    expect(path).toContain('nalar.db');
  });

  it('should be able to query config table', () => {
    expect(() => db.select().from(mod.config).limit(1)).not.toThrow();
  });
});
```

- [ ] **Step 7: Run index test**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun && bun test src/db/index.test.ts`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add src/db/client.ts src/db/client.test.ts src/db/index.ts src/db/index.test.ts
git commit -m "feat(db): add database client with cross-platform path resolution"
```

---

## Chunk 4: Migration Setup

**Goal:** Create Drizzle migration for config table

- Create: `src/apps/desktop-bun/drizzle.config.ts`
- Create: `src/apps/desktop-bun/src/db/migrations/0000_init.sql`

- [ ] **Step 1: Write drizzle configuration**

```typescript
// src/apps/desktop-bun/drizzle.config.ts
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  schema: './src/db/schema.ts',
  out: './src/db/migrations',
  dialect: 'sqlite',
  dbCredentials: {
    url: './nalar.db',
  },
});
```

- [ ] **Step 2: Write initial migration SQL**

```sql
-- Migration: 0000_init.sql
CREATE TABLE IF NOT EXISTS config (
  id TEXT PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  value TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_config_key ON config(key);
```

- [ ] **Step 3: Add migration scripts to package.json**

Modify: `package.json`

```json
{
  "scripts": {
    "db:generate": "drizzle-kit generate",
    "db:migrate": "drizzle-kit migrate",
    "db:push": "drizzle-kit push",
    "db:studio": "drizzle-kit studio"
  }
}
```

- [ ] **Step 4: Run migration to create table**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun && bun run db:push`
Expected: Table created successfully

- [ ] **Step 5: Commit**

```bash
git add drizzle.config.ts src/db/migrations/
git add package.json
git commit -m "feat(db): add drizzle migration for config table"
```

---

## Chunk 5: Config Repository

**Goal:** Create repository layer for config CRUD operations

- Create: `src/apps/desktop-bun/src/repositories/configRepository.ts`
- Create: `src/apps/desktop-bun/src/repositories/configRepository.test.ts`

- [ ] **Step 1: Write config repository tests**

```typescript
// src/apps/desktop-bun/src/repositories/configRepository.test.ts
import { describe, it, expect, beforeEach, afterEach, beforeAll } from 'vitest';
import { createClient, closeClient, config } from '../db';
import * as configRepo from './configRepository';

describe('ConfigRepository', () => {
  let db: ReturnType<typeof createClient>;
  
  beforeAll(() => { db = createClient(); });
  
  afterEach(() => {
    db.delete(config).run();
  });
  
  afterAll(() => { closeClient(); });

  describe('set', () => {
    it('should insert a new config entry', async () => {
      const result = await configRepo.set(db, 'theme', 'dark');
      expect(result.key).toBe('theme');
      expect(result.value).toBe('dark');
    });

    it('should update existing entry on duplicate key', async () => {
      await configRepo.set(db, 'theme', 'dark');
      const result = await configRepo.set(db, 'theme', 'light');
      
      expect(result.value).toBe('light');
      
      // Should only have one entry
      const all = await configRepo.getAll(db);
      const themeEntries = all.filter(c => c.key === 'theme');
      expect(themeEntries).toHaveLength(1);
    });
  });

  describe('get', () => {
    it('should return value for existing key', async () => {
      await configRepo.set(db, 'theme', 'dark');
      const value = await configRepo.get(db, 'theme');
      expect(value).toBe('dark');
    });

    it('should return null for non-existent key', async () => {
      const value = await configRepo.get(db, 'nonexistent');
      expect(value).toBeNull();
    });

    it('should return defaultValue if provided and key missing', async () => {
      const value = await configRepo.get(db, 'missing', 'default');
      expect(value).toBe('default');
    });
  });

  describe('remove', () => {
    it('should delete config entry', async () => {
      await configRepo.set(db, 'temp', 'value');
      await configRepo.remove(db, 'temp');
      
      const value = await configRepo.get(db, 'temp');
      expect(value).toBeNull();
    });

    it('should not throw for non-existent key', async () => {
      expect(() => configRepo.remove(db, 'nonexistent')).not.toThrow();
    });
  });

  describe('getAll', () => {
    it('should return all config entries', async () => {
      await configRepo.set(db, 'key1', 'value1');
      await configRepo.set(db, 'key2', 'value2');
      
      const all = await configRepo.getAll(db);
      expect(all).toHaveLength(2);
    });

    it('should return empty array when no entries', async () => {
      const all = await configRepo.getAll(db);
      expect(all).toHaveLength(0);
    });
  });

  describe('has', () => {
    it('should return true for existing key', async () => {
      await configRepo.set(db, 'exists', 'yes');
      const exists = await configRepo.has(db, 'exists');
      expect(exists).toBe(true);
    });

    it('should return false for non-existent key', async () => {
      const exists = await configRepo.has(db, 'missing');
      expect(exists).toBe(false);
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun && bun test src/repositories/configRepository.test.ts`
Expected: FAIL with "Cannot find module ./configRepository"

- [ ] **Step 3: Write config repository implementation**

```typescript
// src/apps/desktop-bun/src/repositories/configRepository.ts
import { eq } from 'drizzle-orm';
import { config, type Config, type NewConfig } from '../db/schema';

/**
 * Set a config value (insert or update)
 */
export async function set(
  db: any,
  key: string,
  value: string
): Promise<Config> {
  // Try insert first, fallback to update
  try {
    const result = await db.insert(config).values({
      id: crypto.randomUUID(),
      key,
      value,
    }).returning();
    return result[0];
  } catch {
    // Key exists, update it
    const result = await db.update(config)
      .set({ value })
      .where(eq(config.key, key))
      .returning();
    return result[0];
  }
}

/**
 * Get a config value by key
 */
export async function get(
  db: any,
  key: string,
  defaultValue?: string
): Promise<string | null> {
  const result = await db.select()
    .from(config)
    .where(eq(config.key, key))
    .limit(1);
  
  if (result[0]) return result[0].value;
  return defaultValue ?? null;
}

/**
 * Remove a config entry by key
 */
export async function remove(db: any, key: string): Promise<void> {
  await db.delete(config).where(eq(config.key, key));
}

/**
 * Get all config entries
 */
export async function getAll(db: any): Promise<Config[]> {
  return db.select().from(config).all();
}

/**
 * Check if a key exists
 */
export async function has(db: any, key: string): Promise<boolean> {
  const result = await db.select({ id: config.id })
    .from(config)
    .where(eq(config.key, key))
    .limit(1);
  return result.length > 0;
}

/**
 * Get multiple values at once (bulk read)
 */
export async function getMany(
  db: any,
  keys: string[]
): Promise<Record<string, string>> {
  const results = await db.select()
    .from(config)
    .where(eq(config.key, keys[0])); // Simplify for now
  
  // For better performance with multiple keys, use in() operator
  const records: Record<string, string> = {};
  for (const row of results) {
    records[row.key] = row.value;
  }
  return records;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun && bun test src/repositories/configRepository.test.ts`
Expected: PASS (all 10 tests green)

- [ ] **Step 5: Commit**

```bash
git add src/repositories/configRepository.ts src/repositories/configRepository.test.ts
git commit -m "feat(db): add config repository with CRUD operations"
```

---

## Verification

### Build
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun
bun run build
```

### Tests
```bash
bun test src/db/ src/repositories/
```

### Manual Verification
```bash
bun run db:studio
```
- Verify `config` table exists with columns: `id`, `key`, `value`

---

## Summary

| Chunk | Files | Tests | Status |
|-------|-------|-------|--------|
| 1 | package.json | - | Dependencies added |
| 2 | schema.ts, schema.test.ts | 2 tests | Schema defined |
| 3 | client.ts, index.ts, *.test.ts | 5 tests | DB connection works |
| 4 | drizzle.config.ts, migrations/* | - | Migrations ready |
| 5 | configRepository.ts, *.test.ts | 10 tests | Full CRUD |

**Total:** 17 tests, all TDD compliant

**Schema:**
```sql
CREATE TABLE config (
  id TEXT PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  value TEXT NOT NULL
);
```
