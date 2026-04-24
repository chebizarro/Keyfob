//
//  ClientIdentity.swift
//
//
//  Created for Keyfob – kf-92b
//

import Foundation

// MARK: - ClientIdentity

/// A registered client that has interacted with Keyfob.
///
/// Each client is identified by a canonical `id` (typically a bundle ID for native
/// apps or an origin domain for web callers). The model tracks when the client
/// was first and last seen, which ``Channel`` it used, and an optional display name.
///
/// Persisted in the ``ClientRegistry`` for policy evaluation, permission rules,
/// and audit display.
public struct ClientIdentity: Codable, Equatable, Sendable, Identifiable {

    /// Canonical client identifier.
    ///
    /// For native apps: the bundle ID (e.g. `"com.example.nostr"`).
    /// For web callers: the origin domain (e.g. `"example.com"`).
    /// For NIP-46: the remote signer pubkey hex.
    public let id: String

    /// Optional human-readable name for UI display (e.g. app name, website title).
    public var displayName: String?

    /// When this client first interacted with Keyfob.
    public let firstSeen: Date

    /// When this client last interacted with Keyfob.
    public var lastSeen: Date

    /// The IPC channel this client uses.
    public let channel: Channel

    public init(
        id: String,
        displayName: String? = nil,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        channel: Channel
    ) {
        self.id = id
        self.displayName = displayName
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.channel = channel
    }

    /// A user-friendly name: the display name if set, otherwise the id.
    public var effectiveDisplayName: String {
        if let name = displayName, !name.isEmpty {
            return name
        }
        return id
    }
}

// MARK: - ClientRegistryError

/// Errors from ``ClientRegistry`` operations.
public enum ClientRegistryError: Error, Equatable {
    /// The client was not found.
    case clientNotFound(String)
    /// The registry storage is unavailable.
    case storageUnavailable(String)
    /// The registry data is corrupt.
    case dataCorrupt(String)
}

// MARK: - ClientRegistry Protocol

/// Protocol for managing registered clients.
///
/// Clients are auto-registered on first IPC contact and tracked for policy
/// evaluation and UI display. The registry is the persistent counterpart to
/// the transient ``ClientContext`` that flows through the pipeline.
public protocol ClientRegistry: Sendable {

    /// Register a new client or update an existing one.
    ///
    /// If a client with the same `id` already exists, updates `lastSeen`
    /// and optionally `displayName`. Otherwise creates a new record.
    ///
    /// - Parameter context: The ``ClientContext`` from the current request.
    /// - Returns: The registered or updated ``ClientIdentity``.
    @discardableResult
    func registerOrUpdate(from context: ClientContext) throws -> ClientIdentity

    /// Look up a client by its identifier.
    ///
    /// - Parameter id: The client identifier.
    /// - Returns: The ``ClientIdentity`` if found, `nil` otherwise.
    func lookup(id: String) throws -> ClientIdentity?

    /// List all registered clients, sorted by last seen (most recent first).
    func listClients() throws -> [ClientIdentity]

    /// Remove a client registration.
    ///
    /// - Parameter id: The client identifier to remove.
    func remove(id: String) throws
}
