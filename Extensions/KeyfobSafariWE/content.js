(function(){
  if (window.nostr) return;

  const UL_BASE = 'https://keyfob.example.com/app'; // TODO: replace with your domain
  const ORIGIN = window.location.origin;
  const CB_ID = 'keyfob-cb-' + Math.random().toString(36).slice(2);

  function onceMessage(expectedId, timeoutMs = 60000) {
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

  async function handoff(path, params) {
    const cb = `${ORIGIN}/#${CB_ID}`;
    const q = new URLSearchParams({...params, cb, origin: ORIGIN});
    const url = `${UL_BASE}/${path}?${q.toString()}`;
    // Open in a new window/tab to allow user to confirm
    window.open(url, '_blank', 'noopener');
    const result = await onceMessage(CB_ID, 60000);
    if (!result || !result.ok) throw new Error(result?.msg || 'Keyfob error');
    return result;
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
