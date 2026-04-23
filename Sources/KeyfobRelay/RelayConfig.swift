// ──────────────────────────────────────────────────────────────────
// RelayConfig.swift — Relay configuration with read/write roles
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Relay Role

/// The role a relay serves in the pool.
public enum RelayRole: String, Codable, Sendable, Equatable {
    /// Relay used for reading (subscriptions) only.
    case read
    /// Relay used for writing (publishing) only.
    case write
    /// Relay used for both reading and writing.
    case readWrite
}

// MARK: - Relay Config Entry

/// Configuration for a single relay in the pool.
public struct RelayConfigEntry: Codable, Sendable, Equatable, Identifiable {

    /// The relay WebSocket URL.
    public var url: URL

    /// The role this relay serves.
    public var role: RelayRole

    /// Whether this relay is currently enabled.
    public var isEnabled: Bool

    /// Unique identifier (derived from URL string).
    public var id: String { url.absoluteString }

    public init(url: URL, role: RelayRole = .readWrite, isEnabled: Bool = true) {
        self.url = url
        self.role = role
        self.isEnabled = isEnabled
    }

    /// Whether this relay accepts subscriptions (read or readWrite).
    public var canRead: Bool {
        isEnabled && (role == .read || role == .readWrite)
    }

    /// Whether this relay accepts publishes (write or readWrite).
    public var canWrite: Bool {
        isEnabled && (role == .write || role == .readWrite)
    }
}

// MARK: - Relay Pool Configuration

/// The full relay pool configuration, persistable as JSON.
public struct RelayPoolConfig: Codable, Sendable, Equatable {

    /// The configured relays.
    public var relays: [RelayConfigEntry]

    public init(relays: [RelayConfigEntry] = []) {
        self.relays = relays
    }

    /// Relays eligible for subscriptions.
    public var readRelays: [RelayConfigEntry] {
        relays.filter { $0.canRead }
    }

    /// Relays eligible for publishing.
    public var writeRelays: [RelayConfigEntry] {
        relays.filter { $0.canWrite }
    }

    /// All enabled relays.
    public var enabledRelays: [RelayConfigEntry] {
        relays.filter { $0.isEnabled }
    }

    /// Add a relay. No-op if URL already exists.
    public mutating func addRelay(url: URL, role: RelayRole = .readWrite) {
        guard !relays.contains(where: { $0.url == url }) else { return }
        relays.append(RelayConfigEntry(url: url, role: role))
    }

    /// Remove a relay by URL.
    @discardableResult
    public mutating func removeRelay(url: URL) -> Bool {
        let before = relays.count
        relays.removeAll { $0.url == url }
        return relays.count < before
    }

    /// Update the role for an existing relay.
    @discardableResult
    public mutating func setRole(url: URL, role: RelayRole) -> Bool {
        guard let idx = relays.firstIndex(where: { $0.url == url }) else { return false }
        relays[idx].role = role
        return true
    }

    /// Enable or disable a relay.
    @discardableResult
    public mutating func setEnabled(url: URL, enabled: Bool) -> Bool {
        guard let idx = relays.firstIndex(where: { $0.url == url }) else { return false }
        relays[idx].isEnabled = enabled
        return true
    }

    // MARK: - bunker:// URI Support

    /// Parse a bunker:// URI and extract relay URLs.
    ///
    /// Format: `bunker://<signer-pubkey>?relay=wss://relay1&relay=wss://relay2&secret=<token>`
    ///
    /// Returns the signer pubkey, relay URLs, and optional secret.
    public static func parseBunkerURI(_ uri: String) -> BunkerURIComponents? {
        guard let components = URLComponents(string: uri),
              components.scheme == "bunker",
              let host = components.host, !host.isEmpty else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let relayURLs = queryItems
            .filter { $0.name == "relay" }
            .compactMap { $0.value }
            .compactMap { URL(string: $0) }

        let secret = queryItems.first(where: { $0.name == "secret" })?.value

        return BunkerURIComponents(
            signerPubkey: host,
            relayURLs: relayURLs,
            secret: secret
        )
    }

    /// Create a pool config from a bunker:// URI.
    /// All relays from the URI are configured as readWrite.
    public static func fromBunkerURI(_ uri: String) -> (config: RelayPoolConfig, components: BunkerURIComponents)? {
        guard let components = parseBunkerURI(uri) else { return nil }
        let entries = components.relayURLs.map {
            RelayConfigEntry(url: $0, role: .readWrite)
        }
        return (RelayPoolConfig(relays: entries), components)
    }
}

// MARK: - Bunker URI Components

/// Parsed components from a bunker:// URI.
public struct BunkerURIComponents: Sendable, Equatable {
    /// The remote signer's pubkey (hex).
    public let signerPubkey: String
    /// Relay URLs to connect to.
    public let relayURLs: [URL]
    /// Optional secret/token for authentication.
    public let secret: String?

    public init(signerPubkey: String, relayURLs: [URL], secret: String? = nil) {
        self.signerPubkey = signerPubkey
        self.relayURLs = relayURLs
        self.secret = secret
    }
}
