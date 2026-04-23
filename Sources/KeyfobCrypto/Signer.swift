import Foundation
import CryptoKit
import NostrSDK

public struct SignatureResponse: Codable, Equatable {
    public let id: String
    public let sig: String
    public let pubkey: String
}

public enum SignerError: Error {
    case invalidEvent
    case keyLoadFailed
}

public final class Signer {
    public init() {}

    private struct MinimalEvent: Codable {
        let kind: Int
        let pubkey: String?
        let created_at: Int
        let tags: [[String]]
        let content: String
    }

    // MARK: - Signing

    /// Sign a Nostr event using the default Keychain identity.
    ///
    /// Loads the SDK `Keypair` from the Keychain (may trigger biometric auth),
    /// computes the NIP-01 event id, and produces a Schnorr signature.
    public func signEvent(eventJSON: String) throws -> SignatureResponse {
        let sdkKeypair = try KeyManager.shared.loadSDKKeypair()
        return try signEvent(eventJSON: eventJSON, with: sdkKeypair)
    }

    /// Sign a Nostr event using a provided SDK `Keypair`.
    ///
    /// Use this overload when you already have the keypair (e.g., after biometric
    /// authentication) to avoid redundant Keychain access.
    public func signEvent(eventJSON: String, with sdkKeypair: NostrSDK.Keypair) throws -> SignatureResponse {
        guard let data = eventJSON.data(using: .utf8) else { throw SignerError.invalidEvent }
        let evt = try JSONDecoder().decode(MinimalEvent.self, from: data)

        let pubkeyHex = sdkKeypair.publicKey.hex
        let sdkTags = Signer.tagsToSDK(evt.tags)
        let idHex = EventSerializer.identifierForEvent(
            withPubkey: pubkeyHex,
            createdAt: Int64(evt.created_at),
            kind: evt.kind,
            tags: sdkTags,
            content: evt.content
        )

        struct _Signing: ContentSigning {}
        let sigHex = try _Signing().signatureForContent(idHex, privateKey: sdkKeypair.privateKey.hex)
        return SignatureResponse(id: idHex, sig: sigHex, pubkey: pubkeyHex)
    }

    /// Sign a `KeyfobCore.NostrEvent` directly, avoiding the JSON parse round-trip.
    ///
    /// Computes the NIP-01 event id from the event fields using SDK's `EventSerializer`,
    /// then produces a Schnorr signature using the provided keypair.
    public func signEvent(kind: Int, createdAt: Int, tags: [[String]], content: String, with sdkKeypair: NostrSDK.Keypair) throws -> SignatureResponse {
        let pubkeyHex = sdkKeypair.publicKey.hex
        let sdkTags = Signer.tagsToSDK(tags)
        let idHex = EventSerializer.identifierForEvent(
            withPubkey: pubkeyHex,
            createdAt: Int64(createdAt),
            kind: kind,
            tags: sdkTags,
            content: content
        )

        struct _Signing: ContentSigning {}
        let sigHex = try _Signing().signatureForContent(idHex, privateKey: sdkKeypair.privateKey.hex)
        return SignatureResponse(id: idHex, sig: sigHex, pubkey: pubkeyHex)
    }

    // MARK: - NIP-01 Serialization (delegating to SDK EventSerializer)

    /// Compute the NIP-01 event id: SHA-256 of the canonical serialized event.
    ///
    /// Delegates to SDK's `EventSerializer.identifierForEvent()`.
    public static func computeNIP01Id(pubkey: String, createdAt: Int64, kind: Int, tags: [[String]], content: String) -> String {
        let sdkTags = tagsToSDK(tags)
        return EventSerializer.identifierForEvent(
            withPubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: sdkTags,
            content: content
        )
    }

    /// Produce the NIP-01 canonical serialization: `[0,<pubkey>,<created_at>,<kind>,<tags>,<content>]`.
    ///
    /// Delegates to SDK's `EventSerializer.serializedEvent()`.
    static func serializeNIP01(pubkey: String, createdAt: Int64, kind: Int, tags: [[String]], content: String) -> String {
        let sdkTags = tagsToSDK(tags)
        return EventSerializer.serializedEvent(
            withPubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: sdkTags,
            content: content
        )
    }

    // MARK: - Tag Conversion

    /// Convert `[[String]]` tags to SDK `[Tag]` via JSON round-trip.
    ///
    /// SDK's `Tag.init` is module-internal, so we encode `[[String]]` and decode as `[Tag]`.
    /// Tag's Codable implementation uses an unkeyed container: `["name", "value", ...otherParams]`,
    /// which is identical to `[String]` encoding, so the round-trip is lossless.
    ///
    /// Tags with fewer than 2 elements are padded with empty strings to satisfy the SDK's decoder
    /// (which requires at least a name and a value). Empty tags are dropped.
    ///
    /// Performance: negligible for typical event tag counts (< 100 tags).
    public static func tagsToSDK(_ tags: [[String]]) -> [NostrSDK.Tag] {
        guard !tags.isEmpty else { return [] }
        // SDK Tag decoder requires at least 2 elements (name + value).
        // Pad short tags with empty strings to preserve them in serialization.
        let normalizedTags = tags.compactMap { tag -> [String]? in
            guard !tag.isEmpty else { return nil }
            if tag.count < 2 {
                return tag + Array(repeating: "", count: 2 - tag.count)
            }
            return tag
        }
        guard !normalizedTags.isEmpty else { return [] }
        guard let data = try? JSONEncoder().encode(normalizedTags),
              let sdkTags = try? JSONDecoder().decode([NostrSDK.Tag].self, from: data) else {
            return []
        }
        return sdkTags
    }

    /// Convert SDK `[Tag]` back to `[[String]]` via JSON round-trip.
    public static func tagsFromSDK(_ sdkTags: [NostrSDK.Tag]) -> [[String]] {
        guard !sdkTags.isEmpty else { return [] }
        guard let data = try? JSONEncoder().encode(sdkTags),
              let rawTags = try? JSONDecoder().decode([[String]].self, from: data) else {
            return []
        }
        return rawTags
    }
}
