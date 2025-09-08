# Integration Guide

This document describes the IPC contracts and how to integrate with keyfob.

## App Intent (iOS)
- Intent: `SignNostrEvent`
- Input: `eventJSON: String`
- Output: `{ id: String, sig: String, pubkey: String }`
- Flow: validate → normalize → compute id → consent → sign → return

## Custom URL Scheme
- Scheme: `keyfob://sign?payload=<base64url-json>&cb=<url-encoded-callback>&origin=<domain-or-bundle>`
- Success callback: `cb://done?ok=1&id=<hex>&sig=<hex>&pubkey=<hex>`
- Error callback: `cb://done?ok=0&code=<str>&msg=<str>`

## Universal Link
- `https://keyfob.example.com/app/sign?payload=<base64url-json>&cb=<url-encoded-callback>&origin=<domain-or-bundle>`
- `https://keyfob.example.com/app/pubkey?cb=<url-encoded-callback>&origin=<domain-or-bundle>`
- Payload is Base64URL-encoded compact NIP-01 event object (fields: `kind, pubkey(optional), created_at, tags, content`).
- Callback is an absolute URL. Recommended for web flows: an HTML page that posts a message to `window.opener` with the query parameters.
- The native app resolves ULs through `BridgeHandler.handleUniversalLink(_:)` and opens the callback URL with appended query parameters:
  - On success: `?ok=1&id=<hex>&sig=<hex>&pubkey=<hex>`
  - On error: `?ok=0&code=<str>&msg=<str>`

## macOS XPC
```
protocol KeyfobXPCProtocol {
  func sign(eventJSON: Data, clientBundleID: String, originHint: String?, reply: @escaping (Result<SignatureResponse, XPCError>) -> Void)
}
```
- Caller bundle ID validated against allowlist.
- Consent required in menubar app.

## NIP-07 mapping (Safari extensions)
- `window.nostr.getPublicKey()` → Promise<string>
- `window.nostr.signEvent(event)` → Promise<event>
- Sign is bridged to native (Universal Link on iOS; XPC on macOS).

The iOS Safari Web Extension `content.js` included in `Extensions/KeyfobSafariWE/` implements the above using Universal Links and expects the callback page to echo results back via `window.postMessage`. See `Web/demo/callback.html` for a reference implementation.
