import Foundation

public struct NostrEvent: Codable, Equatable {
    public var kind: Int
    public var pubkey: String
    public var created_at: Int
    public var tags: [[String]]
    public var content: String
    public var id: String?
    public var sig: String?
}

public enum EventError: Error {
    case invalid
}
