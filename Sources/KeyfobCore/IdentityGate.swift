//
//  IdentityGate.swift
//
//
//  Created for Keyfob – kf-28e
//
//  Pre-flight check for all IPC entry points: ensure an active identity exists
//  before attempting any crypto operation. Without this, missing-key errors
//  surface as low-level keychain/crypto failures instead of helpful messages.
//

import Foundation
import KeyfobCrypto

// MARK: - IdentityGateError

/// Error thrown when no active identity is configured.
///
/// IPC entry points (URL scheme, Universal Links, App Intent, XPC, Safari
/// extensions) should catch this error and present a user-visible message
/// directing them to create or import a key via onboarding.
public enum IdentityGateError: Error, Equatable, LocalizedError {
    /// No active identity is configured in Keyfob.
    case noActiveIdentity

    public var errorDescription: String? {
        switch self {
        case .noActiveIdentity:
            return "No active identity configured. Please open Keyfob and create or import a key."
        }
    }
}

// MARK: - IdentityGate

/// Guards IPC entry points by verifying an active identity exists.
///
/// Every IPC channel (URL scheme, Universal Links, App Intent, XPC, Safari
/// extension) should call one of these methods before performing crypto
/// operations. If no identity exists, a clear ``IdentityGateError/noActiveIdentity``
/// error is thrown instead of a cryptic keychain or signing failure.
///
/// ## Usage
///
/// **With IdentityStore (preferred):**
/// ```swift
/// try IdentityGate.requireActiveIdentity(store: identityStore)
/// // proceed with signing...
/// ```
///
/// **With shared provider (for entry points without direct store access):**
/// ```swift
/// // At app startup:
/// IdentityGate.configureSharedStore(myIdentityStore)
///
/// // At IPC entry point:
/// try IdentityGate.requireActiveIdentity()
/// ```
///
/// **Legacy KeyManager check:**
/// ```swift
/// try IdentityGate.requireLegacyKeypair()
/// ```
public enum IdentityGate {

    /// Shared store reference, set at app startup via ``configureSharedStore(_:)``.
    private static var _sharedStore: IdentityStore?
    private static let lock = NSLock()

    // MARK: - Configuration

    /// Configure the shared identity store for gate checks.
    ///
    /// Call this once at app startup (e.g. in `application(_:didFinishLaunchingWithOptions:)`
    /// or `@main App.init`). Must be called before any IPC entry point fires.
    ///
    /// - Parameter store: The identity store to use for active-identity checks.
    public static func configureSharedStore(_ store: IdentityStore) {
        lock.lock()
        defer { lock.unlock() }
        _sharedStore = store
    }

    /// The currently configured shared store, or `nil` if not yet configured.
    public static var sharedStore: IdentityStore? {
        lock.lock()
        defer { lock.unlock() }
        return _sharedStore
    }

    // MARK: - Gate Checks

    /// Require an active identity using the given store.
    ///
    /// - Parameter store: The identity store to check.
    /// - Throws: ``IdentityGateError/noActiveIdentity`` if no active identity exists.
    public static func requireActiveIdentity(store: IdentityStore) throws {
        let active = try store.activeIdentity()
        guard active != nil else {
            throw IdentityGateError.noActiveIdentity
        }
    }

    /// Require an active identity using the shared store.
    ///
    /// Falls back to the legacy ``KeyManager`` check if no shared store is configured.
    ///
    /// - Throws: ``IdentityGateError/noActiveIdentity`` if no active identity exists.
    public static func requireActiveIdentity() throws {
        if let store = sharedStore {
            try requireActiveIdentity(store: store)
        } else {
            try requireLegacyKeypair()
        }
    }

    /// Require a keypair via the legacy single-key ``KeyManager``.
    ///
    /// This is a fallback for code paths not yet migrated to multi-key
    /// ``IdentityStore``. It checks whether ``KeyManager`` can produce a
    /// keypair without triggering biometric auth — it only reads metadata.
    ///
    /// - Throws: ``IdentityGateError/noActiveIdentity`` if no key exists.
    public static func requireLegacyKeypair() throws {
        // Check if the shared store has identities (preferred)
        if let store = sharedStore {
            let identities = try store.listIdentities()
            guard !identities.isEmpty else {
                throw IdentityGateError.noActiveIdentity
            }
            return
        }

        // Last resort: try loading a keypair via legacy KeyManager
        // This may trigger biometric in some configurations.
        do {
            _ = try KeyManager.shared.loadKeypair()
        } catch {
            throw IdentityGateError.noActiveIdentity
        }
    }

    // MARK: - Convenience

    /// Check if an active identity exists (non-throwing).
    ///
    /// Useful for conditional UI: show onboarding vs main app.
    ///
    /// - Returns: `true` if an active identity is configured.
    public static func hasActiveIdentity() -> Bool {
        do {
            try requireActiveIdentity()
            return true
        } catch {
            return false
        }
    }

    /// Check if an active identity exists using the given store (non-throwing).
    public static func hasActiveIdentity(store: IdentityStore) -> Bool {
        do {
            try requireActiveIdentity(store: store)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Testing Support

    /// Reset the shared store (for testing only).
    internal static func resetSharedStore() {
        lock.lock()
        defer { lock.unlock() }
        _sharedStore = nil
    }
}
