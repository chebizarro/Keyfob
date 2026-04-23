import SafariServices
import Foundation
import os.log

private let log = OSLog(subsystem: "com.keyfob.safari-extension", category: "handler")

final class SafariExtensionHandler: SFSafariExtensionHandler {
    // Reads from Info.plist key KEYFOB_XPC_SERVICE_NAME, set via Keyfob.xcconfig.
    private let xpcServiceName: String = {
        if let override = Bundle.main.infoDictionary?["KEYFOB_XPC_SERVICE_NAME"] as? String, !override.isEmpty {
            return override
        }
        return "com.example.keyfob.mac.xpc"
    }()

    override func messageReceived(withName messageName: String, from page: SFSafariPage, userInfo: [String : Any]?) {
        let reqId = (userInfo?["reqId"] as? String) ?? ""
        switch messageName {
        case "keyfob_getPublicKey":
            getPublicKey { result in
                self.reply(name: "keyfob_response", to: page, payload: [
                    "ok": result.ok,
                    "pubkey": result.pubkey ?? "",
                    "msg": result.msg ?? "",
                    "reqId": reqId
                ])
            }
        case "keyfob_signEvent":
            guard let eventJSON = userInfo?["eventJSON"] as? String else {
                reply(name: "keyfob_response", to: page, payload: ["ok": 0, "msg": "missing eventJSON", "reqId": reqId])
                return
            }
            sign(eventJSON: eventJSON) { result in
                self.reply(name: "keyfob_response", to: page, payload: [
                    "ok": result.ok,
                    "id": result.id ?? "",
                    "sig": result.sig ?? "",
                    "pubkey": result.pubkey ?? "",
                    "msg": result.msg ?? "",
                    "reqId": reqId
                ])
            }
        default:
            os_log(.error, log: log, "[Keyfob] unrecognized message name: %{public}@, reqId=%{public}@", messageName, reqId)
            break
        }
    }

    private func reply(name: String, to page: SFSafariPage, payload: [String: Any]) {
        page.dispatchMessageToScript(withName: name, userInfo: payload)
    }

    private func getPublicKey(completion: @escaping (ResultPayload) -> Void) {
        let connection = NSXPCConnection(serviceName: xpcServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: KeyfobXPCProtocol.self)
        connection.resume()
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            os_log(.error, log: log, "[Keyfob] getPublicKey XPC proxy error: %{public}@", error.localizedDescription)
            completion(.err("xpc: \(error.localizedDescription)"))
            connection.invalidate()
        } as? KeyfobXPCProtocol
        proxy?.getPublicKey(clientBundleID: bundleID) { pubkey, err in
            defer { connection.invalidate() }
            if let err = err {
                os_log(.error, log: log, "[Keyfob] getPublicKey XPC call error: %{public}@", err.localizedDescription)
                completion(.err(err.localizedDescription))
                return
            }
            completion(.pubkey(pubkey ?? ""))
        }
    }

    private func sign(eventJSON: String, completion: @escaping (ResultPayload) -> Void) {
        guard let data = eventJSON.data(using: .utf8) else { completion(.err("bad json")); return }
        let connection = NSXPCConnection(serviceName: xpcServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: KeyfobXPCProtocol.self)
        connection.resume()
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            os_log(.error, log: log, "[Keyfob] sign XPC proxy error: %{public}@", error.localizedDescription)
            completion(.err("xpc: \(error.localizedDescription)"))
            connection.invalidate()
        } as? KeyfobXPCProtocol
        proxy?.sign(eventJSON: data, clientBundleID: bundleID, originHint: nil) { respData, err in
            defer { connection.invalidate() }
            if let err = err {
                os_log(.error, log: log, "[Keyfob] sign XPC call error: %{public}@", err.localizedDescription)
                completion(.err(err.localizedDescription))
                return
            }
            guard let respData = respData else { completion(.err("empty response")); return }
            do {
                let resp = try JSONDecoder().decode(SignatureResponse.self, from: respData)
                completion(.sig(resp.id, resp.sig, resp.pubkey))
            } catch {
                completion(.err(error.localizedDescription))
            }
        }
    }
}

private enum ResultPayload {
    case pubkey(String)
    case sig(String, String, String)
    case err(String)

    var ok: Int { if case .err = self { return 0 } else { return 1 } }
    var pubkey: String? { if case .pubkey(let p) = self { return p } else if case .sig(_, _, let p) = self { return p } else { return nil } }
    var id: String? { if case .sig(let id, _, _) = self { return id } else { return nil } }
    var sig: String? { if case .sig(_, let s, _) = self { return s } else { return nil } }
    var msg: String? { if case .err(let m) = self { return m } else { return nil } }
}
