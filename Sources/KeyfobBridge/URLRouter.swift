import Foundation
import KeyfobCore

public enum URLRouterError: Error { case invalid, tooLarge }

public struct URLRouter {
    public static let scheme = "keyfob"
    public static let maxPayload = 16 * 1024 // 16 KB cap
    public static let ulHost = "keyfob.example.com" // TODO: replace

    private static func decodeBase64URL(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = str.count % 4
        if rem == 2 { str += "==" }
        else if rem == 3 { str += "=" }
        else if rem != 0 && rem != 0 { /* no-op */ }
        return Data(base64Encoded: str)
    }

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
        guard let data = decodeBase64URL(payloadB64) else { throw URLRouterError.invalid }
        guard data.count <= maxPayload else { throw URLRouterError.tooLarge }
        let evt = try JSONDecoder().decode(NostrEvent.self, from: data)
        guard let cb = URL(string: cbStr) else { throw URLRouterError.invalid }
        return (evt, cb, origin)
    }

    public static func parseUniversalLink(_ url: URL) throws -> (mode: String, event: NostrEvent?, callback: URL, origin: String) {
        // https://keyfob.example.com/app/sign?payload=...&cb=...&origin=...
        // https://keyfob.example.com/app/pubkey?cb=...&origin=...
        guard url.scheme == "https", url.host == ulHost else { throw URLRouterError.invalid }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLRouterError.invalid }
        let path = comps.path
        var cbStr = ""
        var origin = ""
        var payloadB64 = ""
        for item in comps.queryItems ?? [] {
            switch item.name {
            case "cb": cbStr = item.value ?? ""
            case "origin": origin = item.value ?? ""
            case "payload": payloadB64 = item.value ?? ""
            default: break
            }
        }
        guard let cb = URL(string: cbStr) else { throw URLRouterError.invalid }
        if path.hasSuffix("/sign") {
            guard let data = decodeBase64URL(payloadB64) else { throw URLRouterError.invalid }
            guard data.count <= maxPayload else { throw URLRouterError.tooLarge }
            let evt = try JSONDecoder().decode(NostrEvent.self, from: data)
            return ("sign", evt, cb, origin)
        } else if path.hasSuffix("/pubkey") {
            return ("pubkey", nil, cb, origin)
        } else {
            throw URLRouterError.invalid
        }
    }

    public struct CallbackResult: Codable {
        public let ok: Int
        public let id: String?
        public let sig: String?
        public let pubkey: String?
        public let code: String?
        public let msg: String?
        public init(success id: String?, sig: String?, pubkey: String?) {
            self.ok = 1; self.id = id; self.sig = sig; self.pubkey = pubkey; self.code = nil; self.msg = nil
        }
        public init(error code: String, msg: String) {
            self.ok = 0; self.id = nil; self.sig = nil; self.pubkey = nil; self.code = code; self.msg = msg
        }
    }

    public static func makeCallbackURL(cb: URL, result: CallbackResult) -> URL? {
        var comps = URLComponents(url: cb, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "ok", value: String(result.ok)))
        if let id = result.id { items.append(URLQueryItem(name: "id", value: id)) }
        if let sig = result.sig { items.append(URLQueryItem(name: "sig", value: sig)) }
        if let pk = result.pubkey { items.append(URLQueryItem(name: "pubkey", value: pk)) }
        if let code = result.code { items.append(URLQueryItem(name: "code", value: code)) }
        if let msg = result.msg { items.append(URLQueryItem(name: "msg", value: msg)) }
        comps?.queryItems = items
        return comps?.url
    }
}
