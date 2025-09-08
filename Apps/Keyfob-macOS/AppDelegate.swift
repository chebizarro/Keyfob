import AppKit
import KeyfobBridge
import KeyfobPolicy
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var allowlistWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize menubar status item here later
        PolicyEngine.shared.consentProvider = MacConsentCoordinator.shared

        // Create menu bar item
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Keyfob"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Manage Allowlist…", action: #selector(openAllowlist), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Keyfob", action: #selector(quitApp), keyEquivalent: "q"))
        item.menu = menu
        self.statusItem = item
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

    @objc private func openAllowlist() {
        if let w = allowlistWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let hosting = NSHostingView(rootView: AllowlistView())
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered,
                         defer: false)
        w.title = "Keyfob Allowlist"
        w.contentView = hosting
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.allowlistWindow = w
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
