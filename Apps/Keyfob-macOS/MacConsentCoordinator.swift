import Foundation
import AppKit
import SwiftUI
import KeyfobPolicy
import KeyfobCore
import KeyfobUI
import LocalAuthentication

final class MacConsentCoordinator: NSObject, PolicyEngine.ConsentProvider {
    static let shared = MacConsentCoordinator()
    private override init() {}

    private var window: NSWindow?

    func requestConsent(origin: String, eventPreview: String, mode: PolicyEngine.ConsentMode) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var approved = false
        var presentError: Error?

        DispatchQueue.main.async {
            let event: NostrEvent
            if let data = eventPreview.data(using: .utf8), let ev = try? JSONDecoder().decode(NostrEvent.self, from: data) {
                event = ev
            } else {
                event = NostrEvent(kind: 0, pubkey: "", created_at: Int(Date().timeIntervalSince1970), tags: [], content: eventPreview, id: nil, sig: nil)
            }

            let content = ConsentView(origin: origin, event: event, onApprove: { decision in
                // If user selected a session (Mode B), require biometry before approval
                if decision.useSession {
                    let ctx = LAContext()
                    var error: NSError?
                    let policy: LAPolicy = .deviceOwnerAuthentication
                    if ctx.canEvaluatePolicy(policy, error: &error) {
                        ctx.evaluatePolicy(policy, localizedReason: "Start Keyfob session") { success, evalError in
                            DispatchQueue.main.async {
                                if success {
                                    approved = true
                                } else {
                                    approved = false
                                }
                                self.window?.close()
                                semaphore.signal()
                            }
                        }
                        return
                    }
                    // If we cannot evaluate policy, deny
                    approved = false
                    self.window?.close()
                    semaphore.signal()
                    return
                }
                approved = true
                self.window?.close()
                semaphore.signal()
            }, onDeny: {
                approved = false
                self.window?.close()
                semaphore.signal()
            })
            let hosting = NSHostingView(rootView: content)

            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                             styleMask: [.titled, .closable],
                             backing: .buffered,
                             defer: false)
            w.title = "Keyfob Approval"
            w.contentView = hosting
            w.center()
            self.window = w
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        _ = semaphore.wait(timeout: .distantFuture)
        if let err = presentError { throw err }
        if !approved { throw NSError(domain: "Consent", code: 1, userInfo: [NSLocalizedDescriptionKey: "User denied"]) }
    }
}
