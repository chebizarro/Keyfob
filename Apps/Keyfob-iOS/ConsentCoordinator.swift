import Foundation
import UIKit
import SwiftUI
import KeyfobPolicy
import KeyfobCore
import KeyfobUI
import KeyfobCrypto
import LocalAuthentication

final class ConsentCoordinator: NSObject, PolicyEngine.ConsentProvider {
    static let shared = ConsentCoordinator()
    private override init() {}

    func requestConsent(origin: String, eventPreview: String, mode: PolicyEngine.ConsentMode) throws {
        // Present a blocking consent sheet and wait for user selection
        let sem = DispatchSemaphore(value: 0)
        var approved = false
        var presentError: Error?

        DispatchQueue.main.async {
            // Decode the preview back into an event for UI. If it fails, show minimal content.
            let event: NostrEvent
            if let data = eventPreview.data(using: .utf8), let ev = try? JSONDecoder().decode(NostrEvent.self, from: data) {
                event = ev
            } else {
                event = NostrEvent(kind: 0, pubkey: "", created_at: Int(Date().timeIntervalSince1970), tags: [], content: eventPreview, id: nil, sig: nil)
            }

            guard let presenter = Self.topViewController() else {
                presentError = NSError(domain: "Consent", code: -1, userInfo: [NSLocalizedDescriptionKey: "No presenter available"])
                sem.signal()
                return
            }

            let host = UIHostingController(rootView: ConsentView(origin: origin, event: event, onApprove: { decision in
                // If user requested a session (Mode B), require biometry before approval
                if decision.useSession {
                    let ctx = LAContext()
                    var error: NSError?
                    let policy: LAPolicy = .deviceOwnerAuthentication
                    if ctx.canEvaluatePolicy(policy, error: &error) {
                        ctx.evaluatePolicy(policy, localizedReason: "Start Keyfob session") { success, _ in
                            DispatchQueue.main.async {
                                if success {
                                    if let pair = try? KeyManager.shared.loadKeypair() {
                                        PolicyEngine.shared.startSession(origin: origin, pubkey: pair.pubkeyHex, ttl: decision.ttl)
                                    }
                                    approved = true
                                } else {
                                    approved = false
                                }
                                presenter.dismiss(animated: true) { sem.signal() }
                            }
                        }
                        return
                    } else {
                        // Cannot evaluate policy; deny
                        approved = false
                        presenter.dismiss(animated: true) { sem.signal() }
                        return
                    }
                }
                approved = true
                presenter.dismiss(animated: true) { sem.signal() }
            }, onDeny: {
                approved = false
                presenter.dismiss(animated: true) { sem.signal() }
            }))
            host.modalPresentationStyle = .formSheet
            presenter.present(host, animated: true)
        }

        // Wait until UI dismisses
        _ = sem.wait(timeout: .distantFuture)
        if let err = presentError { throw err }
        if !approved { throw NSError(domain: "Consent", code: 1, userInfo: [NSLocalizedDescriptionKey: "User denied"]) }
    }

    private static func topViewController(base: UIViewController? = UIApplication.shared.windows.first { $0.isKeyWindow }?.rootViewController) -> UIViewController? {
        if let nav = base as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}
