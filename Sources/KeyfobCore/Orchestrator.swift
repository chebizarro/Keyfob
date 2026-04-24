//
//  Orchestrator.swift
//
//
//  Created for Keyfob – kf-85t (generalized from sign-only)
//

import Foundation
import KeyfobCrypto
import KeyfobPolicy

// MARK: - SignOrchestrator

/// The single entry point for ALL crypto operations from ALL IPC channels.
///
/// Implements ``OperationPipeline`` with the full pipeline:
/// validate → resolve identity → check policy → prompt consent → execute → audit → return.
///
/// Supports all five ``SignerOperation`` cases:
/// - `.sign` → Schnorr signature via ``Signer``
/// - `.nip44Encrypt` / `.nip44Decrypt` → via ``EncryptionService``
/// - `.nip04Encrypt` / `.nip04Decrypt` → via ``EncryptionService`` (legacy)
///
/// ## Dependency Injection
///
/// The orchestrator requires an ``IdentityStore`` for identity resolution and
/// keypair loading. ``EncryptionService`` and ``PolicyEngine`` default to
/// sensible production values.
///
/// ## Backward Compatibility
///
/// The legacy ``prepareAndSign(event:origin:mode:)`` method is preserved for
/// existing callers that haven't migrated to the pipeline API.
public final class SignOrchestrator: OperationPipeline {

    private let identityStore: IdentityStore?
    private let encryptionService: EncryptionService
    private let policyEngine: PolicyEngine

    // MARK: - Init

    /// Create an orchestrator with explicit dependencies for the full pipeline.
    ///
    /// - Parameters:
    ///   - identityStore: Store for identity resolution and keypair loading.
    ///   - encryptionService: Crypto executor for NIP-44/NIP-04 operations.
    ///   - policyEngine: Policy engine for rate limiting, rules, and consent.
    public init(
        identityStore: IdentityStore,
        encryptionService: EncryptionService = EncryptionService(),
        policyEngine: PolicyEngine = .shared
    ) {
        self.identityStore = identityStore
        self.encryptionService = encryptionService
        self.policyEngine = policyEngine
    }

    /// Legacy no-arg initializer for backward-compatible ``prepareAndSign`` usage.
    ///
    /// Does **not** support the full ``OperationPipeline/execute`` method — calling
    /// it will throw ``OperationPipelineError/noActiveIdentity`` because no
    /// ``IdentityStore`` is configured. Use ``init(identityStore:encryptionService:policyEngine:)``
    /// for full pipeline support.
    public init() {
        self.identityStore = nil
        self.encryptionService = EncryptionService()
        self.policyEngine = .shared
    }

    // MARK: - OperationPipeline

    /// Execute a crypto operation through the full pipeline.
    ///
    /// Pipeline stages:
    /// 1. **Validate** operation inputs (peer pubkey format, etc.)
    /// 2. **Resolve identity** from ``IdentitySelection`` → ``Identity`` + SDK keypair
    /// 3. **Validate event pubkey** (for sign ops: must match resolved identity)
    /// 4. **Policy preflight** (rate limit → permission rules → consent prompt)
    /// 5. **Execute** the crypto operation
    /// 6. **Audit log** the outcome (success or failure)
    /// 7. **Return** ``OperationOutput``
    ///
    /// - Parameters:
    ///   - operation: The operation to perform.
    ///   - identity: Which identity to use.
    ///   - client: Context about the requesting client.
    /// - Returns: The operation output on success.
    /// - Throws: ``OperationPipelineError``, ``IdentityStoreError``, ``SignerError``,
    ///           ``EncryptionServiceError``, or policy-layer errors on failure.
    public func execute(
        operation: SignerOperation,
        identity: IdentitySelection,
        client: ClientContext
    ) throws -> OperationOutput {
        let startTime = CFAbsoluteTimeGetCurrent()
        var resolvedPubkey: String?

        do {
            // 1. Validate operation inputs.
            try validate(operation)

            // 2. Resolve identity.
            guard let store = identityStore else {
                throw OperationPipelineError.noActiveIdentity
            }
            let resolvedIdentity = try resolveIdentity(identity, store: store)
            resolvedPubkey = resolvedIdentity.pubkeyHex

            // 3. Validate event pubkey for sign operations.
            if case .sign(let event) = operation {
                try validateEventPubkey(event, resolvedPubkey: resolvedIdentity.pubkeyHex)
            }

            // 4. Policy preflight (rate limit → rules → consent).
            let consentMode = mapApprovalPreference(client.approvalPreference)
            let preview = buildConsentPreview(operation, identity: resolvedIdentity)
            try policyEngine.preflightOperation(
                clientID: client.clientID,
                identityID: resolvedIdentity.id,
                operationKind: operation.kind.rawValue,
                eventKind: operation.eventKind,
                counterpartyPubkey: operation.peerPubkeyHex,
                identityPubkey: resolvedIdentity.pubkeyHex,
                eventPreview: preview,
                mode: consentMode
            )

            // 5. Execute — keypair loaded and consumed inline so we never need
            //    to spell the NostrSDK.Keypair type in a method signature.
            let keypair = try store.loadSDKKeypair(for: resolvedIdentity.id)
            let output: OperationOutput

            switch operation {
            case .sign(let event):
                let json = try CanonicalJSON.serializeEvent(event)
                let resp = try Signer().signEvent(eventJSON: json, with: keypair)
                output = .signature(resp)

            case .nip44Encrypt(let peerPK, let plaintext):
                let ct = try encryptionService.nip44Encrypt(
                    plaintext: plaintext, peerPubkeyHex: peerPK, using: keypair
                )
                output = .ciphertext(ct)

            case .nip44Decrypt(let peerPK, let ciphertext):
                let pt = try encryptionService.nip44Decrypt(
                    payload: ciphertext, peerPubkeyHex: peerPK, using: keypair
                )
                output = .plaintext(pt)

            // NIP-04 is intentionally supported for legacy client compatibility.
            // Uses non-deprecated pipeline entry points on EncryptionService.
            case .nip04Encrypt(let peerPK, let plaintext):
                let ct = try encryptionService.legacyEncrypt(
                    content: plaintext, peerPubkeyHex: peerPK, using: keypair
                )
                output = .ciphertext(ct)

            case .nip04Decrypt(let peerPK, let ciphertext):
                let pt = try encryptionService.legacyDecrypt(
                    encryptedContent: ciphertext, peerPubkeyHex: peerPK, using: keypair
                )
                output = .plaintext(pt)
            }

            // 6. Audit success.
            let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            policyEngine.recordOperationSuccess(
                clientID: client.clientID,
                operationKind: operation.kind.rawValue,
                eventKind: operation.eventKind,
                counterpartyPubkey: operation.peerPubkeyHex,
                identityPubkey: resolvedIdentity.pubkeyHex,
                durationMs: durationMs
            )

            return output

        } catch {
            // 6. Audit failure.
            let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            policyEngine.recordOperationFailure(
                clientID: client.clientID,
                operationKind: operation.kind.rawValue,
                eventKind: operation.eventKind,
                counterpartyPubkey: operation.peerPubkeyHex,
                identityPubkey: resolvedPubkey,
                error: error,
                durationMs: durationMs
            )
            throw error
        }
    }

    // MARK: - Legacy API

    public enum Mode { case perRequest, session }

    /// Legacy sign-only entry point for backward compatibility.
    ///
    /// Uses ``Signer`` with the default (KeyManager-loaded) keypair.
    /// Does not use ``IdentityStore`` or the full pipeline.
    ///
    /// Existing callers: AppDelegate, BridgeHandler, SignIntent,
    /// KeyfobXPCService, ActionExtension.
    public func prepareAndSign(event: NostrEvent, origin: String, mode: Mode) throws -> SignatureResponse {
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            try policyEngine.preflight(origin: origin)
            let json = try CanonicalJSON.serializeEvent(event)
            let consentMode: PolicyEngine.ConsentMode = (mode == .perRequest) ? .perRequest : .session
            try policyEngine.requestConsent(origin: origin, eventPreview: json, mode: consentMode)
            let resp = try Signer().signEvent(eventJSON: json)
            policyEngine.recordSuccess(origin: origin)

            let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            policyEngine.auditLog.log(AuditEntry(
                origin: origin,
                action: .approved,
                eventKind: event.kind,
                detail: "sign completed, mode=\(mode)",
                durationMs: durationMs,
                operationType: SignerOperationKind.sign.rawValue
            ))

            return resp
        } catch {
            let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            policyEngine.auditLog.log(AuditEntry(
                origin: origin,
                action: .denied,
                eventKind: event.kind,
                detail: "sign failed: \(error.localizedDescription)",
                durationMs: durationMs,
                operationType: SignerOperationKind.sign.rawValue
            ))
            throw error
        }
    }

    // MARK: - Private: Validation

    /// Validate operation inputs before identity resolution.
    private func validate(_ operation: SignerOperation) throws {
        switch operation {
        case .sign:
            break // Event structure validated after identity resolution (pubkey check).
        case .nip44Encrypt(let pk, _), .nip44Decrypt(let pk, _),
             .nip04Encrypt(let pk, _), .nip04Decrypt(let pk, _):
            try validatePeerPubkey(pk)
        }
    }

    /// Validate a peer public key is a 64-char lowercase hex string.
    private func validatePeerPubkey(_ hex: String) throws {
        guard hex.count == 64,
              hex.allSatisfy({ $0.isHexDigit }),
              hex == hex.lowercased() else {
            throw OperationPipelineError.invalidPeerPublicKey(hex)
        }
    }

    /// Validate that a sign event's pubkey matches the resolved identity.
    /// An empty event pubkey is allowed — the pipeline fills it in.
    private func validateEventPubkey(_ event: NostrEvent, resolvedPubkey: String) throws {
        let eventPubkey = event.pubkey
        if !eventPubkey.isEmpty && eventPubkey != resolvedPubkey {
            throw OperationPipelineError.eventPubkeyMismatch(
                expected: resolvedPubkey,
                provided: eventPubkey
            )
        }
    }

    // MARK: - Private: Identity Resolution

    /// Resolve identity selection to a concrete ``Identity``.
    private func resolveIdentity(_ selection: IdentitySelection, store: IdentityStore) throws -> Identity {
        switch selection {
        case .active:
            guard let active = try store.activeIdentity() else {
                throw OperationPipelineError.noActiveIdentity
            }
            return active

        case .specific(let id):
            let allIdentities = try store.listIdentities()
            guard let found = allIdentities.first(where: { $0.id == id }) else {
                throw IdentityStoreError.identityNotFound(id)
            }
            return found
        }
    }

    // MARK: - Private: Policy Mapping

    /// Map client's approval preference to PolicyEngine consent mode.
    private func mapApprovalPreference(_ pref: ApprovalPreference) -> PolicyEngine.ConsentMode {
        switch pref {
        case .perRequest: return .perRequest
        case .session: return .session
        case .inheritPolicy: return .perRequest // Default to per-request when inheriting.
        }
    }

    /// Build a human-readable preview string for the consent dialog.
    private func buildConsentPreview(_ operation: SignerOperation, identity: Identity) -> String {
        switch operation {
        case .sign(let event):
            return (try? CanonicalJSON.serializeEvent(event)) ?? "{}"
        case .nip44Encrypt(let pk, _):
            return "NIP-44 encrypt to \(NpubDisplay.truncated(pk))"
        case .nip44Decrypt(let pk, _):
            return "NIP-44 decrypt from \(NpubDisplay.truncated(pk))"
        case .nip04Encrypt(let pk, _):
            return "NIP-04 encrypt to \(NpubDisplay.truncated(pk))"
        case .nip04Decrypt(let pk, _):
            return "NIP-04 decrypt from \(NpubDisplay.truncated(pk))"
        }
    }

}
