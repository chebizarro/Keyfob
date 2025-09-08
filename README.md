# keyfob

A local Nostr signer for iOS 15+ and macOS 12+, written in Swift 5.7 with Swift Package Manager. Security-first, least privilege, App Store–compliant IPC only.

Modules (SPM):
- `KeyfobCrypto`: thin wrappers over `nostr-sdk-ios` for key management and signing.
- `KeyfobCore`: event model, canonical JSON normalization, id computation, NIP-07/55/46 orchestration.
- `KeyfobPolicy`: origin registry, session policies, rate limits, audit log.
- `KeyfobBridge`: App Intent, URL/Universal Link router, shared DTOs.
- `KeyfobUI`: SwiftUI consent sheets and key management UI.
- `KeyfobWebShared`: shared JS/TS for web extension ↔ native message contract.

Apps & Extensions (placeholders included):
- iOS app `Keyfob-iOS` + Action Extension + Safari Web Extension
- macOS menubar app `Keyfob-macOS` + XPC helper + Safari App Extension
- Demo iOS Host App
- Demo Web site in `Web/demo/`

Important placeholders to update:
- Team ID: `TODO_TEAMID`
- Bundle IDs: `TODO.com.yourorg.keyfob` etc.
- Associated domains: `applinks:keyfob.example.com`

See `Docs/SECURITY.md`, `Docs/POLICY.md`, and `Docs/INTEGRATION.md` for details.
