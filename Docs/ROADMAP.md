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
6. **SDK-first**: Use nostr-sdk-ios primitives before building custom implementations. The SDK already provides NIP-44, NIP-04, NIP-19, event serialization, and key management types.

---

## SDK Dependency: nostr-sdk-ios

**Version**: 0.3.0 (latest release)
**Platforms**: macOS 12+, iOS 15+ (matches Keyfob)

### SDK Primitives Available (no custom implementation needed)

| Primitive | SDK Type/Protocol | Replaces Custom |
|-----------|------------------|-----------------|
| NIP-44 encrypt/decrypt | `NIP44v2Encrypting` protocol | — (was planned from scratch) |
| NIP-04 encrypt/decrypt | `LegacyDirectMessageEncrypting` protocol | — (was planned from scratch) |
| NIP-19 bech32 keys | `PublicKey.npub`, `PrivateKey.nsec` | — (was planned from scratch) |
| NIP-19 TLV entities | `MetadataCoding`, `Bech32IdentifierType` | — (was planned from scratch) |
| Event serialization | `EventSerializer` | `CanonicalJSON.serializeEvent()` |
| Schnorr signatures | `ContentSigning` protocol | Custom secp256k1 calls |
| Event verification | `EventVerifying` protocol | — |
| Key types | `Keypair`, `PublicKey`, `PrivateKey` | `KeyfobCrypto.Keypair` (pubkeyHex only) |
| Event model | `NostrEvent` (Builder pattern) | `KeyfobCore.NostrEvent` (basic struct) |
| Event kinds | `EventKind` enum (.authentication, etc.) | Hardcoded Int values |
| Combined crypto | `EventCreating` protocol | — |

### NOT in SDK (custom implementation required)

| Primitive | Notes |
|-----------|-------|
| NIP-06 BIP39/BIP32 mnemonic derivation | Need BIP39 wordlist + BIP32 HD key derivation |
| NIP-49 ncryptsec encryption | Need scrypt + XChaCha20-Poly1305 + bech32 |
| Keychain storage with biometrics | Apple-specific, Keyfob's core value |
| Policy engine / consent | Keyfob-specific trust model |
| Relay infrastructure | KeyfobRelay (zero-dependency by design) |

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

### Protocol Gaps (SDK-aware)
- **NIP-04**: SDK provides `LegacyDirectMessageEncrypting` — wrap it, don't reimplement
- **NIP-06**: NOT in SDK — custom BIP39/BIP32 implementation needed
- **NIP-19**: SDK provides `PublicKey.npub`, `PrivateKey.nsec`, `MetadataCoding` — wire through UI
- **NIP-44**: SDK provides `NIP44v2Encrypting` — wrap it, don't reimplement
- **NIP-49**: NOT in SDK — custom scrypt + XChaCha20-Poly1305 implementation needed
- **NIP-46**: Handler exists, needs SDK crypto integration layer

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

### Architecture Gaps
- KeyfobRelay is zero-dependency by design — needs an integration module to wire NIP-46 to crypto/policy
- Custom `KeyfobCrypto.Keypair` only holds `pubkeyHex` — should adopt SDK's full `Keypair` type
- Custom `CanonicalJSON` and `Signer.serializeNIP01()` duplicate SDK's `EventSerializer`
- Custom `KeyfobCore.NostrEvent` is a plain struct — SDK's `NostrEvent` has Builder pattern, signing, bech32

---

## Phase 1 — Identity Foundation & First-Run Experience

**Priority**: P0 (blocks everything)
**Goal**: A user can install Keyfob, create or import a key, and start signing.
**SDK impact**: Adopt SDK `Keypair`/`PublicKey`/`PrivateKey` types throughout. Replace custom serialization.

### Critical Path

```
kf-kec: Adopt SDK Keypair type
  ├── kf-7of: Replace custom serialization with SDK EventSerializer
  │     └── kf-rek: SignerOperation pipeline (Phase 2 foundation)
  ├── kf-3kr: IdentityStore protocol + Keychain impl
  │     ├── kf-gps: Migrate KeyManager
  │     ├── kf-8qj: Onboarding create flow
  │     └── kf-92b: Client identity model (Phase 2)
  ├── kf-ghe: Wire npub/nsec display
  ├── kf-dbn: Bech32 import parsing
  └── kf-l7w: nprofile/nevent/naddr via MetadataCoding
```

### Tasks

| Bead | Task | SDK Usage | Effort |
|------|------|-----------|--------|
| kf-kec | Adopt SDK Keypair type in KeyfobCrypto | Replace custom Keypair with SDK's Keypair/PublicKey/PrivateKey | M |
| kf-7of | Replace custom event serialization | SDK EventSerializer + ContentSigning replace CanonicalJSON + serializeNIP01 | M |
| kf-3kr | IdentityStore protocol + Keychain impl | Store/retrieve SDK PrivateKey data, reconstruct SDK Keypair | L |
| kf-gps | Migrate KeyManager to IdentityStore | Adapt existing Keychain patterns to new protocol | M |
| kf-ghe | Wire npub/nsec display in identity UI | SDK PublicKey.npub / PrivateKey.nsec — no custom bech32 | S |
| kf-dbn | Bech32 key import parsing | SDK PrivateKey(nsec:) / PublicKey(npub:) initializers | S |
| kf-l7w | nprofile/nevent/naddr support | SDK MetadataCoding + Bech32IdentifierType — no custom TLV | M |
| kf-8qj | Onboarding: create new key flow | Generate SDK Keypair, show npub confirmation | M |
| kf-bbk | Onboarding: import existing key flow | Parse nsec/hex via SDK, validate, store | M |

### Migration
- Existing single-key installs: synthesize one Identity record from existing Keychain key, mark active.
- Idempotent via persisted schema version marker.

---

## Phase 2 — Trust Model, Permissions & Low-Friction Approval

**Priority**: P0 (core differentiator)
**Goal**: Keyfob feels safe AND low-friction. Smart defaults minimize prompts without sacrificing trust.
**SDK impact**: Pipeline uses SDK's `EventCreating` protocol (bundles signing + NIP-44 + NIP-04).

### Tasks

| Bead | Task | Details | Effort |
|------|------|---------|--------|
| kf-rek | SignerOperation enum + pipeline protocol | Validate → identity → policy → consent → execute (SDK) → audit | L |
| kf-92b | Client identity model + persistence | ClientIdentity with SwiftData / UserDefaults fallback | M |
| kf-sxf | PermissionRule model + policy integration | Per-client/per-kind/per-operation rules, session scoping | L |
| kf-z19 | Consent UX with context + remember | Operation type, client name, event kind, npub, remember options | M |
| kf-w5x | Policy presets (basic/standard/paranoid) | Three preset PermissionRule sets, customizable | M |
| kf-cmq | Signing request history view | Chronological list from AuditLog, filter by client/type/outcome | M |

### Default Policies

**Basic auto-approve (recommended)**:
- `getPublicKey`: allow after first client trust approval
- `signEvent`: first request per client prompts → timed session (10–15 min)
- Crypto ops: prompt on first use, then session
- Export/reveal: always prompt + biometric

**Paranoid per-app**:
- Every request prompts unless user creates a persistent allow rule

---

## Phase 3 — Protocol Completeness & Recovery Safety

**Priority**: P1 (table stakes for real adoption)
**Goal**: Support the crypto methods real Nostr apps use. Standard backup/import formats.
**SDK impact**: NIP-44 and NIP-04 are pure SDK wrapping — no custom crypto. NIP-06 and NIP-49 need custom implementations.

### Tasks

| Bead | Task | SDK? | Effort |
|------|------|------|--------|
| kf-0qn | EncryptionService wrapping NIP44v2Encrypting | ✅ SDK wrap | M |
| kf-cjp | LegacyEncryptionService wrapping NIP-04 | ✅ SDK wrap | S |
| kf-my4 | NIP-44/NIP-04 integration tests | Test SDK integration | M |
| kf-3vo | Policy/audit wiring for encrypt/decrypt | Extend PolicyEngine for crypto ops | M |
| kf-5in | BIP39 mnemonic generation + validation | ❌ Custom (not in SDK) | L |
| kf-s8m | BIP32 key derivation at NIP-06 path | ❌ Custom (not in SDK) | L |
| kf-q3r | NIP-49 scrypt + XChaCha20-Poly1305 | ❌ Custom (CryptoSwift available as transitive dep) | L |
| kf-3so | NIP-49 ncryptsec bech32 encoding/decoding | ❌ Custom | M |
| kf-65u | Legacy AES-GCM import compatibility | Migration path | S |

### Notes
- NIP-44 must land before NIP-46 integration (Phase 4) since NIP-46 uses NIP-44 for message encryption.
- NIP-49 becomes the default export format; legacy AES-GCM import retained indefinitely.
- CryptoSwift (SDK transitive dependency) provides scrypt — can use it for NIP-49.

---

## Phase 4 — Full NIP-46 Remote Signer Product

**Priority**: P1 (biggest remaining value unlock)
**Goal**: Keyfob becomes a remote signer that desktop/web apps can pair with via relay.
**SDK impact**: NIP46Delegate uses SDK's EventCreating (NIP-44 transport encryption + signing). RelayAuthSigner uses SDK NostrEvent + ContentSigning.

### Architecture: New Integration Module

```
KeyfobSignerIntegration (new SPM module)
├── Dependencies: KeyfobRelay, KeyfobCrypto, KeyfobCore, KeyfobPolicy
├── Implements: NIP46Delegate (via SDK EventCreating)
├── Implements: RelayAuthSigner (via SDK NostrEvent + ContentSigning)
├── Owns: NIP-46 session manager, decrypt/dispatch/respond, pairing lifecycle
├── Does NOT own: WebSocket transport, secret storage, UI state
```

KeyfobRelay remains zero-dependency.

### Tasks

| Bead | Task | SDK Usage | Effort |
|------|------|-----------|--------|
| kf-3wi | NIP46Delegate via SDK EventCreating | SDK NIP44v2Encrypting for transport, ContentSigning for events | L |
| kf-t4p | RelayAuthSigner via SDK NostrEvent | SDK NostrEvent builder + Schnorr signing for kind 22242 | M |
| kf-862 | NIP-46 encrypt/decrypt method handlers | Route nip04/nip44 encrypt/decrypt through pipeline | M |
| kf-gst | bunker:// URL handler + pairing state machine | Parse URI, connect relays, exchange connect handshake | M |
| kf-sso | QR code generation + scanning | AVFoundation (iOS), generate/scan bunker:// URIs | M |
| kf-d5b | Relay configuration UI | List relays, add/remove, show state + RelayInfo | M |
| kf-2v8 | Remote connection management UI | Paired apps, disconnect, permissions, history filter | M |

---

## Phase 5 — Ecosystem Integration for Apple Clients

**Priority**: P2 (broadens adoption)
**Goal**: Third-party Apple apps can integrate with Keyfob easily.

### Tasks

| Bead | Task | SDK Usage | Effort |
|------|------|-----------|--------|
| kf-9r0 | NIP-07 nip44 sub-object | SDK NIP44v2Encrypting via pipeline | M |
| kf-7dj | NIP-07 nip04 sub-object | SDK LegacyDirectMessageEncrypting via pipeline | S |
| kf-g5t | nostrsigner:// URL scheme (Apple NIP-55) | Route operations through SignerOperation pipeline | M |
| kf-cav | Multi-key XPC + App Intent contracts | Add identity parameter, encrypt/decrypt methods | M |
| kf-bx9 | Capability negotiation protocol | Expose supported operations via all IPC channels | S |
| kf-sor | Integration sample Swift package | Demo XPC client, URL scheme, App Intent usage | M |

---

## Phase 6 — Polish, Trust Signals & Release Hardening

**Priority**: P2 (ship-quality)
**Goal**: Close the gap between feature-complete and preferred daily signer.

### Tasks

| Bead | Task | Details | Effort |
|------|------|---------|--------|
| kf-wsf | Active profile display | Fetch kind:0 via RelayPool, show avatar/name/npub | M |
| kf-798 | Telemetry + diagnostics viewer | Connection timeline, latency, reconnect history, export | M |
| kf-hje | Reliability hardening pass | Cancellation, thread safety, timeouts, memory, stress test | L |
| kf-xem | Release readiness checklist | A11y, l10n, privacy manifest, code signing, TestFlight | M |

---

## Implementation Order (Summary)

```
FOUNDATION (no deps):
  kf-kec → Adopt SDK Keypair                              ← START HERE
  kf-5in → BIP39 mnemonic (parallel track)
  kf-q3r → NIP-49 crypto (parallel track)

PHASE 1 (identity):
  kf-7of → SDK EventSerializer
  kf-3kr → IdentityStore
  kf-ghe → npub/nsec display
  kf-dbn → bech32 import
  kf-gps → Migrate KeyManager
  kf-8qj → Onboarding create
  kf-bbk → Onboarding import

PHASE 2 (trust):
  kf-rek → SignerOperation pipeline
  kf-92b → Client model
  kf-sxf → Permission rules
  kf-z19 → Consent UX
  kf-w5x → Policy presets
  kf-cmq → History view

PHASE 3 (crypto):
  kf-0qn → NIP-44 SDK wrap
  kf-cjp → NIP-04 SDK wrap
  kf-s8m → BIP32 derivation
  kf-3so → ncryptsec bech32
  kf-3vo → Policy/audit for crypto

PHASE 4 (remote signer):
  kf-3wi → NIP46Delegate
  kf-t4p → RelayAuthSigner
  kf-862 → NIP-46 method router
  kf-gst → bunker:// pairing
  kf-sso → QR pairing

PHASE 5 (ecosystem):
  kf-9r0 → NIP-07 nip44
  kf-7dj → NIP-07 nip04
  kf-g5t → nostrsigner://
  kf-cav → Multi-key XPC

PHASE 6 (polish):
  kf-wsf → Profile display
  kf-hje → Hardening
  kf-xem → Release readiness
```

## Risks

| Risk | Mitigation |
|------|-----------|
| Single-key → multi-key migration | Synthesize metadata from existing key; idempotent via schema version |
| SDK 0.3.0 vs main divergence | Main bumps to macOS 14 + Swift 5.10; stay on 0.3.0 until Keyfob is ready to bump minimums |
| NIP-49 export not backward-compatible | Keep AES-GCM import forever; label new format clearly |
| Cross-process persistence races | Serialized writes, atomic file replacement, stress-test multi-target |
| NIP46Handler may need hooks for integration | Validate with test trace before coding UI |
| Entitlement/access-group mismatch across targets | Audit before implementation begins |
| iOS 15+ excludes SwiftData | Use app-group-backed file persistence with atomic writes for iOS 15-16 |
| BIP39/BIP32 correctness | Use well-tested library or validate against reference test vectors |
