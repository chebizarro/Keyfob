import Foundation
import KeyfobBridge
import KeyfobCore
import KeyfobCrypto
import KeyfobPolicy

public final class KeyfobXPCService: NSObject, KeyfobXPCProtocol, NSXPCListenerDelegate {
    public func sign(eventJSON: Data, clientBundleID: String, originHint: String?, with reply: @escaping (Data?, NSError?) -> Void) {
        // Validate caller bundle ID against allowlist
        if !PolicyEngine.shared.isCallerAllowed(clientBundleID) {
            let err = NSError(domain: "KeyfobXPC", code: 403, userInfo: [NSLocalizedDescriptionKey: "Caller not allowed: \(clientBundleID)"])
            reply(nil, err)
            return
        }
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

    // NSXPCListenerDelegate
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: KeyfobXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    public static func run() {
        let listener = NSXPCListener.service()
        let service = KeyfobXPCService()
        listener.delegate = service
        listener.resume()
        // Never returns
    }
}
