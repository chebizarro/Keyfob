(function () {
  if (window.nostr) return;

  const pending = new Map();
  const TIMEOUT_MS = 120000; // 2 minutes — allows time for user consent in native app

  function uuid() {
    return ([1e7]+-1e3+-4e3+-8e3+-1e11).replace(/[018]/g, c =>
      (c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16)
    );
  }

  // Receive responses from native
  safari.self.addEventListener("message", (event) => {
    if (event.name !== "keyfob_response") return;
    const data = event.message || {};
    const reqId = data.reqId || "";
    const wait = pending.get(reqId);
    if (!wait) return;
    clearTimeout(wait.timer);
    pending.delete(reqId);
    if (String(data.ok) === "1") {
      wait.resolve(data);
    } else {
      const err = new Error(data.msg || "Keyfob error");
      err.code = data.code || "error";
      wait.reject(err);
    }
  }, false);

  function sendAndWait(messageName, payload) {
    const reqId = uuid();
    const promise = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(reqId);
        reject(new Error("Keyfob: no response from signer (timeout)"));
      }, TIMEOUT_MS);
      pending.set(reqId, { resolve, reject, timer });
    });
    safari.extension.dispatchMessage(messageName, { ...payload, reqId });
    return promise;
  }

  async function getPublicKey() {
    const resp = await sendAndWait("keyfob_getPublicKey", {});
    return resp.pubkey;
  }

  async function signEvent(event) {
    // NIP-01 expects signature returned and event augmented by signer. We return signature fields.
    const eventJSON = JSON.stringify(event);
    const resp = await sendAndWait("keyfob_signEvent", { eventJSON });
    // Return augmented event if desired; here we return the NIP-07 style object
    return { id: resp.id, sig: resp.sig, pubkey: resp.pubkey };
  }

  Object.defineProperty(window, "nostr", {
    value: {
      getPublicKey,
      signEvent
    },
    configurable: false,
  });
})();
