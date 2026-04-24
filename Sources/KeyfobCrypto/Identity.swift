//
//  Identity.swift
//
//
//  Created for Keyfob – kf-3kr
//

import Foundation

/// How an identity's private key was provisioned.
public enum IdentitySource: String, Codable, Sendable {
    /// Generated fresh on-device.
    case generated
    /// Imported from an nsec / hex string.
    case imported
    /// Imported from a BIP-39 mnemonic (future).
    case mnemonic
    /// Imported from a NIP-49 encrypted export (future).
    case nip49
}

/// A Keyfob identity — the public metadata for one keypair.
///
/// Private keys are never stored in this struct; they live in the Keychain
/// and are accessed transiently via ``IdentityStore/loadSDKKeypair(for:)``.
public struct Identity: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier for this identity (not the Nostr pubkey).
    public let id: UUID

    /// 64-character lowercase hex x-only public key.
    public let pubkeyHex: String

    /// Optional user-chosen display label (e.g. "Main", "Burner").
    public var label: String?

    /// When this identity was first stored.
    public let createdAt: Date

    /// How the private key was provisioned.
    public let source: IdentitySource

    /// Whether this identity is the currently active one.
    ///
    /// This is a computed property derived from the store's `activeIdentityID`,
    /// not persisted per-record, to avoid multi-active / zero-active invalid states.
    /// It is set by ``KeychainIdentityStore`` when materializing results.
    public internal(set) var isActive: Bool

    public init(
        id: UUID = UUID(),
        pubkeyHex: String,
        label: String? = nil,
        createdAt: Date = Date(),
        source: IdentitySource,
        isActive: Bool = false
    ) {
        self.id = id
        self.pubkeyHex = pubkeyHex
        self.label = label
        self.createdAt = createdAt
        self.source = source
        self.isActive = isActive
    }

    // MARK: - Codable

    // `isActive` is excluded from coding — it's derived from activeIdentityID.
    private enum CodingKeys: String, CodingKey {
        case id, pubkeyHex, label, createdAt, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        pubkeyHex = try c.decode(String.self, forKey: .pubkeyHex)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        source = try c.decode(IdentitySource.self, forKey: .source)
        isActive = false // derived later
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(pubkeyHex, forKey: .pubkeyHex)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(source, forKey: .source)
    }
}
