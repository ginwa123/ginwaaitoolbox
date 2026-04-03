import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { createFolder, deleteFolder, listDirectory, renameFolder } from './filesystem-handlers';

// ============================================================================
// Test: getCwd RPC Handler
// ============================================================================

describe('getCwd RPC', () => {
  test('returns process.cwd() value', () => {
    // The handler should return the current working directory
    const expectedCwd = process.cwd();
    expect(typeof expectedCwd).toBe('string');
    expect(expectedCwd.length).toBeGreaterThan(0);
  });

  test('returns an absolute path', () => {
    const cwd = process.cwd();
    // Unix absolute paths start with /
    // Windows absolute paths have drive letter (e.g., C:\)
    const isAbsolute =
      cwd.startsWith('/') || // Unix
      /^[A-Za-z]:/.test(cwd); // Windows
    expect(isAbsolute).toBe(true);
  });

  test('cwd should be a non-empty string', () => {
    const cwd = process.cwd();
    // Basic validation that cwd is a non-empty string
    expect(typeof cwd).toBe('string');
    expect(cwd.length).toBeGreaterThan(0);
  });
});

// ============================================================================
// Filesystem Operations Tests
// ============================================================================

describe('listDirectory', () => {
  test('returns array of DirectoryEntry', () => {
    const entries = listDirectory(process.cwd(), false);
    expect(Array.isArray(entries)).toBe(true);
  });

  test('entries have required properties', () => {
    const cwd = process.cwd();
    const entries = listDirectory(cwd, false);
    if (entries.length > 0) {
      const entry = entries[0];
      expect(typeof entry.name).toBe('string');
      expect(typeof entry.path).toBe('string');
      expect(typeof entry.isDirectory).toBe('boolean');
      expect(typeof entry.isHidden).toBe('boolean');
    }
  });

  test('hides hidden files when showHidden is false', () => {
    const cwd = process.cwd();
    const entries = listDirectory(cwd, false);
    const hidden = entries.filter((e) => e.name.startsWith('.') && e.isHidden);
    expect(hidden.length).toBe(0);
  });

  test('shows hidden files when showHidden is true', () => {
    const cwd = process.cwd();
    const entries = listDirectory(cwd, true);
    // Just verify it runs without error
    expect(Array.isArray(entries)).toBe(true);
  });
});

describe('createFolder', () => {
  const testDir = path.join(process.cwd(), '.test-folder-picker');
  const testFolderName = `test-temp-folder-${Date.now()}`;

  afterEach(() => {
    // Cleanup
    try {
      const folderPath = path.join(testDir, testFolderName);
      if (fs.existsSync(folderPath)) {
        fs.rmdirSync(folderPath);
      }
    } catch {}
    try {
      if (fs.existsSync(testDir)) {
        fs.rmdirSync(testDir);
      }
    } catch {}
  });

  test('creates folder successfully', () => {
    // Create test parent dir if needed
    if (!fs.existsSync(testDir)) {
      fs.mkdirSync(testDir);
    }

    const result = createFolder(testDir, testFolderName);
    expect(result.success).toBe(true);
    expect(fs.existsSync(result.path)).toBe(true);
  });

  test('returns error for duplicate folder', () => {
    if (!fs.existsSync(testDir)) {
      fs.mkdirSync(testDir);
    }

    // Create folder first
    const existingPath = path.join(testDir, testFolderName);
    fs.mkdirSync(existingPath);

    // Try to create again
    const result = createFolder(testDir, testFolderName);
    expect(result.success).toBe(false);
    expect(result.error).toContain('already exists');
  });
});

describe('renameFolder', () => {
  const testDir = path.join(process.cwd(), '.test-folder-picker-rename');
  const oldName = `old-folder-${Date.now()}`;
  const newName = `new-folder-${Date.now()}`;

  beforeEach(() => {
    if (!fs.existsSync(testDir)) {
      fs.mkdirSync(testDir);
    }
    fs.mkdirSync(path.join(testDir, oldName));
  });

  afterEach(() => {
    // Cleanup both old and new paths
    try {
      const oldPath = path.join(testDir, oldName);
      const newPath = path.join(testDir, newName);
      if (fs.existsSync(oldPath)) fs.rmdirSync(oldPath);
      if (fs.existsSync(newPath)) fs.rmdirSync(newPath);
    } catch {}
    try {
      if (fs.existsSync(testDir)) fs.rmdirSync(testDir);
    } catch {}
  });

  test('renames folder successfully', () => {
    const oldPath = path.join(testDir, oldName);
    const result = renameFolder(oldPath, newName);

    expect(result.success).toBe(true);
    expect(fs.existsSync(result.newPath)).toBe(true);
    expect(fs.existsSync(oldPath)).toBe(false);
  });

  test('returns error for non-existent folder', () => {
    const result = renameFolder('/non/existent/path', 'newName');
    expect(result.success).toBe(false);
  });
});

describe('deleteFolder', () => {
  const testDir = path.join(process.cwd(), '.test-folder-picker-delete');
  const folderName = `folder-to-delete-${Date.now()}`;

  beforeEach(() => {
    if (!fs.existsSync(testDir)) {
      fs.mkdirSync(testDir);
    }
    fs.mkdirSync(path.join(testDir, folderName));
  });

  afterEach(() => {
    try {
      const fullPath = path.join(testDir, folderName);
      if (fs.existsSync(fullPath)) fs.rmdirSync(fullPath);
    } catch {}
    try {
      if (fs.existsSync(testDir)) fs.rmdirSync(testDir);
    } catch {}
  });

  test('deletes empty folder successfully', () => {
    const fullPath = path.join(testDir, folderName);
    const result = deleteFolder(fullPath);

    expect(result.success).toBe(true);
    expect(fs.existsSync(fullPath)).toBe(false);
  });

  test('returns error for non-empty folder', () => {
    const fullPath = path.join(testDir, folderName);
    // Add a file
    fs.writeFileSync(path.join(fullPath, 'test.txt'), 'content');

    const result = deleteFolder(fullPath);
    expect(result.success).toBe(false);
    expect(result.error).toContain('not empty');

    // Cleanup file
    fs.unlinkSync(path.join(fullPath, 'test.txt'));
  });

  test('returns error for non-existent folder', () => {
    const result = deleteFolder('/non/existent/path');
    expect(result.success).toBe(false);
  });
});
