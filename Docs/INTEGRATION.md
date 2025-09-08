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
- `https://keyfob.example.com/app/sign?...` (replace domain)
- Same parameters as URL scheme.

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
