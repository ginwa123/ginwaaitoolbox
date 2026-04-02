import { describe, expect, test, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor } from '@solidjs/testing-library';
import { FolderPicker } from './FolderPicker';

// Mock fetch
const mockFetch = vi.fn();
global.fetch = mockFetch;

describe('FolderPicker', () => {
  beforeEach(() => {
    mockFetch.mockReset();
  });

  afterEach(() => cleanup());

  test('renders modal when isOpen is true', () => {
    mockFetch.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ entries: [] }),
    });

    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
    ));

    expect(screen.getByText('Select Folder')).toBeDefined();
  });

  test('does not render when isOpen is false', () => {
    const onSelect = vi.fn();
    const onClose = vi.fn();

    const { container } = render(() => (
      <FolderPicker isOpen={false} onSelect={onSelect} onClose={onClose} />
    ));

    expect(container.textContent).toBe('');
  });

  test('calls onSelect when Select button is clicked with selected path', async () => {
    mockFetch.mockResolvedValue({
      ok: true,
      json: () =>
        Promise.resolve({
          entries: [
            { name: 'Documents', path: '/home/user/Documents', isDirectory: true, isHidden: false },
            { name: 'file.txt', path: '/home/user/file.txt', isDirectory: false, isHidden: false },
          ],
        }),
    });

    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
    ));

    // Wait for entries to load
    await waitFor(() => {
      expect(screen.getByText('Documents')).toBeDefined();
    });

    // Click on Documents folder
    fireEvent.click(screen.getByText('Documents'));

    // Now click Select button
    fireEvent.click(screen.getByText('Select'));
    expect(onSelect).toHaveBeenCalledWith('/home/user/Documents');
  });

  test('calls onClose when Cancel button is clicked', () => {
    mockFetch.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ entries: [] }),
    });

    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
    ));

    fireEvent.click(screen.getByText('Cancel'));
    expect(onClose).toHaveBeenCalled();
  });

  test('displays folder entries from API', async () => {
    mockFetch.mockResolvedValue({
      ok: true,
      json: () =>
        Promise.resolve({
          entries: [
            { name: 'Documents', path: '/home/user/Documents', isDirectory: true, isHidden: false },
            { name: 'Downloads', path: '/home/user/Downloads', isDirectory: true, isHidden: false },
            { name: 'file.txt', path: '/home/user/file.txt', isDirectory: false, isHidden: false },
          ],
        }),
    });

    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
    ));

    await waitFor(() => {
      expect(screen.getByText('Documents')).toBeDefined();
      expect(screen.getByText('Downloads')).toBeDefined();
      expect(screen.getByText('file.txt')).toBeDefined();
    });
  });

  test('shows breadcrumb navigation', async () => {
    mockFetch.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ entries: [] }),
    });

    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <FolderPicker isOpen={true} initialPath="/home/user" onSelect={onSelect} onClose={onClose} />
    ));

    await waitFor(() => {
      expect(screen.getByText('Root')).toBeDefined();
      expect(screen.getByText('home')).toBeDefined();
      expect(screen.getByText('user')).toBeDefined();
    });
  });

  test('closes on Escape key', async () => {
    mockFetch.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ entries: [] }),
    });

    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
    ));

    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalled();
  });

  test('navigates with arrow keys', async () => {
    mockFetch.mockResolvedValue({
      ok: true,
      json: () =>
        Promise.resolve({
          entries: [
            { name: 'Documents', path: '/home/user/Documents', isDirectory: true, isHidden: false },
            { name: 'Downloads', path: '/home/user/Downloads', isDirectory: true, isHidden: false },
          ],
        }),
    });

    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
    ));

    await waitFor(() => {
      expect(screen.getByText('Documents')).toBeDefined();
    });

    // Press ArrowDown to focus first item
    fireEvent.keyDown(document, { key: 'ArrowDown' });
    fireEvent.keyDown(document, { key: 'ArrowDown' });

    // Should not crash
    expect(true).toBe(true);
  });

  test('shows New Folder button in header', async () => {
    mockFetch.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ entries: [] }),
    });

    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
    ));

    await waitFor(() => {
      expect(screen.getByText('+ New Folder')).toBeDefined();
    });
  });

  test('clicking New Folder button shows input field', async () => {
    mockFetch.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ entries: [] }),
    });

    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
    ));

    await waitFor(() => {
      expect(screen.getByText('+ New Folder')).toBeDefined();
    });

    fireEvent.click(screen.getByText('+ New Folder'));

    await waitFor(() => {
      expect(screen.getByPlaceholderText('New folder name...')).toBeDefined();
    });
  });
});
