import Foundation
import KeyfobCore

public enum URLRouterError: Error { case invalid, tooLarge }

public struct URLRouter {
    public static let scheme = "keyfob"
    public static let maxPayload = 16 * 1024 // 16 KB cap

    public static func parse(_ url: URL) throws -> (event: NostrEvent, callback: URL, origin: String) {
        guard url.scheme == scheme, url.host == "sign" else { throw URLRouterError.invalid }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLRouterError.invalid }
        var payloadB64 = ""
        var cbStr = ""
        var origin = ""
        for item in comps.queryItems ?? [] {
            switch item.name {
            case "payload": payloadB64 = item.value ?? ""
            case "cb": cbStr = item.value ?? ""
            case "origin": origin = item.value ?? ""
            default: break
            }
        }
        guard let data = Data(base64Encoded: payloadB64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")) else { throw URLRouterError.invalid }
        guard data.count <= maxPayload else { throw URLRouterError.tooLarge }
        let evt = try JSONDecoder().decode(NostrEvent.self, from: data)
        guard let cb = URL(string: cbStr) else { throw URLRouterError.invalid }
        return (evt, cb, origin)
    }
}
