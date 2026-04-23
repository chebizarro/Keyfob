# keyfob

A local Nostr signer for iOS 15+ and macOS 12+, written in Swift 5.7 with Swift Package Manager. Security-first, least privilege, App Store–compliant IPC only.

Modules (SPM):
- `KeyfobCrypto`: thin wrappers over `nostr-sdk-ios` for key management and signing.
- `KeyfobCore`: event model, canonical JSON normalization, id computation, NIP-07/55 orchestration.
- `KeyfobPolicy`: origin registry, session policies, rate limits, audit log.
- `KeyfobBridge`: App Intent, URL/Universal Link router, shared DTOs.
- `KeyfobUI`: SwiftUI consent sheets and key management UI.
- `KeyfobWebShared`: shared JS/TS for web extension ↔ native message contract.

Apps & Extensions (placeholders included):
- iOS app `Keyfob-iOS` + Action Extension + Safari Web Extension
- macOS menubar app `Keyfob-macOS` + XPC helper + Safari App Extension
- Demo iOS Host App
- Demo Web site in `Web/demo/`

## Setup

All identifiers are centralized in `Build/Keyfob.xcconfig`:

1. Copy `Build/Keyfob.xcconfig` to `Build/Keyfob.local.xcconfig`
2. Fill in your real values:
   - `DEVELOPMENT_TEAM` — your Apple Team ID
   - `KEYFOB_BUNDLE_ID_BASE` — your bundle identifier base (e.g. `com.yourcompany.keyfob`)
   - `KEYFOB_UL_HOST` — your Universal Link domain
3. All derived identifiers (bundle IDs, access groups, XPC names) are computed automatically
4. The `.local` file is gitignored so credentials stay out of version control

Runtime code reads configuration from Info.plist keys injected by the xcconfig. See `Build/Keyfob.xcconfig` for the full list.

See `Docs/SECURITY.md`, `Docs/POLICY.md`, and `Docs/INTEGRATION.md` for details.

## Roadmap

- **NIP-46 (Nostr Connect)**: Remote signer support via relay, allowing desktop/web apps to request signing from Keyfob over a relay connection. Planned — requires a new `KeyfobRelay` module with WebSocket client, NIP-42 AUTH, EOSE-aware subscriptions, and kind 24133 request/response handling.
