import AppKit
import KeyfobBridge

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize menubar status item here later
    }

    // Handle Universal Links: https://keyfob.example.com/app/...
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else { return false }
        if let cbURL = BridgeHandler.handleUniversalLink(url) {
            NSWorkspace.shared.open(cbURL)
            return true
        }
        return false
    }
}
