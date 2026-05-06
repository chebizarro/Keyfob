# Security Model

- Keys stored only in Keychain (optionally iCloud). Access Group configured via `KEYFOB_KEYCHAIN_ACCESS_GROUP` (see `Build/Keyfob.xcconfig`).
- App Group for small shared state configured via `KEYFOB_APP_GROUP`.
- Every signature requires visible consent unless a session (Mode B) is active and within timeout.
- If no `consentProvider` is set, signing requests are rejected (never silently approved).
- Biometrics via LocalAuthentication required per approval or at session start.
- Strict JSON schema; deterministic canonical JSON; stable field order; normalized unicode (RFC 8259 compliant escaping).
- Payload caps; reject ambiguous/extra fields.
- Encrypted export uses AES-256-GCM with HKDF-SHA256 key derivation from password.
- macOS uses XPC only; no localhost sockets.
- All mutable PolicyEngine state is synchronized via serial dispatch queue.

## Configuration

All identifiers are centralized in `Build/Keyfob.xcconfig`. Copy to `Build/Keyfob.local.xcconfig` with real values for production builds. The `.local` file is gitignored.

Runtime code reads configuration from Info.plist keys injected by the xcconfig:
- `KEYFOB_KEYCHAIN_ACCESS_GROUP` — Keychain access group
- `KEYFOB_APP_GROUP` — App Group container identifier
- `KEYFOB_UL_HOST` — Universal Link host domain
- `KEYFOB_XPC_SERVICE_NAME` — XPC service bundle identifier
