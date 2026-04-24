//
//  KeyManagementService.swift
//
//
//  Created for Keyfob – kf-tiu
//
//  Service layer for key management UI operations: list, rename, activate,
//  copy, delete identities. Bridges IdentityStore (KeyfobCrypto) with
//  UI-consumable types so KeyfobUI doesn't need to import KeyfobCrypto.
//

import Foundation
import KeyfobCrypto

// MARK: - IdentityViewModel

/// A UI-ready view model for a single identity.
///
/// Contains all display strings the key management UI needs,
/// without requiring the UI to import KeyfobCrypto directly.
public struct IdentityViewModel: Identifiable, Equatable, Sendable {
    /// The stable identity UUID.
    public let id: UUID

    /// 64-character hex public key.
    public let pubkeyHex: String

    /// User-assigned label (may be nil).
    public let label: String?

    /// Truncated npub for compact display (e.g. `npub1abcd…wxyz`).
    public let npubTruncated: String

    /// Full npub string for copy/share.
    public let npubFull: String

    /// How the key was provisioned (e.g. "generated", "imported", "nip49").
    public let source: String

    /// Whether this is the currently active identity.
    public let isActive: Bool

    /// When this identity was created.
    public let createdAt: Date

    /// User-friendly display name: label if set, otherwise truncated npub.
    public var displayName: String {
        if let label = label, !label.isEmpty {
            return label
        }
        return npubTruncated
    }

    public init(
        id: UUID,
        pubkeyHex: String,
        label: String?,
        npubTruncated: String,
        npubFull: String,
        source: String,
        isActive: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.pubkeyHex = pubkeyHex
        self.label = label
        self.npubTruncated = npubTruncated
        self.npubFull = npubFull
        self.source = source
        self.isActive = isActive
        self.createdAt = createdAt
    }
}

// MARK: - KeyManagementError

/// Errors from key management operations.
public enum KeyManagementError: Error, Equatable, LocalizedError {
    /// The identity was not found.
    case identityNotFound(UUID)
    /// The operation failed.
    case operationFailed(String)
    /// Cannot delete the only remaining identity.
    case cannotDeleteLastIdentity

    public var errorDescription: String? {
        switch self {
        case .identityNotFound(let id):
            return "Identity not found: \(id)"
        case .operationFailed(let msg):
            return msg
        case .cannotDeleteLastIdentity:
            return "Cannot delete the only remaining identity. Create or import another key first."
        }
    }
}

// MARK: - KeyManagementService

/// Coordinates key management UI operations.
///
/// Provides CRUD operations on identities, returning ``IdentityViewModel``
/// structs ready for SwiftUI binding.
///
/// ## Usage
///
/// ```swift
/// let service = KeyManagementService(identityStore: store)
///
/// // List all identities
/// let identities = try service.listIdentities()
///
/// // Rename
/// try service.renameIdentity(id: identity.id, newLabel: "Work")
///
/// // Set active
/// try service.setActiveIdentity(id: identity.id)
///
/// // Delete (with safety check)
/// try service.deleteIdentity(id: identity.id)
/// ```
public final class KeyManagementService: @unchecked Sendable {

    private let identityStore: IdentityStore

    public init(identityStore: IdentityStore) {
        self.identityStore = identityStore
    }

    // MARK: - List

    /// List all identities as view models, sorted by creation date.
    public func listIdentities() throws -> [IdentityViewModel] {
        try identityStore.listIdentities().map { viewModel(from: $0) }
    }

    /// Get the currently active identity, if any.
    public func activeIdentity() throws -> IdentityViewModel? {
        guard let identity = try identityStore.activeIdentity() else { return nil }
        return viewModel(from: identity)
    }

    // MARK: - Rename

    /// Rename an identity by updating its label.
    ///
    /// - Parameters:
    ///   - id: The identity UUID.
    ///   - newLabel: The new label (empty string clears the label).
    /// - Throws: ``KeyManagementError`` on failure.
    public func renameIdentity(id: UUID, newLabel: String) throws {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try identityStore.updateLabel(for: id, label: label.isEmpty ? nil : label)
        } catch {
            throw KeyManagementError.operationFailed(error.localizedDescription)
        }
    }

    // MARK: - Set Active

    /// Set the active identity.
    ///
    /// - Parameter id: The UUID of the identity to activate.
    /// - Throws: ``KeyManagementError`` on failure.
    public func setActiveIdentity(id: UUID) throws {
        do {
            try identityStore.setActiveIdentity(id)
        } catch {
            throw KeyManagementError.operationFailed(error.localizedDescription)
        }
    }

    // MARK: - Delete

    /// Delete an identity.
    ///
    /// Prevents deleting the last remaining identity (user would be locked out).
    ///
    /// - Parameter id: The UUID of the identity to delete.
    /// - Throws: ``KeyManagementError`` on failure.
    public func deleteIdentity(id: UUID) throws {
        let identities = try identityStore.listIdentities()
        guard identities.count > 1 else {
            throw KeyManagementError.cannotDeleteLastIdentity
        }

        do {
            try identityStore.deleteIdentity(id)
        } catch {
            throw KeyManagementError.operationFailed(error.localizedDescription)
        }
    }

    // MARK: - Copy Strings

    /// Get the full npub string for clipboard copy.
    public func npubForCopy(pubkeyHex: String) -> String {
        KeyClipboard.npubForCopy(pubkeyHex)
    }

    /// Get the hex string for clipboard copy.
    public func hexForCopy(pubkeyHex: String) -> String {
        KeyClipboard.hexForCopy(pubkeyHex)
    }

    // MARK: - Private

    private func viewModel(from identity: Identity) -> IdentityViewModel {
        IdentityViewModel(
            id: identity.id,
            pubkeyHex: identity.pubkeyHex,
            label: identity.label,
            npubTruncated: identity.truncatedNpub,
            npubFull: identity.npub ?? identity.pubkeyHex,
            source: identity.source.rawValue,
            isActive: identity.isActive,
            createdAt: identity.createdAt
        )
    }
}
