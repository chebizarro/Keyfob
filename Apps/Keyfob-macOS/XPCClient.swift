import Foundation
import KeyfobCore

final class XPCClient {
    static let shared = XPCClient()
    private init() {}

    // Replace with your XPC service bundle identifier (also set in project signing)
    private let serviceName = "TODO.com.yourorg.keyfob.mac.xpc"

    func sign(event: NostrEvent, originHint: String? = nil, completion: @escaping (Result<SignatureResponse, Error>) -> Void) {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: KeyfobXPCProtocol.self)
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            completion(.failure(error))
            connection.invalidate()
        } as? KeyfobXPCProtocol

        do {
            let data = try JSONEncoder().encode(event)
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            proxy?.sign(eventJSON: data, clientBundleID: bundleID, originHint: originHint) { respData, err in
                defer { connection.invalidate() }
                if let err = err {
                    completion(.failure(err))
                    return
                }
                guard let respData = respData else {
                    completion(.failure(NSError(domain: "XPC", code: -1, userInfo: [NSLocalizedDescriptionKey: "empty response"])));
                    return
                }
                do {
                    let resp = try JSONDecoder().decode(SignatureResponse.self, from: respData)
                    completion(.success(resp))
                } catch {
                    completion(.failure(error))
                }
            }
        } catch {
            completion(.failure(error))
            connection.invalidate()
        }
    }
}
