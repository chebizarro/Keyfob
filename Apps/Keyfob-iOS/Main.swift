import SwiftUI

@main
struct KeyfobApp: App {
    // Keep URL handling via AppDelegate (Universal Links)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
