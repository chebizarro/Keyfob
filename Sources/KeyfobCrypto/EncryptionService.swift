//
//  EncryptionService.swift
//
//
//  Created for Keyfob – kf-0qn
//

import Foundation
import NostrSDK

// MARK: - EncryptionServiceError

/// Errors specific to ``EncryptionService`` operations.
public enum EncryptionServiceError: Error, Equatable {
    /// The peer public key is not a valid 64-character lowercase hex string.
    case invalidPeerPublicKey(String)
    /// The private key could not be used for encryption.
    case invalidPrivateKey
    /// NIP-44 encryption failed.
    case nip44EncryptionFailed(String)
    /// NIP-44 decryption failed.
    case nip44DecryptionFailed(String)
    /// NIP-04 (legacy) encryption failed.
    case nip04EncryptionFailed(String)
    /// NIP-04 (legacy) decryption failed.
    case nip04DecryptionFailed(String)
}

// MARK: - EncryptionService

/// Crypto executor for NIP-44 and NIP-04 encrypt/decrypt operations.
///
/// Wraps the SDK's ``NIP44v2Encrypting`` and ``LegacyDirectMessageEncrypting``
/// protocol default implementations with a clean API that accepts hex strings
/// and SDK ``Keypair`` types.
///
/// This service is stateless and designed to be injected into the
/// ``OperationPipeline`` as the crypto executor for `.nip44Encrypt`,
/// `.nip44Decrypt`, `.nip04Encrypt`, and `.nip04Decrypt` operations.
///
/// ## Usage
///
/// ```swift
/// let service = EncryptionService()
/// let keypair = try identityStore.loadSDKKeypair(for: identityID)
///
/// // NIP-44 encrypt
/// let ciphertext = try service.nip44Encrypt(
///     plaintext: "hello",
///     peerPubkeyHex: recipientPubkeyHex,
///     using: keypair
/// )
///
/// // NIP-44 decrypt
/// let plaintext = try service.nip44Decrypt(
///     payload: ciphertext,
///     peerPubkeyHex: senderPubkeyHex,
///     using: keypair
/// )
/// ```
public struct EncryptionService: NIP44v2Encrypting, LegacyDirectMessageEncrypting, Sendable {

    public init() {}

    // MARK: - NIP-44

    /// Encrypt plaintext for a peer using NIP-44 (XChaCha20-Poly1305 + HKDF).
    ///
    /// - Parameters:
    ///   - plaintext: The plaintext message to encrypt.
    ///   - peerPubkeyHex: The 64-character hex-encoded public key of the recipient.
    ///   - keypair: The sender's SDK ``Keypair`` (private key used for ECDH).
    /// - Returns: Base64-encoded NIP-44 payload.
    /// - Throws: ``EncryptionServiceError`` on validation or encryption failure.
    public func nip44Encrypt(plaintext: String, peerPubkeyHex: String, using keypair: NostrSDK.Keypair) throws -> String {
        let peerPublicKey = try resolvedPeerPublicKey(peerPubkeyHex)

        do {
            return try encrypt(plaintext: plaintext, privateKeyA: keypair.privateKey, publicKeyB: peerPublicKey)
        } catch {
            throw EncryptionServiceError.nip44EncryptionFailed(error.localizedDescription)
        }
    }

    /// Decrypt a NIP-44 payload from a peer.
    ///
    /// - Parameters:
    ///   - payload: Base64-encoded NIP-44 ciphertext.
    ///   - peerPubkeyHex: The 64-character hex-encoded public key of the sender.
    ///   - keypair: The recipient's SDK ``Keypair`` (private key used for ECDH).
    /// - Returns: The decrypted plaintext.
    /// - Throws: ``EncryptionServiceError`` on validation or decryption failure.
    public func nip44Decrypt(payload: String, peerPubkeyHex: String, using keypair: NostrSDK.Keypair) throws -> String {
        let peerPublicKey = try resolvedPeerPublicKey(peerPubkeyHex)

        do {
            return try decrypt(payload: payload, privateKeyA: keypair.privateKey, publicKeyB: peerPublicKey)
        } catch {
            throw EncryptionServiceError.nip44DecryptionFailed(error.localizedDescription)
        }
    }

    // MARK: - NIP-04 (Legacy)

    /// Encrypt content for a peer using legacy NIP-04 (AES-256-CBC).
    ///
    /// - Parameters:
    ///   - content: The plaintext content to encrypt.
    ///   - peerPubkeyHex: The 64-character hex-encoded public key of the recipient.
    ///   - keypair: The sender's SDK ``Keypair``.
    /// - Returns: NIP-04 formatted ciphertext (`base64?iv=base64`).
    /// - Throws: ``EncryptionServiceError`` on validation or encryption failure.
    ///
    /// > Warning: NIP-04 is deprecated in favor of NIP-44. Use only for backward
    /// > compatibility with clients that haven't migrated to NIP-44.
    @available(*, deprecated, message: "NIP-04 is deprecated. Use nip44Encrypt instead.")
    public func nip04Encrypt(content: String, peerPubkeyHex: String, using keypair: NostrSDK.Keypair) throws -> String {
        let peerPublicKey = try resolvedPeerPublicKey(peerPubkeyHex)

        do {
            return try legacyEncrypt(content: content, privateKey: keypair.privateKey, publicKey: peerPublicKey)
        } catch {
            throw EncryptionServiceError.nip04EncryptionFailed(error.localizedDescription)
        }
    }

    /// Decrypt NIP-04 ciphertext from a peer.
    ///
    /// - Parameters:
    ///   - encryptedContent: NIP-04 formatted ciphertext (`base64?iv=base64`).
    ///   - peerPubkeyHex: The 64-character hex-encoded public key of the sender.
    ///   - keypair: The recipient's SDK ``Keypair``.
    /// - Returns: The decrypted plaintext.
    /// - Throws: ``EncryptionServiceError`` on validation or decryption failure.
    ///
    /// > Warning: NIP-04 is deprecated in favor of NIP-44. Use only for backward
    /// > compatibility with clients that haven't migrated to NIP-44.
    @available(*, deprecated, message: "NIP-04 is deprecated. Use nip44Decrypt instead.")
    public func nip04Decrypt(encryptedContent: String, peerPubkeyHex: String, using keypair: NostrSDK.Keypair) throws -> String {
        let peerPublicKey = try resolvedPeerPublicKey(peerPubkeyHex)

        do {
            return try legacyDecrypt(encryptedContent: encryptedContent, privateKey: keypair.privateKey, publicKey: peerPublicKey)
        } catch {
            throw EncryptionServiceError.nip04DecryptionFailed(error.localizedDescription)
        }
    }

    // MARK: - NIP-04 Pipeline Compatibility

    // These methods provide the same functionality as the deprecated nip04*
    // methods but without the @available annotation, allowing the pipeline
    // to call them without generating deprecation warnings. NIP-04 support
    // is intentional for backward compatibility with legacy clients.

    /// Encrypt content for a peer using legacy NIP-04 (pipeline entry point).
    ///
    /// Functionally identical to ``nip04Encrypt(content:peerPubkeyHex:using:)``
    /// but not marked deprecated, since the pipeline intentionally supports NIP-04.
    public func legacyEncrypt(content: String, peerPubkeyHex: String, using keypair: NostrSDK.Keypair) throws -> String {
        let peerPublicKey = try resolvedPeerPublicKey(peerPubkeyHex)
        do {
            return try legacyEncrypt(content: content, privateKey: keypair.privateKey, publicKey: peerPublicKey)
        } catch {
            throw EncryptionServiceError.nip04EncryptionFailed(error.localizedDescription)
        }
    }

    /// Decrypt NIP-04 ciphertext from a peer (pipeline entry point).
    ///
    /// Functionally identical to ``nip04Decrypt(encryptedContent:peerPubkeyHex:using:)``
    /// but not marked deprecated, since the pipeline intentionally supports NIP-04.
    public func legacyDecrypt(encryptedContent: String, peerPubkeyHex: String, using keypair: NostrSDK.Keypair) throws -> String {
        let peerPublicKey = try resolvedPeerPublicKey(peerPubkeyHex)
        do {
            return try legacyDecrypt(encryptedContent: encryptedContent, privateKey: keypair.privateKey, publicKey: peerPublicKey)
        } catch {
            throw EncryptionServiceError.nip04DecryptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    /// Resolve and validate a peer public key hex string to an SDK ``PublicKey``.
    private func resolvedPeerPublicKey(_ hex: String) throws -> NostrSDK.PublicKey {
        // Enforce canonical 64-char lowercase hex (32 bytes).
        guard hex.count == 64,
              hex.allSatisfy({ $0.isHexDigit }),
              hex == hex.lowercased() else {
            throw EncryptionServiceError.invalidPeerPublicKey(hex)
        }

        guard let publicKey = NostrSDK.PublicKey(hex: hex) else {
            throw EncryptionServiceError.invalidPeerPublicKey(hex)
        }

        return publicKey
    }
}
