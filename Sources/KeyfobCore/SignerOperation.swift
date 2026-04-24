//
//  SignerOperation.swift
//
//
//  Created for Keyfob – kf-rek
//

import Foundation
import KeyfobCrypto

// MARK: - SignerOperationKind

/// The kind of a ``SignerOperation``, without payloads.
///
/// Used for policy rules, audit logging, and UI switching where
/// the full operation payload is not needed.
public enum SignerOperationKind: String, Codable, Sendable, CaseIterable {
    case sign
    case nip44Encrypt
    case nip44Decrypt
    case nip04Encrypt
    case nip04Decrypt
}

// MARK: - SignerOperation

/// A crypto operation request from any IPC channel.
///
/// This is the canonical input to ``OperationPipeline``. Each case
/// carries the minimum data needed for the operation. Identity resolution,
/// policy checks, and consent happen inside the pipeline, not the caller.
///
/// > Note: NIP-44 and NIP-04 operations are defined now but will throw
/// > ``OperationPipelineError/unsupportedOperation(_:)`` until their
/// > executor beads (kf-0qn, kf-cjp) land.
public enum SignerOperation: Equatable, Sendable {
    /// Sign a Nostr event. The pipeline recomputes `id` and `sig`;
    /// any inbound values are ignored.
    case sign(NostrEvent)

    /// Encrypt plaintext for a peer using NIP-44 (XChaCha20-Poly1305 + HKDF).
    case nip44Encrypt(peerPubkeyHex: String, plaintext: String)

    /// Decrypt NIP-44 ciphertext from a peer.
    case nip44Decrypt(peerPubkeyHex: String, ciphertext: String)

    /// Encrypt plaintext for a peer using legacy NIP-04 (AES-256-CBC).
    case nip04Encrypt(peerPubkeyHex: String, plaintext: String)

    /// Decrypt NIP-04 ciphertext from a peer.
    case nip04Decrypt(peerPubkeyHex: String, ciphertext: String)

    /// The kind of this operation, without payloads.
    public var kind: SignerOperationKind {
        switch self {
        case .sign: return .sign
        case .nip44Encrypt: return .nip44Encrypt
        case .nip44Decrypt: return .nip44Decrypt
        case .nip04Encrypt: return .nip04Encrypt
        case .nip04Decrypt: return .nip04Decrypt
        }
    }

    /// The Nostr event kind, if this is a `.sign` operation.
    public var eventKind: Int? {
        switch self {
        case .sign(let event): return event.kind
        default: return nil
        }
    }

    /// The peer public key hex, if this is a crypto (encrypt/decrypt) operation.
    public var peerPubkeyHex: String? {
        switch self {
        case .sign: return nil
        case .nip44Encrypt(let pk, _), .nip44Decrypt(let pk, _),
             .nip04Encrypt(let pk, _), .nip04Decrypt(let pk, _):
            return pk
        }
    }
}

// MARK: - IdentitySelection

/// How the pipeline should resolve which identity to use for an operation.
public enum IdentitySelection: Equatable, Sendable {
    /// Use the currently active identity from the ``IdentityStore``.
    case active
    /// Use a specific identity by its UUID.
    case specific(UUID)
}

// MARK: - OperationOutput

/// The output of a successful pipeline execution.
///
/// Each case corresponds to a ``SignerOperation`` variant.
/// Failures are expressed as thrown errors, not as an output case.
public enum OperationOutput: Equatable, Sendable {
    /// Result of a `.sign` operation: event id, signature, and pubkey.
    case signature(SignatureResponse)
    /// Result of an encrypt operation: the ciphertext string.
    case ciphertext(String)
    /// Result of a decrypt operation: the recovered plaintext string.
    case plaintext(String)
}

// MARK: - OperationPipelineError

/// Errors specific to the ``OperationPipeline`` orchestration layer.
///
/// These are distinct from `IdentityStoreError` (identity/keychain issues),
/// `SignerError` (crypto execution), and `PolicyEngine` errors (rate limiting,
/// consent denial). Those errors propagate through the pipeline unmodified.
public enum OperationPipelineError: Error, Equatable {
    /// No active identity is set and ``IdentitySelection/active`` was requested.
    case noActiveIdentity

    /// The peer public key is not a valid 64-character hex string.
    case invalidPeerPublicKey(String)

    /// The event's pubkey field doesn't match the resolved identity.
    /// - Parameters:
    ///   - expected: The resolved identity's pubkey hex.
    ///   - provided: The pubkey hex found in the event.
    case eventPubkeyMismatch(expected: String, provided: String)

    /// The requested operation kind is not yet implemented.
    case unsupportedOperation(SignerOperationKind)
}
