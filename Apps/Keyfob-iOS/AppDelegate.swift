import UIKit
import KeyfobBridge
import KeyfobPolicy

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Register consent provider to surface approval UI
        PolicyEngine.shared.consentProvider = ConsentCoordinator.shared
        return true
    }

    // Handle custom URL scheme: keyfob://sign?...
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        // Parse and sign, then open callback
        do {
            let parsed = try URLRouter.parse(url)
            let resp = try SignOrchestrator().prepareAndSign(event: parsed.event, origin: parsed.origin, mode: .perRequest)
            let result = URLRouter.CallbackResult(success: resp.id, sig: resp.sig, pubkey: resp.pubkey)
            if let cb = URLRouter.makeCallbackURL(cb: parsed.callback, result: result) {
                UIApplication.shared.open(cb, options: [:], completionHandler: nil)
                return true
            }
        } catch {
            // Try to callback with error if possible
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let cbStr = comps.queryItems?.first(where: { $0.name == "cb" })?.value, let cb = URL(string: cbStr) {
                if let errURL = URLRouter.makeCallbackURL(cb: cb, result: .init(error: "invalid", msg: String(describing: error))) {
                    UIApplication.shared.open(errURL, options: [:], completionHandler: nil)
                    return true
                }
            }
        }
        return false
    }

    // Handle Universal Links: https://keyfob.example.com/app/...
    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else { return false }
        if let cbURL = BridgeHandler.handleUniversalLink(url) {
            UIApplication.shared.open(cbURL, options: [:], completionHandler: nil)
            return true
        }
        return false
    }
}
