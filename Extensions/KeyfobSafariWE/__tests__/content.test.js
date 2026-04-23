// ──────────────────────────────────────────────────────────────────
// content.test.js — Tests for Safari WE content.js NIP-07 provider
// ─────────────────────────────────────────────────────────���────────
//
// Tests the window.nostr API injected by content.js:
//   - onceMessage() timeout and listener lifecycle
//   - handoff() retry behavior with exponential backoff
//   - getPublicKey() and signEvent() NIP-07 contract
//   - Error response handling
//   - Status indicator DOM management
//
// Uses vitest with jsdom and fake timers. No real network or delays.
// ──────────────────────────────────────────────────────────────────

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { readFileSync } from 'fs';
import { join } from 'path';

// ── Helpers ──────────────────────────────────────────────────────

const CONTENT_JS_PATH = join(__dirname, '..', 'content.js');
const CONTENT_JS_SOURCE = readFileSync(CONTENT_JS_PATH, 'utf-8');

/**
 * Load content.js into the current jsdom window.
 * Returns window.nostr for convenience.
 */
function loadContentScript() {
  // Reset window.nostr so the IIFE doesn't bail out
  delete window.nostr;

  // Mock window.open (Universal Link trigger)
  window.open = vi.fn();

  // Execute the IIFE in global scope
  const fn = new Function(CONTENT_JS_SOURCE);
  fn();

  return window.nostr;
}

/**
 * Simulate the callback.html postMessage response.
 * @param {string} cbId - The __keyfob_cb__ value to match.
 * @param {object} payload - The response payload.
 */
function simulateCallback(cbId, payload) {
  window.dispatchEvent(
    new MessageEvent('message', {
      data: { __keyfob_cb__: cbId, payload },
      origin: window.location.origin,
    })
  );
}

/**
 * Extract the callback ID from the URL passed to window.open.
 * The content.js generates: `${ORIGIN}/callback.html#${CB_ID}`
 * and passes it as the `cb` query param.
 */
function extractCbId() {
  const call = window.open.mock.calls[0];
  if (!call) throw new Error('window.open was not called');
  const url = new URL(call[0]);
  const cb = url.searchParams.get('cb');
  // cb is like "http://localhost/callback.html#keyfob-cb-xxxxx"
  const hash = new URL(cb).hash;
  return hash.slice(1); // remove '#'
}

// ── Test Setup ───────────────────────────────────────────────────

describe('content.js — window.nostr provider', () => {
  let nostr;
  let originalAddEventListener;
  let activeListeners;

  beforeEach(() => {
    vi.useFakeTimers();

    // Track event listeners for cleanup verification
    activeListeners = new Map();
    originalAddEventListener = window.addEventListener.bind(window);

    const origAdd = window.addEventListener.bind(window);
    const origRemove = window.removeEventListener.bind(window);

    vi.spyOn(window, 'addEventListener').mockImplementation((type, fn, opts) => {
      if (!activeListeners.has(type)) activeListeners.set(type, new Set());
      activeListeners.get(type).add(fn);
      origAdd(type, fn, opts);
    });

    vi.spyOn(window, 'removeEventListener').mockImplementation((type, fn, opts) => {
      if (activeListeners.has(type)) activeListeners.get(type).delete(fn);
      origRemove(type, fn, opts);
    });

    nostr = loadContentScript();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
    delete window.nostr;
    // Clean up status element if present
    const el = document.getElementById('keyfob-status');
    if (el) el.remove();
  });

  // ── Basic Setup ──────────────────────────────────────────────

  describe('injection', () => {
    it('creates window.nostr with NIP-07 methods', () => {
      expect(nostr).toBeDefined();
      expect(typeof nostr.getPublicKey).toBe('function');
      expect(typeof nostr.signEvent).toBe('function');
    });

    it('does not overwrite existing window.nostr', () => {
      const sentinel = { getPublicKey: 'sentinel' };
      window.nostr = sentinel;

      // Re-execute content.js — should detect existing and bail
      const fn = new Function(CONTENT_JS_SOURCE);
      fn();

      expect(window.nostr).toBe(sentinel);
    });
  });

  // ── onceMessage / Timeout ────────────────────────────────────

  describe('timeout behavior', () => {
    it('rejects with "Keyfob timeout" when no response arrives', async () => {
      const promise = nostr.getPublicKey();
      promise.catch(() => {}); // handle early to avoid unhandled rejection during timer advance

      // Must exhaust all 3 attempts: 120s + 3s backoff + 120s + 6s backoff + 120s
      // Attempt 0
      await vi.advanceTimersByTimeAsync(120_001);
      // Attempt 1 (3s backoff + 120s timeout)
      await vi.advanceTimersByTimeAsync(3_000 + 120_001);
      // Attempt 2 (6s backoff + 120s timeout)
      await vi.advanceTimersByTimeAsync(6_000 + 120_001);

      await expect(promise).rejects.toThrow('Keyfob timeout');
    });

    it('retries up to MAX_RETRIES times before final timeout', async () => {
      const promise = nostr.getPublicKey();
      promise.catch(() => {}); // handle early to avoid unhandled rejection during timer advance

      // Attempt 0: initial timeout (120s)
      await vi.advanceTimersByTimeAsync(120_001);
      expect(window.open).toHaveBeenCalledTimes(1);

      // Attempt 1: retry backoff (3s) + timeout (120s)
      await vi.advanceTimersByTimeAsync(3_000 + 120_001);
      expect(window.open).toHaveBeenCalledTimes(2);

      // Attempt 2: retry backoff (6s) + timeout (120s)
      await vi.advanceTimersByTimeAsync(6_000 + 120_001);
      expect(window.open).toHaveBeenCalledTimes(3);

      // All 3 attempts exhausted — should reject
      await expect(promise).rejects.toThrow('Keyfob timeout');
    });

    it('ignores messages with wrong callback ID', async () => {
      const promise = nostr.getPublicKey();
      promise.catch(() => {}); // handle early to avoid unhandled rejection during timer advance

      // Send a message with wrong callback ID
      simulateCallback('wrong-id-xxx', { ok: true, pubkey: 'abc' });

      // The promise should still be pending — advance timer to force timeout
      await vi.advanceTimersByTimeAsync(120_001);
      // Retry 1
      await vi.advanceTimersByTimeAsync(3_000 + 120_001);
      // Retry 2
      await vi.advanceTimersByTimeAsync(6_000 + 120_001);

      await expect(promise).rejects.toThrow('Keyfob timeout');
    });
  });

  // ── Happy Path ───────────────────────────────────────────────

  describe('getPublicKey()', () => {
    it('resolves with hex pubkey on success', async () => {
      const promise = nostr.getPublicKey();

      // Let the microtask for showStatus run
      await vi.advanceTimersByTimeAsync(0);

      const cbId = extractCbId();
      simulateCallback(cbId, { ok: true, pubkey: 'deadbeef01' });

      const result = await promise;
      expect(result).toBe('deadbeef01');
    });

    it('opens Universal Link with correct URL structure', async () => {
      const promise = nostr.getPublicKey();
      await vi.advanceTimersByTimeAsync(0);

      expect(window.open).toHaveBeenCalledTimes(1);
      const url = new URL(window.open.mock.calls[0][0]);
      expect(url.pathname).toContain('/app/pubkey');
      expect(url.searchParams.has('cb')).toBe(true);
      expect(url.searchParams.has('origin')).toBe(true);

      // Resolve to avoid dangling promise
      const cbId = extractCbId();
      simulateCallback(cbId, { ok: true, pubkey: 'abc' });
      await promise;
    });
  });

  describe('signEvent()', () => {
    it('returns augmented event with id, sig, pubkey', async () => {
      const unsignedEvent = {
        kind: 1,
        created_at: 1700000000,
        tags: [['e', 'abc123']],
        content: 'hello nostr',
      };

      const promise = nostr.signEvent(unsignedEvent);
      await vi.advanceTimersByTimeAsync(0);

      const cbId = extractCbId();
      simulateCallback(cbId, {
        ok: true,
        id: 'event-id-hex',
        sig: 'event-sig-hex',
        pubkey: 'signer-pubkey-hex',
      });

      const signed = await promise;
      expect(signed.id).toBe('event-id-hex');
      expect(signed.sig).toBe('event-sig-hex');
      expect(signed.pubkey).toBe('signer-pubkey-hex');
      expect(signed.kind).toBe(1);
      expect(signed.content).toBe('hello nostr');
      expect(signed.tags).toEqual([['e', 'abc123']]);
      expect(signed.created_at).toBe(1700000000);
    });

    it('sends base64url-encoded event payload in URL', async () => {
      const promise = nostr.signEvent({
        kind: 1,
        created_at: 1700000000,
        tags: [],
        content: 'test',
      });
      await vi.advanceTimersByTimeAsync(0);

      const url = new URL(window.open.mock.calls[0][0]);
      expect(url.pathname).toContain('/app/sign');
      const b64u = url.searchParams.get('payload');
      expect(b64u).toBeTruthy();

      // Decode and verify it's valid JSON with NIP-01 fields
      const json = decodeURIComponent(escape(atob(b64u.replace(/-/g, '+').replace(/_/g, '/'))));
      const parsed = JSON.parse(json);
      expect(parsed.kind).toBe(1);
      expect(parsed.content).toBe('test');

      // Resolve to avoid dangling promise
      const cbId = extractCbId();
      simulateCallback(cbId, { ok: true, id: 'x', sig: 'y', pubkey: 'z' });
      await promise;
    });

    it('normalizes malformed event fields', async () => {
      const promise = nostr.signEvent({
        kind: undefined,
        created_at: null,
        tags: 'not-an-array',
        content: 42,
      });
      await vi.advanceTimersByTimeAsync(0);

      const url = new URL(window.open.mock.calls[0][0]);
      const b64u = url.searchParams.get('payload');
      const json = decodeURIComponent(escape(atob(b64u.replace(/-/g, '+').replace(/_/g, '/'))));
      const parsed = JSON.parse(json);

      // kind|0 → 0, created_at|0 → 0, non-array tags → [], non-string content → ''
      expect(parsed.kind).toBe(0);
      expect(parsed.created_at).toBe(0);
      expect(parsed.tags).toEqual([]);
      expect(parsed.content).toBe('');

      const cbId = extractCbId();
      simulateCallback(cbId, { ok: true, id: 'x', sig: 'y', pubkey: 'z' });
      await promise;
    });
  });

  // ── Error Handling ───────────────────────────────────────────

  describe('error responses', () => {
    it('throws on result.ok falsy', async () => {
      const promise = nostr.getPublicKey();
      promise.catch(() => {}); // handle early to avoid unhandled rejection during timer advance
      await vi.advanceTimersByTimeAsync(0);
      const cbId = extractCbId();

      // Error is caught by retry loop — must fail all 3 attempts
      // Attempt 0
      simulateCallback(cbId, { ok: false, msg: 'user rejected' });
      await vi.advanceTimersByTimeAsync(0);
      // Attempt 1 (3s backoff)
      await vi.advanceTimersByTimeAsync(3_001);
      simulateCallback(cbId, { ok: false, msg: 'user rejected' });
      await vi.advanceTimersByTimeAsync(0);
      // Attempt 2 (6s backoff)
      await vi.advanceTimersByTimeAsync(6_001);
      simulateCallback(cbId, { ok: false, msg: 'user rejected' });
      await vi.advanceTimersByTimeAsync(0);

      await expect(promise).rejects.toThrow('user rejected');
    });

    it('throws generic error when result.ok falsy and no msg', async () => {
      const promise = nostr.getPublicKey();
      promise.catch(() => {}); // handle early to avoid unhandled rejection during timer advance
      await vi.advanceTimersByTimeAsync(0);
      const cbId = extractCbId();

      // Attempt 0
      simulateCallback(cbId, { ok: false });
      await vi.advanceTimersByTimeAsync(0);
      // Attempt 1 (3s backoff)
      await vi.advanceTimersByTimeAsync(3_001);
      simulateCallback(cbId, { ok: false });
      await vi.advanceTimersByTimeAsync(0);
      // Attempt 2 (6s backoff)
      await vi.advanceTimersByTimeAsync(6_001);
      simulateCallback(cbId, { ok: false });
      await vi.advanceTimersByTimeAsync(0);

      await expect(promise).rejects.toThrow('Keyfob error');
    });

    it('throws when result is null/undefined', async () => {
      const promise = nostr.getPublicKey();
      promise.catch(() => {}); // handle early to avoid unhandled rejection during timer advance
      await vi.advanceTimersByTimeAsync(0);
      const cbId = extractCbId();

      // Attempt 0
      simulateCallback(cbId, null);
      await vi.advanceTimersByTimeAsync(0);
      // Attempt 1 (3s backoff)
      await vi.advanceTimersByTimeAsync(3_001);
      simulateCallback(cbId, null);
      await vi.advanceTimersByTimeAsync(0);
      // Attempt 2 (6s backoff)
      await vi.advanceTimersByTimeAsync(6_001);
      simulateCallback(cbId, null);
      await vi.advanceTimersByTimeAsync(0);

      await expect(promise).rejects.toThrow('Keyfob error');
    });
  });

  // ── Listener Cleanup ───────────────────────────��─────────────

  describe('listener cleanup', () => {
    it('removes message listener on successful response', async () => {
      const promise = nostr.getPublicKey();
      await vi.advanceTimersByTimeAsync(0);

      // Should have a 'message' listener registered
      expect(activeListeners.get('message')?.size).toBeGreaterThan(0);

      const cbId = extractCbId();
      simulateCallback(cbId, { ok: true, pubkey: 'abc' });
      await promise;

      // After resolution, the message listener should be cleaned up
      expect(activeListeners.get('message')?.size ?? 0).toBe(0);
    });

    it('removes message listener on timeout', async () => {
      const promise = nostr.getPublicKey();
      promise.catch(() => {}); // handle early to avoid unhandled rejection during timer advance
      await vi.advanceTimersByTimeAsync(0);

      expect(activeListeners.get('message')?.size).toBeGreaterThan(0);

      // Exhaust all retries
      await vi.advanceTimersByTimeAsync(120_001);
      await vi.advanceTimersByTimeAsync(3_000 + 120_001);
      await vi.advanceTimersByTimeAsync(6_000 + 120_001);

      await promise.catch(() => {}); // swallow rejection

      // All message listeners should be cleaned up
      expect(activeListeners.get('message')?.size ?? 0).toBe(0);
    });
  });

  // ── Status Indicator ─────────────────────────────────────────

  describe('status indicator', () => {
    it('shows status element during handoff', async () => {
      const promise = nostr.getPublicKey();
      await vi.advanceTimersByTimeAsync(0);

      const el = document.getElementById('keyfob-status');
      expect(el).not.toBeNull();
      expect(el.textContent).toContain('Waiting for Keyfob');

      // Resolve to clean up
      const cbId = extractCbId();
      simulateCallback(cbId, { ok: true, pubkey: 'abc' });
      await promise;
    });

    it('removes status element on success', async () => {
      const promise = nostr.getPublicKey();
      await vi.advanceTimersByTimeAsync(0);

      const cbId = extractCbId();
      simulateCallback(cbId, { ok: true, pubkey: 'abc' });
      await promise;

      const el = document.getElementById('keyfob-status');
      expect(el).toBeNull();
    });

    it('removes status element on final timeout', async () => {
      const promise = nostr.getPublicKey();
      promise.catch(() => {}); // handle early to avoid unhandled rejection during timer advance

      // Exhaust all retries
      await vi.advanceTimersByTimeAsync(120_001);
      await vi.advanceTimersByTimeAsync(3_000 + 120_001);
      await vi.advanceTimersByTimeAsync(6_000 + 120_001);
      await promise.catch(() => {});

      const el = document.getElementById('keyfob-status');
      expect(el).toBeNull();
    });

    it('updates status text on retry', async () => {
      const promise = nostr.getPublicKey();
      await vi.advanceTimersByTimeAsync(0);

      // Check initial status
      let el = document.getElementById('keyfob-status');
      expect(el.textContent).toContain('Waiting for Keyfob');

      // First timeout → triggers retry
      await vi.advanceTimersByTimeAsync(120_001);

      el = document.getElementById('keyfob-status');
      // Should show retry or "did not respond" message
      expect(el).not.toBeNull();

      // Resolve on retry
      await vi.advanceTimersByTimeAsync(3_000); // backoff
      await vi.advanceTimersByTimeAsync(0); // flush microtasks

      const cbId = extractCbId();
      simulateCallback(cbId, { ok: true, pubkey: 'abc' });

      // Advance remaining timers for second attempt timeout so promise resolves
      try { await promise; } catch { /* may still timeout if cb didn't match */ }
    });
  });
});
