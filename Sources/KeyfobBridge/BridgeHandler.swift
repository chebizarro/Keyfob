import Foundation
import KeyfobCore
import KeyfobCrypto

public enum BridgeHandler {
    public static func handleUniversalLink(_ url: URL) -> URL? {
        do {
            let parsed = try URLRouter.parseUniversalLink(url)
            switch parsed.mode {
            case "pubkey":
                // Load pubkey from keychain (no sign)
                let pub = try KeyManager.shared.loadKeypair().pubkeyHex
                let result = URLRouter.CallbackResult(success: nil, sig: nil, pubkey: pub)
                return URLRouter.makeCallbackURL(cb: parsed.callback, result: result)
            case "sign":
                guard let evt = parsed.event else { return URLRouter.makeCallbackURL(cb: parsed.callback, result: .init(error: "invalid", msg: "Missing event")) }
                let orchestrator = SignOrchestrator()
                let resp = try orchestrator.prepareAndSign(event: evt, origin: parsed.origin, mode: .perRequest)
                let result = URLRouter.CallbackResult(success: resp.id, sig: resp.sig, pubkey: resp.pubkey)
                return URLRouter.makeCallbackURL(cb: parsed.callback, result: result)
            default:
                return URLRouter.makeCallbackURL(cb: parsed.callback, result: .init(error: "invalid", msg: "Unknown mode"))
            }
        } catch {
            // Fallback: try to encode error
            var cb = URL(string: "")
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                if let q = comps.queryItems?.first(where: { $0.name == "cb" })?.value, let u = URL(string: q) { cb = u }
            }
            if let cb = cb { return URLRouter.makeCallbackURL(cb: cb, result: .init(error: "invalid", msg: String(describing: error))) }
            return nil
        }
    }
}
