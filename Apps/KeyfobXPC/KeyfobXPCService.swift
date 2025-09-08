import Foundation
import KeyfobBridge
import KeyfobCore
import KeyfobCrypto
import KeyfobPolicy

// NOTE: To use this with an actual XPC target, create a separate XPC Service target in Xcode
// and set its principal class to this service entry point. This SwiftPM file is a scaffold.

public final class KeyfobXPCService: NSObject, KeyfobXPCProtocol {
    public func sign(eventJSON: Data, clientBundleID: String, originHint: String?, with reply: @escaping (Data?, NSError?) -> Void) {
        // Validate caller bundle ID against allowlist (placeholder)
        // TODO: Load allowlist from OriginRegistry and compare clientBundleID.
        do {
            let evt = try JSONDecoder().decode(NostrEvent.self, from: eventJSON)
            let origin = originHint ?? clientBundleID
            let resp = try SignOrchestrator().prepareAndSign(event: evt, origin: origin, mode: .perRequest)
            let data = try JSONEncoder().encode(resp)
            reply(data, nil)
        } catch {
            reply(nil, error as NSError)
        }
    }
}
