import Foundation

@objc public protocol KeyfobXPCProtocol {
    func sign(eventJSON: Data, clientBundleID: String, originHint: String?, with reply: @escaping (Data?, NSError?) -> Void)
}

public struct XPCSignatureResponse: Codable {
    public let id: String
    public let sig: String
    public let pubkey: String
}
