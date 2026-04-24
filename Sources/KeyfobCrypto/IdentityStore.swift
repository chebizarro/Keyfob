//
//  IdentityStore.swift
//
//
//  Created for Keyfob – kf-3kr
//

import Foundation
import NostrSDK

/// Errors thrown by ``IdentityStore`` operations.
public enum IdentityStoreError: Error, Equatable {
    /// The app group container is unavailable (misconfigured entitlements).
    case appGroupUnavailable
    /// No identity exists with the given ID.
    case identityNotFound(UUID)
    /// An identity with this public key already exists.
    case duplicatePublicKey(String)
    /// The provided private key data is invalid.
    case invalidPrivateKey
    /// The metadata file could not be decoded.
    case metadataCorrupt(String)
    /// The metadata file could not be written.
    case metadataWriteFailed(String)
    /// A Keychain operation failed.
    case keychainError(OSStatus)
    /// The identity source is not valid for create (e.g. mnemonic/nip49 not yet supported).
    case unsupportedSourceForCreate(IdentitySource)
}

/// Protocol for managing multiple Nostr identities.
///
/// Each identity has its private key stored in the Keychain and its metadata
/// (public key, label, creation date, source) stored in a shared JSON file.
///
/// Implementations must be safe for single-process concurrent access.
/// Cross-process safety is handled by file locking in the concrete implementation.
public protocol IdentityStore: Sendable {

    // MARK: - CRUD

    /// Generate a new keypair and store it.
    /// - Parameters:
    ///   - label: Optional display label.
    ///   - makeActive: Whether to set this as the active identity (default: true).
    /// - Returns: The newly created ``Identity``.
    func createIdentity(label: String?, makeActive: Bool) throws -> Identity

    /// Import an existing private key.
    /// - Parameters:
    ///   - privateKeyHex: The 64-character hex-encoded private key.
    ///   - source: How the key was obtained (`.imported`, `.mnemonic`, etc.).
    ///   - label: Optional display label.
    ///   - makeActive: Whether to set this as the active identity (default: true).
    /// - Returns: The imported ``Identity``.
    func importIdentity(privateKeyHex: String, source: IdentitySource, label: String?, makeActive: Bool) throws -> Identity

    /// List all stored identities, sorted by creation date (oldest first).
    func listIdentities() throws -> [Identity]

    /// The currently active identity, or `nil` if none is set.
    func activeIdentity() throws -> Identity?

    /// Set the active identity by ID.
    /// - Parameter id: The UUID of the identity to activate, or `nil` to clear.
    func setActiveIdentity(_ id: UUID?) throws

    /// Delete an identity and its Keychain entry.
    /// If the deleted identity was active, the active identity is cleared.
    /// - Parameter id: The UUID of the identity to delete.
    func deleteIdentity(_ id: UUID) throws

    // MARK: - Key Access

    /// Load the full SDK `Keypair` for a given identity.
    /// May trigger biometric authentication.
    /// - Parameter identityID: The UUID of the identity.
    /// - Returns: The SDK ``NostrSDK/Keypair``.
    func loadSDKKeypair(for identityID: UUID) throws -> NostrSDK.Keypair

    // MARK: - Observation

    /// An `AsyncStream` that emits the active ``Identity`` whenever it changes.
    /// Yields the current active identity immediately upon subscription, then
    /// yields on every change (including cross-process changes via Darwin notifications).
    func observeActiveIdentity() -> AsyncStream<Identity?>
}

/// Convenience defaults for protocol methods with default parameter values.
public extension IdentityStore {
    func createIdentity(label: String? = nil, makeActive: Bool = true) throws -> Identity {
        try createIdentity(label: label, makeActive: makeActive)
    }

    func importIdentity(privateKeyHex: String, source: IdentitySource = .imported, label: String? = nil, makeActive: Bool = true) throws -> Identity {
        try importIdentity(privateKeyHex: privateKeyHex, source: source, label: label, makeActive: makeActive)
    }
}
