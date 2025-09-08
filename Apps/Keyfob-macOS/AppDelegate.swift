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
        item.button?.title = NSLocalizedString("menu.title", comment: "Status bar title")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: NSLocalizedString("menu.manage_allowlist", comment: "Manage Allowlist"), action: #selector(openAllowlist), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("menu.about", comment: "About"), action: #selector(openAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: NSLocalizedString("menu.print_allowlist", comment: "Print allowlist"), action: #selector(printAllowlist), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("menu.quit", comment: "Quit"), action: #selector(quitApp), keyEquivalent: "q"))
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

    @objc private func openAbout() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let fmt = NSLocalizedString("about.text", comment: "About multi-line text with placeholders for version and build")
        let text = String(format: fmt, v, build)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("about.title", comment: "About title")
        alert.informativeText = text
        alert.addButton(withTitle: NSLocalizedString("about.ok", comment: "OK button"))
        alert.runModal()
    }

    @objc private func printAllowlist() {
        let callers = PolicyEngine.shared.listAllowedCallers()
        NSLog("[Keyfob] Allowed callers: \(callers)")
    }
}
