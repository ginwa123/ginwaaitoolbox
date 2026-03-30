import { describe, expect, test } from 'bun:test';
import { parsePortFromCmdline } from './processDiscovery';

describe('parsePortFromCmdline', () => {
  test('parses --port 8080 from command line', () => {
    const cmdline = '/usr/local/bin/nalar --verbose --port 8080 --process nalar';
    expect(parsePortFromCmdline(cmdline)).toBe(8080);
  });

  test('parses --port 9090 from command line', () => {
    const cmdline = 'nalar --port 9090';
    expect(parsePortFromCmdline(cmdline)).toBe(9090);
  });

  test('returns null when no port specified', () => {
    const cmdline = '/usr/local/bin/nalar --verbose';
    expect(parsePortFromCmdline(cmdline)).toBeNull();
  });

  test('returns null when no nalar process', () => {
    const cmdline = 'some-other-process --port 8080';
    expect(parsePortFromCmdline(cmdline)).toBeNull();
  });
});

describe('findNalarPort', () => {
  test('returns a valid port number', () => {
    const port = parsePortFromCmdline('nalar --port 12345');
    expect(port).toBe(12345);
  });
});
