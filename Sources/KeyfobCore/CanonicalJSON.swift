import Foundation

/// Serialization utilities for Nostr events.
///
/// - `serializeEvent(_:)` produces a JSON **object** with sorted keys, suitable for display and consent previews.
///   This is NOT the NIP-01 id serialization format.
///
/// - The NIP-01 event id is computed from `[0,<pubkey>,<created_at>,<kind>,<tags>,<content>]` (array format).
///   That computation is handled by the SDK's `EventSerializer`, exposed via `Signer.computeNIP01Id()` in KeyfobCrypto.
public enum CanonicalJSON {
    /// Deterministic JSON object serialization for display purposes.
    /// Keys appear in alphabetical order: content, created_at, kind, pubkey, tags.
    ///
    /// **Note**: This is for human-readable display and consent previews only.
    /// For NIP-01 event id computation, use the array-format serialization in `Signer`.
    public static func serializeEvent(_ e: NostrEvent) throws -> String {
        // Stable key order: content, created_at, kind, pubkey, tags
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

    /// Escape a string per RFC 8259 JSON specification.
    /// All control characters (U+0000–U+001F) are properly escaped.
    internal static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                // Escape all other control characters (U+0000–U+001F) per RFC 8259
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.append(String(ch))
                }
            }
        }
        return out
    }
}
