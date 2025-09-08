# Quick Start

This section helps you exercise each IPC surface quickly. Fill placeholders as noted (Team ID, bundle IDs, associated domains).

- URL Scheme (iOS)
  1. Build and run `Keyfob-iOS` to generate/load a key.
  2. From another app (or `KeyfobHostDemo`), open:
     - `keyfob://sign?payload=<base64url-json>&cb=<url-encoded-callback>&origin=<domain-or-bundle>`
  3. On success, callback receives: `?ok=1&id=<hex>&sig=<hex>&pubkey=<hex>`.

- Universal Links (iOS/macOS)
  1. Configure Associated Domains for `applinks:keyfob.example.com`.
  2. Host a callback page similar to `Web/demo/callback.html` on your domain.
  3. Open:
     - Sign: `https://keyfob.example.com/app/sign?payload=<b64url>&cb=<callback_url>&origin=<origin>`
     - Get pubkey: `https://keyfob.example.com/app/pubkey?cb=<callback_url>&origin=<origin>`
  4. `BridgeHandler.handleUniversalLink(_:)` will return the callback URL; the app opens it for you.

- App Intent (iOS 16+/macOS 13+)
  - Shortcuts path
    1. In Shortcuts, create a Shortcut named “Sign Nostr Event”.
    2. Add Keyfob’s `SignNostrEvent` action; set Event JSON to “Provided Input”.
    3. From a host app (e.g., `KeyfobHostDemo`), open:
       - `shortcuts://run-shortcut?name=Sign%20Nostr%20Event&input=text&text=<eventJSON>`
  - Direct invocation (iOS 16+)
    1. Link `AppIntents` and import `KeyfobBridge`.
    2. Invoke:
       ```swift
       var intent = SignNostrEvent()
       intent.eventJSON = json
       let result = try await intent.perform()
       // Returns a JSON string {id,sig,pubkey}
       ```

- Safari Web Extension (iOS/macOS)
  1. iOS: build & install `KeyfobSafariWEApp` and enable the extension in Settings → Safari → Extensions.
  2. macOS: build & enable the Safari App Extension.
  3. The extension injects `window.nostr` (NIP-07 subset):
     - `getPublicKey(): Promise<string>`
     - `signEvent(event): Promise<event>`
  4. iOS bridge uses Universal Links to hand off; macOS uses XPC.

---

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
