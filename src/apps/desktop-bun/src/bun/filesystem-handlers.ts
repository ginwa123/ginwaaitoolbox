/**
 * Filesystem Handlers - Bun-side RPC implementations for filesystem operations
 *
 * These functions run in Bun's main process and are called via RPC
 * from the webview.
 */
import type { DirectoryEntry } from '../shared/rpc';
import * as fs from 'node:fs';
import * as path from 'node:path';

/**
 * List directory contents with metadata
 */
export function listDirectory(dirPath: string, showHidden: boolean): DirectoryEntry[] {
  const entries: DirectoryEntry[] = [];

  try {
    const items = fs.readdirSync(dirPath, { withFileTypes: true });

    for (const item of items) {
      const fullPath = path.join(dirPath, item.name);
      const isHidden = item.name.startsWith('.');

      // Skip hidden files if not showing hidden
      if (!showHidden && isHidden) continue;

      let modifiedAt = '';
      let size = 0;

      try {
        const stat = fs.statSync(fullPath);
        modifiedAt = stat.mtime.toISOString();
        size = stat.size;
      } catch {
        // Skip items we can't stat
      }

      entries.push({
        name: item.name,
        path: fullPath,
        isDirectory: item.isDirectory(),
        isHidden,
        modifiedAt,
        size,
      });
    }
  } catch (err) {
    console.error(`[Filesystem] Error listing ${dirPath}:`, err);
  }

  // Sort: directories first, then alphabetically
  return entries.sort((a, b) => {
    if (a.isDirectory !== b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.localeCompare(b.name);
  });
}

/**
 * Create a new folder
 */
export function createFolder(
  parentPath: string,
  name: string
): { success: boolean; path: string; error?: string } {
  const fullPath = path.join(parentPath, name);

  try {
    if (fs.existsSync(fullPath)) {
      return { success: false, path: fullPath, error: 'Folder already exists' };
    }
    fs.mkdirSync(fullPath, { recursive: false });
    return { success: true, path: fullPath };
  } catch (err) {
    return { success: false, path: fullPath, error: String(err) };
  }
}

/**
 * Rename/move a folder
 */
export function renameFolder(
  oldPath: string,
  newName: string
): { success: boolean; newPath: string; error?: string } {
  const parentPath = path.dirname(oldPath);
  const newPath = path.join(parentPath, newName);

  try {
    if (!fs.existsSync(oldPath)) {
      return { success: false, newPath, error: 'Folder does not exist' };
    }
    if (fs.existsSync(newPath)) {
      return { success: false, newPath, error: 'A folder with this name already exists' };
    }
    fs.renameSync(oldPath, newPath);
    return { success: true, newPath };
  } catch (err) {
    return { success: false, newPath, error: String(err) };
  }
}

/**
 * Delete an empty folder
 */
export function deleteFolder(folderPath: string): { success: boolean; error?: string } {
  try {
    if (!fs.existsSync(folderPath)) {
      return { success: false, error: 'Folder does not exist' };
    }

    const items = fs.readdirSync(folderPath);
    if (items.length > 0) {
      return { success: false, error: 'Folder is not empty' };
    }

    fs.rmdirSync(folderPath);
    return { success: true };
  } catch (err) {
    return { success: false, error: String(err) };
  }
}
