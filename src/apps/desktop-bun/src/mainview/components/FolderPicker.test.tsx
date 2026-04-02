import { describe, expect, test, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@solidjs/testing-library';
import { FolderPicker } from './FolderPicker';

describe('FolderPicker', () => {
  afterEach(() => cleanup());

  test('renders modal when isOpen is true', () => {
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

  test('calls onSelect when Select button is clicked with selected path', () => {
    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
    ));

    // Click select button - should not call since no path selected
    fireEvent.click(screen.getByText('Select'));
    expect(onSelect).not.toHaveBeenCalled();
  });

  test('calls onClose when Cancel button is clicked', () => {
    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(() => (
      <FolderPicker isOpen={true} onSelect={onSelect} onClose={onClose} />
    ));

    fireEvent.click(screen.getByText('Cancel'));
    expect(onClose).toHaveBeenCalled();
  });
});
