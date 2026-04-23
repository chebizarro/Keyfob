// ──────────────────────────────────────────────────────────────────
// RelayAuth.swift — NIP-42 relay authentication
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Auth State

/// Authentication state for a relay connection (NIP-42).
public enum AuthState: Sendable, Equatable {
    /// Relay has not sent an AUTH challenge.
    case notRequired
    /// Relay sent an AUTH challenge; awaiting signer.
    case challenged(String)
    /// Signed auth event sent; awaiting relay OK.
    case authenticating
    /// Relay accepted the auth event (OK true).
    case authenticated
    /// Relay rejected the auth event, or signing failed.
    case failed(String)
}

// MARK: - Relay Auth Signer Protocol

/// Protocol for signing NIP-42 authentication events.
///
/// Implement this to provide signing without a hard dependency
/// on any specific crypto module (e.g., KeyfobCrypto).
///
/// The signer must construct a **complete, signed kind 22242 event**:
///
/// | Field        | Value                                                   |
/// |--------------|---------------------------------------------------------|
/// | `kind`       | `22242`                                                 |
/// | `tags`       | `[["relay", <relayURL>], ["challenge", <challenge>]]`   |
/// | `content`    | `""`                                                    |
/// | `created_at` | Current unix timestamp                                  |
/// | `pubkey`     | Signer's public key (hex)                               |
/// | `id`         | NIP-01 event id (SHA-256 of canonical serialization)    |
/// | `sig`        | Schnorr signature (hex)                                 |
///
/// Example implementation:
/// ```swift
/// struct MyAuthSigner: RelayAuthSigner {
///     let keyPair: KeyPair
///     func signAuthEvent(challenge: String, relayURL: URL) async throws -> RelayEvent {
///         let tags = [["relay", relayURL.absoluteString], ["challenge", challenge]]
///         return try keyPair.signEvent(kind: 22242, tags: tags, content: "")
///     }
/// }
/// ```
public protocol RelayAuthSigner: Sendable {
    /// Sign a NIP-42 auth event for the given relay and challenge.
    ///
    /// - Parameters:
    ///   - challenge: The challenge string from the relay's AUTH frame.
    ///   - relayURL: The relay URL (used in the `relay` tag).
    /// - Returns: A fully signed `RelayEvent` with kind 22242.
    func signAuthEvent(challenge: String, relayURL: URL) async throws -> RelayEvent
}

// MARK: - Auth Errors

public enum RelayAuthError: Error, Equatable {
    /// No `RelayAuthSigner` configured on the connection.
    case noSigner
    /// Auth is already in progress or completed.
    case authAlreadyInProgress
    /// The signer failed to produce a valid auth event.
    case signingFailed(String)
    /// The relay rejected the auth event.
    case authRejected(String)
}
