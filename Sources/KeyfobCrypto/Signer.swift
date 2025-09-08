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

    public func signEvent(eventJSON: String) throws -> SignatureResponse {
        guard let data = eventJSON.data(using: .utf8) else { throw SignerError.invalidEvent }
        let evt = try JSONDecoder().decode(MinimalEvent.self, from: data)
        // Load private key (biometry-gated)
        let skData = try KeyManager.shared.readPrivateKeyWithBiometrics()
        guard let priv = NostrSDK.PrivateKey(dataRepresentation: skData), let kp = NostrSDK.Keypair(privateKey: priv) else {
            throw SignerError.keyLoadFailed
        }
        let idHex = Self.computeNIP01Id(pubkey: kp.publicKey.hex, createdAt: Int64(evt.created_at), kind: evt.kind, tags: evt.tags, content: evt.content)
        struct _SignerUtil: ContentSigning {}
        let sigHex = try _SignerUtil().signatureForContent(idHex, privateKey: priv.hex)
        return SignatureResponse(id: idHex, sig: sigHex, pubkey: kp.publicKey.hex)
    }

    private static func computeNIP01Id(pubkey: String, createdAt: Int64, kind: Int, tags: [[String]], content: String) -> String {
        // Serialize as compact JSON array per NIP-01
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let tagsString: String
        if let tagsData = try? encoder.encode(tags) {
            tagsString = String(data: tagsData, encoding: .utf8) ?? "[]"
        } else { tagsString = "[]" }
        let contentString: String
        if let cdata = try? encoder.encode(content) { contentString = String(data: cdata, encoding: .utf8) ?? "\"\"" } else { contentString = "\"\"" }
        let ser = "[0,\"\(pubkey)\",\(createdAt),\(kind),\(tagsString),\(contentString)]"
        let digest = SHA256.hash(data: ser.data(using: .utf8)!)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
