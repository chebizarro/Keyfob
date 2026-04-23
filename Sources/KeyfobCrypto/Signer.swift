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
        let idHex = Signer.computeNIP01Id(
            pubkey: pubkeyHex,
            createdAt: Int64(evt.created_at),
            kind: evt.kind,
            tags: evt.tags,
            content: evt.content
        )

        // Sign using SDK's ContentSigning protocol (Schnorr over secp256k1)
        struct _SignerUtil: ContentSigning {}
        let sigHex = try _SignerUtil().signatureForContent(idHex, privateKey: sdkKeypair.privateKey.hex)

        return SignatureResponse(id: idHex, sig: sigHex, pubkey: pubkeyHex)
    }

    /// Compute the NIP-01 event id: SHA-256 of the canonical `[0, pubkey, created_at, kind, tags, content]` array.
    ///
    /// This is the authoritative id computation used for signing. The serialization follows NIP-01:
    /// compact JSON array with no extra whitespace.
    public static func computeNIP01Id(pubkey: String, createdAt: Int64, kind: Int, tags: [[String]], content: String) -> String {
        let ser = serializeNIP01(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
        let digest = SHA256.hash(data: ser.data(using: .utf8)!)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Produce the NIP-01 canonical serialization array string (before hashing).
    /// Exposed as internal for testability via @testable import.
    static func serializeNIP01(pubkey: String, createdAt: Int64, kind: Int, tags: [[String]], content: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let tagsString: String
        if let tagsData = try? encoder.encode(tags) {
            tagsString = String(data: tagsData, encoding: .utf8) ?? "[]"
        } else { tagsString = "[]" }
        let contentString: String
        if let cdata = try? encoder.encode(content) { contentString = String(data: cdata, encoding: .utf8) ?? "\"\"" } else { contentString = "\"\"" }
        return "[0,\"\(pubkey)\",\(createdAt),\(kind),\(tagsString),\(contentString)]"
    }
}
