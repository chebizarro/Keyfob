import Foundation

@objc public protocol KeyfobXPCProtocol {
    // Sign an event; returns JSON-encoded SignatureResponse
    func sign(eventJSON: Data, clientBundleID: String, originHint: String?, with reply: @escaping (Data?, NSError?) -> Void)
    // Get public key (hex) for current user
    func getPublicKey(clientBundleID: String, with reply: @escaping (String?, NSError?) -> Void)
}

public struct XPCSignatureResponse: Codable {
    public let id: String
    public let sig: String
    public let pubkey: String
}
