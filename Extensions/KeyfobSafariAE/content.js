(function () {
  if (window.nostr) return;

  const pending = new Map();

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
    pending.delete(reqId);
    if (String(data.ok) === "1") {
      wait.resolve(data);
    } else {
      const err = new Error(data.msg || "Keyfob error");
      err.code = data.code || "error";
      wait.reject(err);
    }
  }, false);

  async function getPublicKey() {
    const reqId = uuid();
    const promise = new Promise((resolve, reject) => pending.set(reqId, { resolve, reject }));
    safari.extension.dispatchMessage("keyfob_getPublicKey", { reqId });
    const resp = await promise;
    return resp.pubkey;
  }

  async function signEvent(event) {
    // NIP-01 expects signature returned and event augmented by signer. We return signature fields.
    const reqId = uuid();
    const eventJSON = JSON.stringify(event);
    const promise = new Promise((resolve, reject) => pending.set(reqId, { resolve, reject }));
    safari.extension.dispatchMessage("keyfob_signEvent", { reqId, eventJSON });
    const resp = await promise;
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
