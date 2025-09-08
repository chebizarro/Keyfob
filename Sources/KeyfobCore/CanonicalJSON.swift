import Foundation

public enum CanonicalJSON {
    // Deterministic serialization for Nostr events
    public static func serializeEvent(_ e: NostrEvent) throws -> String {
        // Stable key order: content, created_at, kind, pubkey, tags
        let dict: [String: Any] = [
            "content": e.content,
            "created_at": e.created_at,
            "kind": e.kind,
            "pubkey": e.pubkey,
            "tags": e.tags
        ]
        // JSONSerialization is not guaranteed order; construct manually
        let tagsData = try JSONSerialization.data(withJSONObject: e.tags)
        let tagsStr = String(data: tagsData, encoding: .utf8)!
        let json = "{" +
        "\"content\":\"\(escape(e.content))\"," +
        "\"created_at\":\(e.created_at)," +
        "\"kind\":\(e.kind)," +
        "\"pubkey\":\"\(e.pubkey)\"," +
        "\"tags\":\(tagsStr)" +
        "}"
        return json
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                out.append(String(ch))
            }
        }
        return out
    }
}
