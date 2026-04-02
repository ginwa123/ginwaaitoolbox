/**
 * File System Utilities for Bun Desktop App
 * 
 * These utilities handle all file system operations directly in Bun,
 * keeping the Zig backend focused only on AI/LLM processing.
 */

import { readdir, stat, mkdir, rename, rm } from "node:fs/promises";
import { existsSync } from "node:fs";

// =============================================================================
// Types
// =============================================================================

export interface FileEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  isHidden: boolean;
  modifiedAt: string;
  size: number;
}

export interface ListOptions {
  path: string;
  showHidden?: boolean;
}

// =============================================================================
// List Directory
// =============================================================================

export async function listDirectory(
  options: ListOptions
): Promise<{ entries: FileEntry[]; error?: string }> {
  const { path, showHidden = false } = options;

  try {
    // Validate path exists
    if (!existsSync(path)) {
      return { entries: [], error: "Path does not exist" };
    }

    const entries = await readdir(path, { withFileTypes: true });
    const results: FileEntry[] = [];

    for (const entry of entries) {
      const isHidden = entry.name.startsWith(".");
      if (!showHidden && isHidden) continue;

      const fullPath = `${path}/${entry.name}`;
      let modifiedAt = "";
      let size = 0;

      try {
        const stats = await stat(fullPath);
        modifiedAt = stats.mtime.toISOString();
        size = stats.size;
      } catch {
        // Skip stats for inaccessible files
      }

      results.push({
        name: entry.name,
        path: fullPath,
        isDirectory: entry.isDirectory(),
        isHidden,
        modifiedAt,
        size,
      });
    }

    // Sort: directories first, then alphabetically
    results.sort((a, b) => {
      if (a.isDirectory !== b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });

    return { entries: results };
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    return { entries: [], error };
  }
}

// =============================================================================
// Create Directory
// =============================================================================

export async function createDirectory(
  parentPath: string,
  name: string
): Promise<{ success: boolean; path?: string; error?: string }> {
  const fullPath = `${parentPath}/${name}`;

  try {
    await mkdir(fullPath, { recursive: false });
    return { success: true, path: fullPath };
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    return { success: false, error };
  }
}

// =============================================================================
// Rename/Move
// =============================================================================

export async function renamePath(
  oldPath: string,
  newPath: string
): Promise<{ success: boolean; error?: string }> {
  try {
    await rename(oldPath, newPath);
    return { success: true };
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    return { success: false, error };
  }
}

// =============================================================================
// Delete
// =============================================================================

export async function deletePath(
  path: string,
  isDirectory: boolean
): Promise<{ success: boolean; error?: string }> {
  try {
    if (isDirectory) {
      await rm(path, { recursive: true, force: true });
    } else {
      await rm(path, { force: true });
    }
    return { success: true };
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    return { success: false, error };
  }
}
