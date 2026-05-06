import Foundation

public struct NostrEvent: Codable, Equatable, Sendable {
    public var kind: Int
    public var pubkey: String
    public var created_at: Int
    public var tags: [[String]]
    public var content: String
    public var id: String?
    public var sig: String?

    public init(kind: Int, pubkey: String, created_at: Int, tags: [[String]], content: String, id: String? = nil, sig: String? = nil) {
        self.kind = kind
        self.pubkey = pubkey
        self.created_at = created_at
        self.tags = tags
        self.content = content
        self.id = id
        self.sig = sig
    }
}

public enum EventError: Error {
    case invalid
}
