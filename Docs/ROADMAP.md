# Keyfob Product Roadmap

> From protocol infrastructure to full-featured Nostr signing app for Apple platforms.

## Vision

Keyfob becomes the preferred Nostr signer for macOS and iOS — security-first, minimal friction, protocol-complete. Users install it once, onboard in under a minute, and forget it's there until they need to approve something unusual.

## Design Principles

1. **Security-first**: Keys never leave Keychain/XPC. Biometrics gate sensitive operations. Consent is always visible.
2. **Minimal friction**: Smart defaults, session-based approval, auto-approve safe operations. A "basic" policy mode handles most users.
3. **Protocol completeness**: Support the NIPs that real Nostr apps actually use (NIP-01, 04, 06, 07, 19, 42, 44, 46, 49, 55-equivalent).
4. **Apple-native**: SwiftUI, platform conventions, App Store compliant. No localhost sockets, no background daemons.
5. **Modular**: KeyfobRelay stays zero-dependency. Integration layers compose above it.

---

## Current State (What Works)

| Area | Status | Details |
|------|--------|---------|
| NIP-01 signing | ✅ Done | Canonical JSON, id computation, schnorr signatures |
| NIP-07 browser | ✅ Done | `window.nostr` via Safari Web Extension (iOS) and Safari App Extension (macOS) |
| NIP-42 relay AUTH | ✅ Done | Auto-signing challenge/response in RelayConnection |
| NIP-46 transport | ✅ Done | NIP46Handler with kind 24133 routing — but not wired to crypto |
| Policy engine | ✅ Done | Origin allowlist, timed sessions, token-bucket rate limits, JSONL audit log |
| IPC surfaces | ✅ Done | URL scheme, Universal Links, App Intent, XPC protocol |
| Relay infrastructure | ✅ Done | WebSocket client, reconnect backoff, RelayPool, SubscriptionManager, telemetry |
| Test suite | ✅ Done | 387 tests passing across all modules |

---

## Gap Analysis

### Protocol Gaps
- **NIP-04**: Deprecated DM encryption (still needed for compatibility)
- **NIP-06**: BIP39 mnemonic key derivation (import/backup)
- **NIP-19**: Bech32 display (npub/nsec/nprofile/nevent)
- **NIP-44**: Modern encrypted payloads (REQUIRED for NIP-46)
- **NIP-49**: ncryptsec private key encryption (standard backup format)
- **NIP-46**: Handler exists but needs crypto integration layer

### Product Gaps
- No onboarding flow (create/import key)
- Single-key only (no multi-identity support)
- No per-app permission management
- No signing policy presets (auto-approve vs manual)
- No signing history UI
- No `nostrsigner://` URL scheme (Apple NIP-55 equivalent)
- No bunker:// / nostrconnect:// pairing support
- No QR code scanning for bunker URLs
- No relay management UI
- No profile display

### Architecture Gap
- KeyfobRelay is zero-dependency by design — needs an integration module to wire NIP-46 to crypto/policy

---

## Phase 1 — Identity Foundation & First-Run Experience

**Priority**: P0 (blocks everything)
**Goal**: A user can install Keyfob, create or import a key, and start signing.

### Architecture: Multi-Key Identity Model

```
IdentityMetadata (persisted in App Group)
├── id: UUID
├── keyAlias: String
├── publicKeyHex: String
├── displayName: String?
├── source: generated | importedHex | importedNsec | importedMnemonic
├── createdAt: Date
├── lastUsedAt: Date?
└── isActive: Bool

Secrets remain in Keychain (unchanged)
```

### Tasks

| # | Task | Modules | Effort | Depends On |
|---|------|---------|--------|------------|
| 1.1 | Multi-key identity metadata store | KeyfobCrypto | L | — |
| 1.2 | Identity-addressable crypto APIs | KeyfobCrypto, KeyfobCore, KeyfobBridge | L | 1.1 |
| 1.3 | NIP-19 bech32 support (npub/nsec display & input) | KeyfobCrypto or KeyfobCore | M | 1.2 |
| 1.4 | Onboarding flow (create/import key, biometric setup) | KeyfobUI, app targets | M | 1.1–1.3 |
| 1.5 | Key management UI (list, rename, set active, show npub) | KeyfobUI, app targets | M | 1.1–1.3 |
| 1.6 | Entry-point gating (no-identity → onboarding) | KeyfobBridge, apps, extensions | M | 1.1, 1.4 |

### Migration
- Existing single-key installs: synthesize one IdentityMetadata record, mark active, leave secret untouched.
- Idempotent via persisted schema version marker.

---

## Phase 2 — Trust Model, Permissions & Low-Friction Approval

**Priority**: P0 (core differentiator)
**Goal**: Keyfob feels safe AND low-friction. Smart defaults minimize prompts without sacrificing trust.

### Architecture: Generalized Signer Operations

```
SignerOperation (closed enum)
├── getPublicKey
├── signEvent(event)
├── nip04Encrypt(peerPubkey, plaintext)
├── nip04Decrypt(peerPubkey, ciphertext)
├── nip44Encrypt(peerPubkey, plaintext)
├── nip44Decrypt(peerPubkey, payload)
├── exportPrivateKey(format)
└── pairRemoteSigner(connectionRequest)
```

```
ClientRecord (persisted)
├── id: String
├── clientType: webOrigin | xpcBundleId | appIntentSource | remotePubkey
├── displayName: String?
├── firstSeenAt / lastSeenAt: Date
└── trustState: unknown | approved | blocked

PermissionRule (persisted)
├── identityId + clientId + operation + eventKind?
├── decision: allow | prompt | deny
├── sessionDuration / expiresAt
```

### Tasks

| # | Task | Modules | Effort | Depends On |
|---|------|---------|--------|------------|
| 2.1 | Generalize SignOrchestrator to SignerOperation | KeyfobCore | L | Phase 1 |
| 2.2 | Per-client registry (web origins, bundles, remote pubkeys) | KeyfobPolicy, KeyfobBridge | M | 2.1 |
| 2.3 | Per-client/per-kind permission rules | KeyfobPolicy, KeyfobCore | L | 2.1–2.2 |
| 2.4 | Signing policy presets ("Basic" auto-approve / "Manual" per-app) | KeyfobPolicy, KeyfobUI | M | 2.3 |
| 2.5 | History view (audit log → user-facing with filters) | KeyfobPolicy, KeyfobUI | M | 2.1–2.3 |
| 2.6 | Consent UX v2 (client identity, kind, session state, shortcuts) | KeyfobUI, KeyfobCore | M | 2.1–2.4 |

### Default Policies

**Basic auto-approve (recommended)**:
- `getPublicKey`: allow after first client trust approval
- `signEvent`: first request per client prompts → timed session (10–15 min) for that identity+client
- Crypto ops: prompt on first use, then session
- Export/reveal: always prompt + biometric

**Manual per-app**:
- Every request prompts unless user creates a persistent allow rule

---

## Phase 3 — Protocol Completeness & Recovery Safety

**Priority**: P1 (table stakes for real adoption)
**Goal**: Support the crypto methods real Nostr apps use. Standard backup/import formats.

### Tasks

| # | Task | Modules | Effort | Depends On |
|---|------|---------|--------|------------|
| 3.1 | NIP-06 mnemonic import/derivation (BIP39/BIP32) | KeyfobCrypto, KeyfobUI | L | Phase 1 |
| 3.2 | NIP-49 ncryptsec export/import (scrypt + XChaCha20-Poly1305) | KeyfobCrypto, KeyfobUI | L | Phase 1 |
| 3.3 | Legacy AES-GCM import compatibility | KeyfobCrypto | M | 3.2 |
| 3.4 | NIP-44 encrypt/decrypt (ECDH + HKDF + ChaCha20 + HMAC-SHA256) | KeyfobCrypto, KeyfobCore | L | 2.1 |
| 3.5 | NIP-04 encrypt/decrypt (deprecated compat) | KeyfobCrypto, KeyfobCore | M | 2.1 |
| 3.6 | Policy/audit integration for crypto operations | KeyfobCore, KeyfobPolicy, KeyfobUI | M | 3.4–3.5 |

### Notes
- NIP-44 must land before NIP-46 integration (Phase 4) since NIP-46 uses NIP-44 for message encryption.
- NIP-49 becomes the default export format; legacy AES-GCM import retained indefinitely.

---

## Phase 4 — Full NIP-46 Remote Signer Product

**Priority**: P1 (biggest remaining value unlock)
**Goal**: Keyfob becomes a remote signer that desktop/web apps can pair with via relay.

### Architecture: New Integration Module

```
KeyfobSignerIntegration (new SPM module)
├── Dependencies: KeyfobRelay, KeyfobCrypto, KeyfobCore, KeyfobPolicy
├── Owns: NIP-46 session manager, decrypt/dispatch/respond, pairing lifecycle
├── Does NOT own: WebSocket transport, secret storage, UI state
```

KeyfobRelay remains zero-dependency.

### End-to-End NIP-46 Flow

```
bunker:// or nostrconnect:// or QR scan
  → KeyfobBridge (URL parsing)
  → Pairing record persisted
  → KeyfobSignerIntegration starts relay session via RelayPool
  → NIP46Handler receives encrypted kind 24133
  → Integration module decrypts via KeyfobCrypto (NIP-44)
  → Maps to SignerOperation
  → KeyfobCore.SignOrchestrator
  → KeyfobPolicy.PolicyEngine
  → ConsentView if needed
  → KeyfobCrypto executes
  → Integration module encrypts response (NIP-44)
  → KeyfobRelay publishes response
```

### Tasks

| # | Task | Modules | Effort | Depends On |
|---|------|---------|--------|------------|
| 4.1 | KeyfobSignerIntegration module | new module | L | Phases 2–3 |
| 4.2 | NIP-46 method router (ping, connect, sign, crypto) | Integration, KeyfobCore | M | 4.1 |
| 4.3 | Pairing URL support (bunker://, nostrconnect://) | KeyfobBridge, app targets | M | 4.1 |
| 4.4 | QR pairing UX (iOS camera, macOS paste/import) | app targets, KeyfobUI | M | 4.3 |
| 4.5 | Relay configuration UI | KeyfobUI, app targets | M | 4.1 |
| 4.6 | Remote connection management (paired apps, revoke) | KeyfobUI, KeyfobPolicy | M | 4.2–4.5 |
| 4.7 | Remote requests in unified history | KeyfobPolicy, KeyfobCore | S | 4.1–4.2 |

---

## Phase 5 — Ecosystem Integration for Apple Clients

**Priority**: P2 (broadens adoption)
**Goal**: Third-party Apple apps can integrate with Keyfob easily.

### Tasks

| # | Task | Modules | Effort | Depends On |
|---|------|---------|--------|------------|
| 5.1 | nostrsigner:// URL scheme (Apple NIP-55 equivalent) | KeyfobBridge, app targets | M | Phase 2 |
| 5.2 | Multi-key-aware XPC/App Intent contracts | KeyfobBridge, macOS helper | M | Phases 1–2 |
| 5.3 | Capability negotiation (discover supported ops) | KeyfobBridge, KeyfobWebShared | S | Phases 3–4 |
| 5.4 | Integration sample/package for third-party apps | new package or demo | M | 5.1–5.3 |
| 5.5 | Web extension capability update (NIP-07 + new methods) | KeyfobWebShared, Safari exts | S | Phases 2–3 |

---

## Phase 6 — Polish, Trust Signals & Release Hardening

**Priority**: P2 (ship-quality)
**Goal**: Close the gap between feature-complete and preferred daily signer.

### Tasks

| # | Task | Modules | Effort | Depends On |
|---|------|---------|--------|------------|
| 6.1 | Active profile display (fetch kind:0, show avatar/name/npub) | KeyfobRelay, KeyfobUI | M | Phase 4 relay config |
| 6.2 | Consent and history polish (human-readable summaries, risk labels) | KeyfobUI, KeyfobCore | M | Phase 2 |
| 6.3 | Diagnostics surfaces (relay telemetry viewer, audit export) | KeyfobRelay, KeyfobPolicy, KeyfobUI | M | Phases 2–4 |
| 6.4 | Reliability hardening (cross-process locking, reconnect edge cases) | multiple | L | All prior |
| 6.5 | Release readiness (a11y, l10n, entitlement audit, privacy, docs) | all app targets | M | All prior |

---

## Implementation Order (Summary)

```
1. Audit shared storage & entitlements
2. Identity metadata store + active-identity model        ← Phase 1
3. Identity-addressable crypto APIs                       ← Phase 1
4. Onboarding + key management UI                         ← Phase 1
5. Generalize SignOrchestrator → SignerOperation           ← Phase 2
6. Per-client/per-kind permissions + history UI            ← Phase 2
7. NIP-19, NIP-06, NIP-49, NIP-44, NIP-04                ← Phase 3
8. KeyfobSignerIntegration + end-to-end NIP-46            ← Phase 4
9. nostrsigner://, capability negotiation, IPC updates    ← Phase 5
10. Polish, diagnostics, hardening, release               ← Phase 6
```

## Risks

| Risk | Mitigation |
|------|-----------|
| Single-key → multi-key migration | Synthesize metadata from existing key; idempotent via schema version |
| NIP-49 export not backward-compatible | Keep AES-GCM import forever; label new format clearly |
| Cross-process persistence races | Serialized writes, atomic file replacement, stress-test multi-target |
| NIP46Handler may need hooks for integration | Validate with test trace before coding UI |
| Entitlement/access-group mismatch across targets | Audit before implementation begins |
| iOS 15+ excludes SwiftData | Use app-group-backed file persistence with atomic writes |
