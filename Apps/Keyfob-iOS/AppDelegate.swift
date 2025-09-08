import UIKit
import KeyfobBridge

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    // Handle custom URL scheme: keyfob://sign?...
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        // For now we only implement Universal Link in BridgeHandler; you can extend this if needed.
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
