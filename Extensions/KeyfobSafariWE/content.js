(function(){
  if (window.nostr) return;

  // Universal Link base URL. Override at build time by replacing this value
  // or set via safari.extension.baseURI configuration.
  // Must match the domain in your apple-app-site-association file.
  // See Build/Keyfob.xcconfig KEYFOB_UL_HOST for the canonical value.
  const UL_HOST = '__KEYFOB_UL_HOST__'; // replaced by build script; fallback below
  const UL_BASE = UL_HOST.startsWith('__') ? 'https://keyfob.example.com/app' : `https://${UL_HOST}/app`;
  const ORIGIN = window.location.origin;
  const CB_ID = 'keyfob-cb-' + Math.random().toString(36).slice(2);

  // Configuration
  const DEFAULT_TIMEOUT_MS = 120000; // 2 minutes
  const MAX_RETRIES = 2;            // Up to 2 retries (3 total attempts)
  const RETRY_BACKOFF_MS = 3000;    // 3s, 6s backoff between retries

  // ── Status Indicator ──────────────────────────────────────────

  let statusEl = null;

  function showStatus(message) {
    removeStatus();
    statusEl = document.createElement('div');
    statusEl.id = 'keyfob-status';
    statusEl.textContent = message;
    Object.assign(statusEl.style, {
      position: 'fixed',
      bottom: '20px',
      right: '20px',
      padding: '12px 20px',
      background: 'rgba(0,0,0,0.85)',
      color: '#fff',
      borderRadius: '8px',
      fontSize: '14px',
      fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
      zIndex: '2147483647',
      boxShadow: '0 4px 12px rgba(0,0,0,0.3)',
      transition: 'opacity 0.3s',
      opacity: '1'
    });
    document.body.appendChild(statusEl);
  }

  function updateStatus(message) {
    if (statusEl) statusEl.textContent = message;
  }

  function removeStatus() {
    if (statusEl) {
      statusEl.remove();
      statusEl = null;
    }
  }

  // ── Message Listener ──────────────────────────────────────────

  function onceMessage(expectedId, timeoutMs = DEFAULT_TIMEOUT_MS) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        window.removeEventListener('message', onMsg);
        reject(new Error('Keyfob timeout'));
      }, timeoutMs);
      function onMsg(ev) {
        try {
          const data = ev.data;
          if (!data || data.__keyfob_cb__ !== expectedId) return;
          clearTimeout(timer);
          window.removeEventListener('message', onMsg);
          resolve(data.payload);
        } catch (e) {
          // ignore
        }
      }
      window.addEventListener('message', onMsg);
    });
  }

  // ── Handoff with Retry ────────────────────────────────────────

  async function handoff(path, params) {
    const cb = `${ORIGIN}/callback.html#${CB_ID}`;
    const q = new URLSearchParams({...params, cb, origin: ORIGIN});
    const url = `${UL_BASE}/${path}?${q.toString()}`;

    let lastError = null;

    for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
      if (attempt === 0) {
        showStatus('⏳ Waiting for Keyfob approval\u2026');
      } else {
        const delay = RETRY_BACKOFF_MS * attempt;
        updateStatus(`⏳ Retrying (${attempt}/${MAX_RETRIES})\u2026`);
        await new Promise(r => setTimeout(r, delay));
      }

      // Open Universal Link
      window.open(url, '_blank', 'noopener');

      try {
        const result = await onceMessage(CB_ID, DEFAULT_TIMEOUT_MS);
        removeStatus();
        if (!result || !result.ok) throw new Error(result?.msg || 'Keyfob error');
        return result;
      } catch (e) {
        lastError = e;
        if (attempt < MAX_RETRIES) {
          updateStatus('⚠️ Keyfob did not respond. Retrying\u2026');
        }
      }
    }

    removeStatus();
    throw lastError || new Error('Keyfob timeout after retries');
  }

  window.nostr = {
    // NIP-07
    getPublicKey: async () => {
      const res = await handoff('pubkey', {});
      return res.pubkey; // hex
    },
    signEvent: async (evt) => {
      // Enforce minimal schema per NIP-01
      const payload = {
        kind: evt.kind|0,
        pubkey: '',
        created_at: evt.created_at|0,
        tags: Array.isArray(evt.tags) ? evt.tags : [],
        content: typeof evt.content === 'string' ? evt.content : ''
      };
      const json = JSON.stringify(payload);
      const b64u = btoa(unescape(encodeURIComponent(json))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
      const res = await handoff('sign', { payload: b64u });
      // Return full event with id/sig/pubkey
      return {
        ...payload,
        id: res.id,
        sig: res.sig,
        pubkey: res.pubkey
      };
    }
  };
})();
