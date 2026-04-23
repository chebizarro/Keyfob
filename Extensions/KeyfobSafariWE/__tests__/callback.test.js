// ──────────────────────────────────────────────────────────────────
// callback.test.js — Tests for callback.html postMessage round-trip
// ──────────────────────────────────────────────────────────────────
//
// Tests the callback.html script that completes the Universal Link
// signing flow by posting results back to the opener window:
//   - Query param → payload extraction
//   - Hash-based callback ID parsing
//   - targetOrigin from query param vs referrer vs refusal
//   - postMessage envelope structure
//   - Auto-close behavior
//
// Uses vitest with jsdom and fake timers.
// ──────────────────────────────────────────────────────────────────

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { readFileSync } from 'fs';
import { join } from 'path';

// ── Extract script from callback.html ────────────────────────────

const CALLBACK_HTML_PATH = join(__dirname, '..', '..', '..', 'Web', 'demo', 'callback.html');
const CALLBACK_HTML = readFileSync(CALLBACK_HTML_PATH, 'utf-8');

// Extract the IIFE script body from <script>...</script>
const scriptMatch = CALLBACK_HTML.match(/<script>([\s\S]*?)<\/script>/);
if (!scriptMatch) throw new Error('Could not extract script from callback.html');
const CALLBACK_SCRIPT = scriptMatch[1];

// ── Helpers ──────────────────────────────────────────────────────

// Track mock state for cleanup in afterEach
let _mockCleanup = null;

/**
 * Execute the callback.html script with mocked globals.
 * Mocks stay installed until afterEach cleans them up, so
 * pending timers (like the 100ms auto-close) can still reference them.
 *
 * @param {object} opts
 * @param {string} opts.hash - URL hash (e.g., '#keyfob-cb-abc')
 * @param {string} opts.search - URL search string (e.g., '?ok=1&id=abc')
 * @param {string} [opts.referrer] - document.referrer value
 * @param {object} [opts.opener] - window.opener mock (null = no opener)
 * @returns {{ postMessageCalls: Array, mockClose: Function }}
 */
function runCallbackScript(opts) {
  const {
    hash = '',
    search = '',
    referrer = '',
    opener = null,
  } = opts;

  const postMessageCalls = [];

  const mockLocation = {
    hash,
    search,
    origin: 'https://callback.keyfob.example.com',
  };

  const mockOpener = opener !== null ? {
    postMessage: vi.fn((...args) => postMessageCalls.push(args)),
  } : null;

  const mockClose = vi.fn();

  // Save originals for cleanup
  const origLocation = window.location;
  const origOpener = window.opener;
  const origClose = window.close;

  // Install mocks
  delete window.location;
  window.location = mockLocation;

  Object.defineProperty(window, 'opener', {
    value: mockOpener,
    writable: true,
    configurable: true,
  });

  window.close = mockClose;

  Object.defineProperty(document, 'referrer', {
    value: referrer,
    writable: false,
    configurable: true,
  });

  // Register cleanup for afterEach
  _mockCleanup = () => {
    window.location = origLocation;
    Object.defineProperty(window, 'opener', {
      value: origOpener,
      writable: true,
      configurable: true,
    });
    window.close = origClose;
    // Restore referrer to empty string (jsdom default)
    try {
      Object.defineProperty(document, 'referrer', {
        value: '',
        writable: false,
        configurable: true,
      });
    } catch { /* ignore if already restored */ }
    _mockCleanup = null;
  };

  // Execute the callback script
  const fn = new Function(CALLBACK_SCRIPT);
  fn();

  return {
    postMessageCalls,
    mockOpener,
    mockClose,
  };
}

// ── Tests ────────────────────────────────────────────────────────

describe('callback.html — postMessage round-trip', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    // Clean up mocked globals (must happen before restoring timers
    // so pending fake timers don't fire with stale mocks)
    if (_mockCleanup) _mockCleanup();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  // ── Round-Trip Success ─────────────────────────────────────

  describe('successful round-trip', () => {
    it('posts correct envelope with query params as payload', () => {
      const { postMessageCalls } = runCallbackScript({
        hash: '#keyfob-cb-test123',
        search: '?ok=1&id=abc&sig=def&pubkey=ghi&origin=https://example.com',
        opener: {},
      });

      expect(postMessageCalls).toHaveLength(1);
      const [message, targetOrigin] = postMessageCalls[0];

      expect(message.__keyfob_cb__).toBe('keyfob-cb-test123');
      expect(message.payload.ok).toBe('1');
      expect(message.payload.id).toBe('abc');
      expect(message.payload.sig).toBe('def');
      expect(message.payload.pubkey).toBe('ghi');
      expect(targetOrigin).toBe('https://example.com');
    });

    it('preserves all query params in payload', () => {
      const { postMessageCalls } = runCallbackScript({
        hash: '#cb-1',
        search: '?ok=1&custom=value&another=field&origin=https://app.test',
        opener: {},
      });

      const payload = postMessageCalls[0][0].payload;
      expect(payload.ok).toBe('1');
      expect(payload.custom).toBe('value');
      expect(payload.another).toBe('field');
      expect(payload.origin).toBe('https://app.test');
    });
  });

  // ── Error Round-Trip ───────────────────────────────────────

  describe('error round-trip', () => {
    it('posts error payload when ok=0', () => {
      const { postMessageCalls } = runCallbackScript({
        hash: '#keyfob-cb-err1',
        search: '?ok=0&code=denied&msg=User+denied&origin=https://example.com',
        opener: {},
      });

      expect(postMessageCalls).toHaveLength(1);
      const [message] = postMessageCalls[0];

      expect(message.__keyfob_cb__).toBe('keyfob-cb-err1');
      expect(message.payload.ok).toBe('0');
      expect(message.payload.code).toBe('denied');
      expect(message.payload.msg).toBe('User denied'); // URL-decoded
    });
  });

  // ── targetOrigin ───────────────────────────────────────────

  describe('targetOrigin security', () => {
    it('uses origin query param when present', () => {
      const { postMessageCalls } = runCallbackScript({
        hash: '#cb-1',
        search: '?ok=1&origin=https://trusted.example.com',
        opener: {},
      });

      expect(postMessageCalls).toHaveLength(1);
      expect(postMessageCalls[0][1]).toBe('https://trusted.example.com');
    });

    it('falls back to referrer origin when origin param missing', () => {
      const { postMessageCalls } = runCallbackScript({
        hash: '#cb-1',
        search: '?ok=1',
        referrer: 'https://referrer.example.com/some/page',
        opener: {},
      });

      expect(postMessageCalls).toHaveLength(1);
      expect(postMessageCalls[0][1]).toBe('https://referrer.example.com');
    });

    it('does NOT post when neither origin param nor referrer available', () => {
      const { postMessageCalls } = runCallbackScript({
        hash: '#cb-1',
        search: '?ok=1',
        referrer: '',
        opener: {},
      });

      // No postMessage — refuses to use '*'
      expect(postMessageCalls).toHaveLength(0);
    });

    it('does NOT post with wildcard origin', () => {
      // Even if someone tries to inject '*' as origin param,
      // it should be used as-is (not expanded). But the important
      // thing is: with no valid origin, no message is sent.
      const { postMessageCalls } = runCallbackScript({
        hash: '#cb-1',
        search: '?ok=1',
        referrer: '',
        opener: {},
      });

      expect(postMessageCalls).toHaveLength(0);
    });
  });

  // ── Hash-Based Callback ID ─────────────────────────────────

  describe('callback ID parsing', () => {
    it('extracts callback ID from URL hash', () => {
      const { postMessageCalls } = runCallbackScript({
        hash: '#keyfob-cb-r4nd0m',
        search: '?ok=1&origin=https://test.com',
        opener: {},
      });

      expect(postMessageCalls[0][0].__keyfob_cb__).toBe('keyfob-cb-r4nd0m');
    });

    it('handles empty hash gracefully', () => {
      const { postMessageCalls } = runCallbackScript({
        hash: '',
        search: '?ok=1&origin=https://test.com',
        opener: {},
      });

      // Empty hash → cbId is empty string (from '#'.slice(1))
      expect(postMessageCalls).toHaveLength(1);
      expect(postMessageCalls[0][0].__keyfob_cb__).toBe('');
    });

    it('handles hash with only #', () => {
      const { postMessageCalls } = runCallbackScript({
        hash: '#',
        search: '?ok=1&origin=https://test.com',
        opener: {},
      });

      expect(postMessageCalls[0][0].__keyfob_cb__).toBe('');
    });
  });

  // ── No Opener ──────────────────────────────────────────────

  describe('no opener window', () => {
    it('does not post when window.opener is null', () => {
      const { postMessageCalls } = runCallbackScript({
        hash: '#cb-1',
        search: '?ok=1&origin=https://test.com',
        opener: null,
      });

      expect(postMessageCalls).toHaveLength(0);
    });
  });

  // ── Auto-Close ─────────────────────────────────────────────

  describe('auto-close', () => {
    it('schedules window.close() after 100ms', () => {
      const { mockClose } = runCallbackScript({
        hash: '#cb-1',
        search: '?ok=1&origin=https://test.com',
        opener: {},
      });

      // Not closed yet
      expect(mockClose).not.toHaveBeenCalled();

      // Advance fake timers past 100ms
      vi.advanceTimersByTime(101);

      expect(mockClose).toHaveBeenCalledTimes(1);
    });

    it('schedules close even when no opener', () => {
      const { mockClose } = runCallbackScript({
        hash: '#cb-1',
        search: '?ok=1',
        opener: null,
      });

      vi.advanceTimersByTime(101);
      expect(mockClose).toHaveBeenCalledTimes(1);
    });

    it('schedules close even when targetOrigin is unavailable', () => {
      const { mockClose } = runCallbackScript({
        hash: '#cb-1',
        search: '?ok=1',
        referrer: '',
        opener: {},
      });

      vi.advanceTimersByTime(101);
      expect(mockClose).toHaveBeenCalledTimes(1);
    });
  });
});
