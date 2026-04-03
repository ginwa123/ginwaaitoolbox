import { integer, sqliteTable, text } from 'drizzle-orm/sqlite-core';

/**
 * Config table for nalar-desktop
 * Stores key-value pairs for application configuration
 */
export const configTable = sqliteTable('config', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  key: text('key').notNull().unique(),
  value: text('value').notNull(),
});

// Type exports for use in handlers
export type ConfigEntry = typeof configTable.$inferSelect;
export type NewConfigEntry = typeof configTable.$inferInsert;
